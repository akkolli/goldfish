import AppKit
import Foundation

final class ClipboardMonitor {
  private struct CaptureConfiguration {
    let pollProfile: AppConfig.PollProfile
    let ignoredItemKinds: Set<Int>
    let ignoredApps: [String]
    let includeImageTextInSearch: Bool
    let excludeSensitive: Bool
  }

  private let store: HistoryStore
  private let pasteboard: NSPasteboard
  private let cacheService: MediaCache
  private let settings: SettingsModel
  private let frontmostApp: () -> (name: String?, bundleId: String?)
  private let imageTextExtractor: (NSImage) -> String?

  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "clipboard.monitor", qos: .utility)
  private let queueKey = DispatchSpecificKey<Void>()
  private var lastChangeCount: Int
  private var lastActiveChange = Date.distantPast
  private var scheduledInterval: TimeInterval = 0
  private var didReportReadFailure = false
  private var configuration: CaptureConfiguration
  private var paused = false
  private var isStarted = false
  var onCapturedItem: (Clip) -> Void = { _ in }

  init(
    pasteboard: NSPasteboard = .general, store: HistoryStore, cacheService: MediaCache, settings: SettingsModel,
    frontmostApp: @escaping () -> (name: String?, bundleId: String?) = ClipboardMonitor.currentFrontmostApp,
    imageTextExtractor: @escaping (NSImage) -> String? = ImageTextExtractor.recognizedText(in:)
  ) {
    self.store = store
    self.pasteboard = pasteboard
    self.cacheService = cacheService
    self.settings = settings
    self.frontmostApp = frontmostApp
    self.imageTextExtractor = imageTextExtractor
    self.lastChangeCount = pasteboard.changeCount
    self.configuration = CaptureConfiguration(
      pollProfile: settings.pollProfile, ignoredItemKinds: Set(settings.ignoredItemKindsRaw), ignoredApps: settings.ignoredApps,
      includeImageTextInSearch: settings.includeImageTextInSearch, excludeSensitive: settings.excludeSensitive)
    queue.setSpecific(key: queueKey, value: ())
  }

  func start() {
    refreshConfiguration()
    performOnQueueAndWait {
      // First launch/setup must not backfill clipboard contents copied before
      // the user chose to start capture.
      self.lastChangeCount = pasteboard.changeCount
      self.isStarted = true
      if self.paused {
        self.reportCaptureStatus("Capture is paused.")
        self.scheduleTimer(interval: 1.0)
        return
      }

      self.reportCaptureStatus("Capture is running. Waiting for clipboard changes.")
      self.scheduleTimer(interval: self.effectiveProfile.idleInterval)
    }
    pollNow()
  }

  func pollNow() {
    refreshConfiguration()
    queue.async { [weak self] in self?.pollPasteboard(rescheduleAfterCapture: false) }
  }

  func pollNowAndWait() {
    refreshConfiguration()
    performOnQueueAndWait { self.pollPasteboard(rescheduleAfterCapture: false) }
  }

  func setPaused(_ paused: Bool) {
    refreshConfiguration()
    performOnQueueAndWait {
      if self.paused != paused {
        // Never capture a value copied while capture was paused on resume.
        self.lastChangeCount = pasteboard.changeCount
      }
      self.paused = paused
      self.lastActiveChange = .distantPast
      if paused {
        self.reportCaptureStatus("Capture is paused.")
        if self.isStarted { self.scheduleTimer(interval: 1.0) }
      } else {
        self.reportCaptureStatus("Capture resumed. Waiting for clipboard changes.")
        if self.isStarted { self.scheduleTimer(interval: self.effectiveProfile.idleInterval) }
      }
    }
  }

  func stop() {
    performOnQueueAndWait {
      self.isStarted = false
      self.timer?.cancel()
      self.timer = nil
      self.scheduledInterval = 0
    }
  }

  func refreshCaptureConfiguration() { refreshConfiguration() }

  private var effectiveProfile: AppConfig.PollProfile { configuration.pollProfile }

  private func scheduleTimer(interval: TimeInterval) {
    let effective = clampedInterval(interval)
    if timer != nil && scheduledInterval == effective { return }

    timer?.cancel()
    let newTimer = DispatchSource.makeTimerSource(queue: queue)
    timer = nil
    scheduledInterval = 0
    newTimer.schedule(deadline: .now() + effective, repeating: effective, leeway: .milliseconds(12))
    newTimer.setEventHandler { [weak self] in self?.tick() }
    newTimer.resume()
    timer = newTimer
    scheduledInterval = effective
  }

  private func tick() { pollPasteboard(rescheduleAfterCapture: true) }

  private func pollPasteboard(rescheduleAfterCapture: Bool) {
    if paused {
      reportCaptureStatus("Capture is paused.")
      return
    }

    let pasteboard = self.pasteboard
    let changeCount = pasteboard.changeCount

    if changeCount == lastChangeCount {
      if Date().timeIntervalSince(lastActiveChange) > effectiveProfile.idleRecoveryWindow {
        if rescheduleAfterCapture { scheduleTimer(interval: effectiveProfile.idleInterval) }
      }
      return
    }

    lastChangeCount = changeCount
    lastActiveChange = Date()

    if ClipboardWrites.consume(changeCount: changeCount, pasteboard: pasteboard) {
      reportReadFailureStatus("Clipboard was updated by Goldfish; skipping capture.")
      return
    }

    didReportReadFailure = false
    if let item = readCurrentItem(from: pasteboard) {
      reportCaptured(item)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let storedItem = self.store.upsert(item) { self.onCapturedItem(storedItem) }
      }
    } else if !didReportReadFailure {
      reportCaptureStatus("Clipboard changed, but Goldfish could not read a supported item.")
    }

    if rescheduleAfterCapture { scheduleTimer(interval: effectiveProfile.activeInterval) }
  }

  func clampedInterval(_ interval: TimeInterval) -> TimeInterval { max(interval, AppConfig.minResponsiveActiveInterval) }

  static func shouldCaptureManagedPayload(byteCount: Int) -> Bool { byteCount >= 0 && byteCount <= AppConfig.maxManagedPayloadBytes }

  private func readCurrentItem(from pasteboard: NSPasteboard) -> Clip? {
    // Respect the writer's privacy/ephemeral markers before reading any payload,
    // regardless of the foreground app or heuristic secret-filter preference.
    if Self.excludedPasteboardTypes.contains(where: { pasteboard.types?.contains($0) == true }) {
      return reportReadFailureStatus("Skipped confidential or temporary clipboard content.")
    }
    guard store.canPersistHistory else { return reportReadFailureStatus("Error: Capture paused; \(store.savingUnavailableMessage)") }
    let source = frontmostApp()

    if isSourceIgnored(source) { return reportReadFailureStatus("Ignored clipboard change from \(sourceDescription(source)).") }
    // Resolve URL metadata only after file capture has had its first chance.
    var didReadURL = false
    var cachedURL: PasteboardURLPayload?
    func urlPayload() -> PasteboardURLPayload? {
      if !didReadURL {
        cachedURL = urlPayloadFromPasteboard(pasteboard)
        didReadURL = true
      }
      return cachedURL
    }
    var cachedPreviewPresence: Bool?
    func hasURLPreview() -> Bool {
      if let cachedPreviewPresence { return cachedPreviewPresence }
      let present = urlPayload() != nil && imageData(on: pasteboard) != nil
      cachedPreviewPresence = present
      return present
    }
    // Readers are lazy and ordered. A disabled representation ends capture;
    // it cannot fall through to the same content's plain-text fallback.
    let readers: [CaptureReader] = [
      .init(.file, extract: { self.fileURLs(on: pasteboard) }, read: { self.itemFromFiles($0, source: source) }),
      .init(
        .url, present: { urlPayload() != nil }, terminal: { hasURLPreview() },
        read: {
          guard hasURLPreview(), let url = urlPayload() else { return nil }
          return self.itemFromURL(url.url, title: url.title, source: source, previewPasteboard: pasteboard)
        }), .init(.color, extract: { NSColor(from: pasteboard) }, read: { self.itemFromColor($0, source: source) }),
      .init(.image, extract: { self.imageData(on: pasteboard) }, read: { self.itemFromImage($0, source: source) }),
      .init(.pdf, extract: { pasteboard.data(forType: .pdf) }, read: { self.capturedMedia($0, kind: .pdf, source: source) }),
      .init(
        .video, extract: { VideoPayload.data(from: pasteboard) },
        read: { video in
          self.capturedMedia(video.data, kind: .video, source: source, fileExtension: VideoPayload.fileExtension(for: video.type))
        }), .init(.audio, extract: { pasteboard.data(forType: .sound) }, read: { self.capturedMedia($0, kind: .audio, source: source) }),
      .init(.richText, extract: { pasteboard.data(forType: .rtf) }, read: { self.itemFromRichText($0, format: .rtf, source: source) }),
      .init(
        .url, present: { urlPayload() != nil }, terminal: { urlPayload() != nil },
        read: { urlPayload().flatMap { self.itemFromURL($0.url, title: $0.title, source: source) } }),
      .init(.richText, extract: { self.htmlData(from: pasteboard) }, read: { self.itemFromRichText($0, format: .html, source: source) }),
    ]
    for reader in readers {
      if configuration.ignoredItemKinds.contains(reader.kind.rawValue), reader.present() {
        reportIgnoredKind(reader.kind)
        return nil
      }
      let terminal = reader.terminal()
      let item = reader.read()
      if item != nil || terminal { return item }
    }

    if let string = pasteboard.string(forType: .string) { return itemFromString(string, source: source) }
    return reportReadFailureStatus("Clipboard changed, but Goldfish could not read a supported item.")
  }

  private func itemFromString(_ value: String, source: CaptureSource) -> Clip? {
    let trimmed = value.clipboardTrimmed
    if trimmed.isEmpty { return reportReadFailureStatus("Clipboard string is empty.") }
    let url = detectURL(trimmed)
    let kind: ClipKind =
      url != nil ? .url : ColorPayload.isHexColorLiteral(trimmed) ? .color : CodeSnippetPayload.isLikelyCode(trimmed) ? .code : .text
    if configuration.ignoredItemKinds.contains(kind.rawValue) {
      reportIgnoredKind(kind)
      return nil
    }
    if configuration.excludeSensitive,
      SensitiveContentDetector.isLikelySensitive(trimmed, sourceBundleId: source.bundleId, sourceApp: source.name)
    {
      return reportReadFailureStatus("Copy was ignored because it looks sensitive.")
    }

    let payload = url?.absoluteString ?? (kind == .color ? trimmed : value)
    let title =
      url?.absoluteString
      ?? (kind == .color ? ColorPayload.displayHex(from: trimmed) : kind == .code ? CodeSnippetPayload.title(from: trimmed) : trimmed)
    return capturedItem(kind: kind, displayText: title, payload: payload, hash: store.hashString(payload), source: source)
  }

  private static let excludedPasteboardTypes = [
    "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type",
  ].map { NSPasteboard.PasteboardType($0) }

  private func itemFromURL(_ url: URL, title: String?, source: CaptureSource, previewPasteboard: NSPasteboard? = nil) -> Clip? {
    if configuration.excludeSensitive,
      SensitiveContentDetector.isLikelySensitive(url.absoluteString, sourceBundleId: source.bundleId, sourceApp: source.name)
    {
      return reportReadFailureStatus("URL was ignored because it looks sensitive.")
    }
    let displayText = urlDisplayText(url: url, title: title)
    let id = UUID()
    let previewPaths = previewPasteboard.flatMap { previewImagePaths(from: $0, id: id) }
    return capturedItem(
      kind: .url, displayText: displayText, payload: url.absoluteString, hash: store.hashString(url.absoluteString), source: source, id: id,
      imagePath: previewPaths?.full, thumbnailPath: previewPaths?.thumb)
  }

  private func previewImagePaths(from pasteboard: NSPasteboard, id: UUID) -> (full: String, thumb: String)? {
    guard let data = imageData(on: pasteboard), payloadIsWithinLimit(data, kind: "Link preview image"), let image = NSImage(data: data)
    else { return nil }
    return cacheService.cacheImage(image, id: id)
  }

  private func itemFromImage(_ data: Data, source: CaptureSource) -> Clip? {
    guard payloadIsWithinLimit(data, kind: "Image") else { return nil }
    guard let image = NSImage(data: data) else {
      return reportReadFailureStatus("Clipboard image data is present but could not be decoded.")
    }

    let id = UUID()
    guard let cachePaths = cacheService.cacheImage(image, id: id) else {
      return reportReadFailureStatus("Failed to cache image for clipboard history.")
    }
    let recognizedText = recognizedTextIfEnabled(for: image)

    return capturedItem(
      kind: .image, displayText: "Image", payload: cachePaths.full, hash: store.hashData(data), source: source, id: id,
      imagePath: cachePaths.full, thumbnailPath: cachePaths.thumb, ocrText: recognizedText)
  }

  private func recognizedTextIfEnabled(for image: NSImage) -> String? {
    guard configuration.includeImageTextInSearch, let text = imageTextExtractor(image)?.clipboardTrimmed, !text.isEmpty else { return nil }

    return ImageTextExtractor.normalizedRecognizedText(text)
  }

  private func imageData(on pasteboard: NSPasteboard) -> Data? { pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) }

  private func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).filter(\.isFileURL)
    return urls.isEmpty ? nil : urls
  }

  private func capturedMedia(_ data: Data, kind: ClipKind, source: CaptureSource, fileExtension: String? = nil) -> Clip? {
    let title = kind.presentation.label
    guard payloadIsWithinLimit(data, kind: title) else { return nil }
    let id = UUID()
    guard let path = cacheService.cacheMedia(kind, data, id: id, fileExtension: fileExtension) else {
      return reportReadFailureStatus("Failed to cache \(title == "PDF" ? title : title.lowercased()) for clipboard history.")
    }
    let display =
      kind == .video
      ? VideoPayload.displayTitle(byteCount: data.count)
      : "\(title) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
    return capturedItem(kind: kind, displayText: display, payload: path, hash: store.hashData(data), source: source, id: id)
  }

  private func itemFromColor(_ color: NSColor, source: CaptureSource) -> Clip? {
    guard let hex = ColorPayload.hexString(from: color) else {
      return reportReadFailureStatus("Clipboard color is present but could not be decoded.")
    }

    return capturedItem(kind: .color, displayText: hex, payload: hex, hash: store.hashString(hex), source: source)
  }

  private enum RichTextFormat {
    case rtf, html
    var title: String { self == .rtf ? "Rich text" : "HTML text" }
    var pasteboardName: String { self == .rtf ? "RTF" : "HTML" }
  }

  private func itemFromRichText(_ data: Data, format: RichTextFormat, source: CaptureSource) -> Clip? {
    let title = format.title
    guard payloadIsWithinLimit(data, kind: title) else { return nil }
    guard let attributed = format == .rtf ? NSAttributedString(rtf: data, documentAttributes: nil) : attributedString(fromHTMLData: data)
    else { return reportReadFailureStatus("Clipboard pasteboard reported \(format.pasteboardName) but text could not be read.") }
    let text = attributed.string.clipboardTrimmed
    guard !text.isEmpty else { return reportReadFailureStatus("\(title) from pasteboard is empty.") }
    if configuration.excludeSensitive,
      SensitiveContentDetector.isLikelySensitive(text, sourceBundleId: source.bundleId, sourceApp: source.name)
    {
      return reportReadFailureStatus("\(title) was ignored because it looks sensitive.")
    }
    let cacheData: Data
    if format == .rtf {
      cacheData = data
    } else {
      guard let converted = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) else {
        return reportReadFailureStatus("Failed to convert HTML clipboard data for clipboard history.")
      }
      cacheData = converted
    }
    let id = UUID()
    guard let path = cacheService.cacheMedia(.richText, cacheData, id: id) else {
      return reportReadFailureStatus("Failed to cache \(format == .rtf ? "rich text" : title) for clipboard history.")
    }
    return capturedItem(kind: .richText, displayText: text, payload: path, hash: store.hashData(data), source: source, id: id)
  }

  private func itemFromFiles(_ fileURLs: [URL], source: CaptureSource) -> Clip? {
    let text = FilePayload.payload(from: fileURLs)
    let display = fileURLs.count == 1 ? text : "\(fileURLs.count) files"
    return capturedItem(kind: .file, displayText: display, payload: text, hash: store.hashString(text), source: source)
  }

  private func capturedItem(
    kind: ClipKind, displayText: String, payload: String, hash: String, source: CaptureSource, id: UUID = UUID(), imagePath: String? = nil,
    thumbnailPath: String? = nil, ocrText: String? = nil
  ) -> Clip {
    let now = Date()
    return Clip(
      id: id, kind: kind, displayText: displayText, payload: payload, payloadHash: hash, createdAt: now, lastUsedAt: now, useCount: 1,
      sourceApp: source.name, imagePath: imagePath, thumbnailPath: thumbnailPath, sourceAppBundleId: source.bundleId, ocrText: ocrText)
  }

  private func detectURL(_ candidate: String) -> URL? {
    if let direct = URL(string: candidate), let scheme = direct.scheme, !scheme.isEmpty { return direct }

    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let range = NSRange(location: 0, length: candidate.utf16.count)
      if let match = detector.firstMatch(in: candidate, options: [], range: range), match.resultType == .link,
        match.range.location == range.location, match.range.length == range.length, let value = match.url
      {
        return value
      }
    }

    if let comps = URLComponents(string: "https://" + candidate), let host = comps.host, host.contains(".") { return comps.url }

    return nil
  }

  private typealias CaptureSource = (name: String?, bundleId: String?)

  private struct CaptureReader {
    let kind: ClipKind
    let present: () -> Bool
    let terminal: () -> Bool
    let read: () -> Clip?

    init(_ kind: ClipKind, present: @escaping () -> Bool, terminal: @escaping () -> Bool = { false }, read: @escaping () -> Clip?) {
      self.kind = kind
      self.present = present
      self.terminal = terminal
      self.read = read
    }

    init<Payload>(_ kind: ClipKind, extract: @escaping () -> Payload?, read: @escaping (Payload) -> Clip?) {
      var payload: Payload?
      var extracted = false
      func value() -> Payload? {
        if !extracted {
          payload = extract()
          extracted = true
        }
        return payload
      }
      self.init(kind, present: { value() != nil }, read: { value().flatMap(read) })
    }
  }

  private func reportIgnoredKind(_ kind: ClipKind) { reportReadFailureStatus("\(kind.statusName) items are ignored in capture settings.") }

  private struct PasteboardURLPayload {
    let url: URL
    let title: String?
  }

  private func urlPayloadFromPasteboard(_ pasteboard: NSPasteboard) -> PasteboardURLPayload? {
    guard let url = pasteboard.string(forType: .URL) else { return nil }
    guard let detected = detectURL(url) else { return nil }
    return PasteboardURLPayload(url: detected, title: urlTitle(from: pasteboard, url: detected))
  }

  private func urlDisplayText(url: URL, title: String?) -> String {
    if let candidate = cleanURLTitle(title, url: url) { return candidate }
    return url.absoluteString
  }

  private func urlTitle(from pasteboard: NSPasteboard, url: URL) -> String? {
    let titleTypes = [
      NSPasteboard.PasteboardType(rawValue: "public.url-name"),
      NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-file-url-name"),
    ]
    for type in titleTypes { if let title = cleanURLTitle(pasteboard.string(forType: type), url: url) { return title } }

    if let html = pasteboard.string(forType: .html), let title = cleanURLTitle(plainText(fromHTML: html), url: url) { return title }

    if let data = pasteboard.data(forType: .html), let html = String(data: data, encoding: .utf8),
      let title = cleanURLTitle(plainText(fromHTML: html), url: url)
    {
      return title
    }

    return nil
  }

  private func cleanURLTitle(_ value: String?, url: URL) -> String? {
    guard let value else { return nil }
    let normalized = value.split { $0.isWhitespace }.joined(separator: " ").clipboardTrimmed
    guard !normalized.isEmpty else { return nil }
    guard normalized != url.absoluteString else { return nil }
    guard detectURL(normalized) == nil else { return nil }
    return normalized
  }

  private func plainText(fromHTML html: String) -> String? {
    guard let data = html.data(using: .utf8) else { return nil }
    return attributedString(fromHTMLData: data)?.string
  }

  private func htmlData(from pasteboard: NSPasteboard) -> Data? {
    if let data = pasteboard.data(forType: .html), !data.isEmpty { return data }
    if let html = pasteboard.string(forType: .html), let data = html.data(using: .utf8), !data.isEmpty { return data }
    return nil
  }

  private func attributedString(fromHTMLData data: Data) -> NSAttributedString? {
    try? NSAttributedString(
      data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
      documentAttributes: nil)
  }

  private func isSourceIgnored(_ source: (name: String?, bundleId: String?)) -> Bool {
    guard !configuration.ignoredApps.isEmpty else { return false }
    let lowerName = source.name?.lowercased() ?? ""
    let lowerBundle = source.bundleId?.lowercased() ?? ""

    return configuration.ignoredApps.contains { ignored in
      let candidate = ignored.clipboardTrimmed.lowercased()
      if candidate.isEmpty { return false }
      return !candidate.isEmpty && (lowerName.contains(candidate) || lowerBundle.contains(candidate))
    }
  }

  private static func currentFrontmostApp() -> (name: String?, bundleId: String?) {
    guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
    return (app.localizedName, app.bundleIdentifier)
  }

  private func reportCaptured(_ item: Clip) {
    let source = item.sourceApp ?? "unknown app"
    reportCaptureStatus("Captured \(item.kind.displayName) from \(source).")
  }

  private func payloadIsWithinLimit(_ data: Data, kind: String) -> Bool {
    guard Self.shouldCaptureManagedPayload(byteCount: data.count) else {
      let limit = ByteCountFormatter.string(fromByteCount: Int64(AppConfig.maxManagedPayloadBytes), countStyle: .file)
      reportReadFailureStatus("Skipped: \(kind) is larger than the \(limit) capture limit.")
      return false
    }
    return true
  }

  private func refreshConfiguration() {
    precondition(Thread.isMainThread, "Clipboard monitor controls must be used on the main thread.")
    let next = CaptureConfiguration(
      pollProfile: settings.pollProfile, ignoredItemKinds: Set(settings.ignoredItemKindsRaw), ignoredApps: settings.ignoredApps,
      includeImageTextInSearch: settings.includeImageTextInSearch, excludeSensitive: settings.excludeSensitive)
    performOnQueueAndWait { self.configuration = next }
  }

  private func performOnQueueAndWait<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
    return queue.sync(execute: work)
  }

  private func reportCaptureStatus(_ message: String) {
    DispatchQueue.main.async { [weak self] in self?.settings.setStatus(.capture, message) }
  }

  @discardableResult private func reportReadFailureStatus(_ message: String) -> Clip? {
    didReportReadFailure = true
    reportCaptureStatus(captureFailureDisplayMessage(message))
    return nil
  }

  private func captureFailureDisplayMessage(_ message: String) -> String {
    let trimmed = message.clipboardTrimmed
    guard !trimmed.isEmpty else { return "Skipped: Clipboard changed, but there was no readable content." }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("skipped:") || lower.hasPrefix("error:") { return trimmed }
    if lower.contains("failed") { return "Error: \(trimmed)" }
    return "Skipped: \(trimmed)"
  }

  private func sourceDescription(_ source: (name: String?, bundleId: String?)) -> String { source.name ?? source.bundleId ?? "ignored app" }
}
