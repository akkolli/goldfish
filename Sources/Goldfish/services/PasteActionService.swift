import AppKit
import Foundation

final class PasteActionService {
  private let pasteboard: NSPasteboard
  private let cacheService: MediaCache
  private let accessibilityPermissionProvider: () -> Bool
  private let targetActivator: (NSRunningApplication) -> Bool
  private let keyboardPasteScheduler: (@escaping () -> Void) -> Void
  private let feedback: (TransferSound) -> Void
  private let frontmostPID: () -> pid_t?
  private let keyboardPastePoster: () -> Bool

  init(
    pasteboard: NSPasteboard = .general, cacheService: MediaCache = MediaCache(),
    accessibilityPermissionProvider: @escaping () -> Bool = { AccessibilityPermissionService.isTrusted },
    targetActivator: @escaping (NSRunningApplication) -> Bool = PasteActionService.activateForAutomaticPaste,
    keyboardPasteScheduler: @escaping (@escaping () -> Void) -> Void = { action in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { action() }
    }, feedback: @escaping (TransferSound) -> Void = { _ in },
    frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
    keyboardPastePoster: @escaping () -> Bool = PasteActionService.pasteViaKeyboard
  ) {
    self.pasteboard = pasteboard
    self.cacheService = cacheService
    self.accessibilityPermissionProvider = accessibilityPermissionProvider
    self.targetActivator = targetActivator
    self.keyboardPasteScheduler = keyboardPasteScheduler
    self.feedback = feedback
    self.frontmostPID = frontmostPID
    self.keyboardPastePoster = keyboardPastePoster
  }

  enum TransferResult: Equatable {
    case copied(plain: Bool = false, permissionNeeded: Bool = false)
    case pasteScheduled(plain: Bool = false)
    case failed(String)

    var isPaste: Bool {
      if case .pasteScheduled = self { return true }
      return false
    }

    func message(selectedCount: Int? = nil) -> String {
      let verb: String
      let plain: Bool
      let permissionNeeded: Bool
      switch self {
      case .copied(let asPlainText, let needsPermission):
        verb = "Copied"
        plain = asPlainText
        permissionNeeded = needsPermission
      case .pasteScheduled(let asPlainText):
        verb = "Pasted"
        plain = asPlainText
        permissionNeeded = false
      case .failed(let message): return message
      }
      var message = verb
      if let count = selectedCount { message += " \(count) selected \(count == 1 ? "clip" : "clips")" }
      if plain { message += selectedCount == nil ? " Plain Text" : " as Text" }
      if permissionNeeded { message += ". Grant Accessibility access to paste automatically." }
      return message
    }
  }

  enum Intent { case copy, paste }
  enum Content {
    // A single clip and a selection deliberately use different pasteboard APIs:
    // selection writers retain each clip's types rather than single-copy fallbacks.
    case clip(Clip)
    case clips([Clip])
    case plain(Clip)
    case text(String)

    var isPlainText: Bool {
      switch self {
      case .plain, .text: return true
      default: return false
      }
    }
    var failureMessage: String {
      if isPlainText { return "Could not write plain text to clipboard." }
      if case .clips = self { return "Could not write items to clipboard." }
      return "Could not write item to clipboard."
    }
  }

  @discardableResult func transfer(_ content: Content, _ intent: Intent = .copy, targetApp: NSRunningApplication? = nil) -> TransferResult {
    let written: Bool
    switch content {
    case .clip(let clip): written = writeToPasteboard(clip)
    case .clips(let clips): written = writeToPasteboard(clips)
    case .plain(let clip): written = plainText(for: clip).map(writePlainTextToPasteboard) ?? false
    case .text(let text): written = writePlainTextToPasteboard(text)
    }
    guard written else { return .failed(content.failureMessage) }
    let result =
      intent == .paste ? completePaste(targetApp: targetApp, asPlainText: content.isPlainText) : .copied(plain: content.isPlainText)
    return reportCopyFeedback(result)
  }

  private func completePaste(targetApp: NSRunningApplication?, asPlainText: Bool = false) -> TransferResult {
    guard let targetApp, !targetApp.isTerminated else { return .copied(plain: asPlainText) }

    guard accessibilityPermissionProvider() else { return .copied(plain: asPlainText, permissionNeeded: true) }

    guard targetActivator(targetApp) else { return .copied(plain: asPlainText) }

    schedulePaste(into: targetApp)
    return .pasteScheduled(plain: asPlainText)
  }

  private func reportCopyFeedback(_ result: TransferResult) -> TransferResult {
    if case .copied = result { feedback(.copy) }
    return result
  }

  /// Prepare once before clearing the destination. Drag labels are separate
  /// from copy fallbacks so a media copy retains its original clipboard types.
  private enum Representation {
    case objects([NSPasteboardWriting], copyText: String?)
    case files([URL])
    case data(Data, NSPasteboard.PasteboardType, copyText: String?, dragText: String?)
    case text(String)
    case link(String, title: String?)

    var writers: [NSPasteboardWriting] {
      switch self {
      case .objects(let objects, _): return objects
      case .files(let urls): return urls.map { $0.standardizedFileURL as NSURL }
      case .text(let text): return [Self.item(text: text)]
      case .data(let data, let type, let copyText, let dragText):
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let text = dragText ?? copyText { item.setString(text, forType: .string) }
        return [item]
      case .link(let address, let title):
        let item = Self.item(text: address)
        item.setString(address, forType: .URL)
        if let title { item.setString(title, forType: Self.urlNameType) }
        return [item]
      }
    }

    func write(to board: NSPasteboard) -> Bool {
      switch self {
      case .objects(let objects, let text):
        let written = board.writeObjects(objects)
        if written, let text { board.setString(text, forType: .string) }
        return written
      case .files(let urls):
        let written = board.writeObjects(urls.map { $0 as NSURL })
        if written { board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
        return written
      case .data(let data, let type, let text, _):
        let written = board.setData(data, forType: type)
        if let text { board.setString(text, forType: .string) }
        return written
      case .text(let text): return board.setString(text, forType: .string)
      case .link(let address, let title):
        let written = board.setString(address, forType: .string)
        board.setString(address, forType: .URL)
        if let url = URL(string: address) { _ = board.writeObjects([url as NSURL]) }
        if let title { board.setString(title, forType: Self.urlNameType) }
        return written
      }
    }

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    private static func item(text: String?) -> NSPasteboardItem {
      let item = NSPasteboardItem()
      if let text { item.setString(text, forType: .string) }
      return item
    }
  }

  private func representation(for item: Clip) -> Representation? {
    switch item.kind {
    case .image:
      guard let path = item.imagePath, let image = cacheService.image(for: path) else { return nil }
      return .objects([image], copyText: nil)
    case .pdf, .audio, .video:
      guard let data = cacheService.data(for: item.payload) else { return nil }
      let type: NSPasteboard.PasteboardType =
        item.kind == .pdf ? .pdf : (item.kind == .audio ? .sound : VideoPayload.pasteboardType(forPath: item.payload))
      return .data(data, type, copyText: nil, dragText: dragLabel(for: item))
    case .color:
      guard let color = ColorPayload.color(from: item.payload) else { return nil }
      return .objects([color], copyText: ColorPayload.displayHex(from: item.payload))
    case .richText:
      if let data = cacheService.data(for: item.payload) {
        let text = richTextPlainString(from: data) ?? item.displayText.clipboardTrimmed
        return .data(data, .rtf, copyText: text.isEmpty ? nil : text, dragText: nil)
      }
      let text = richTextFallbackPlainString(for: item)
      return text.isEmpty ? nil : .text(text)
    case .file:
      let urls = FilePayload.urls(from: item.payload)
      guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
      return .files(urls)
    case .url:
      guard !item.payload.isEmpty else { return nil }
      return .link(item.payload, title: urlTitleForPasteboard(item.displayText, payload: item.payload))
    case .text, .code, .unknown: return item.payload.isEmpty ? nil : .text(item.payload)
    }
  }

  func pasteboardWriters(for item: Clip) -> [NSPasteboardWriting] { representation(for: item)?.writers ?? [] }

  private func writeToPasteboard(_ item: Clip) -> Bool {
    guard let representation = representation(for: item) else { return false }
    return write { representation.write(to: $0) }
  }

  private func write(_ operation: (NSPasteboard) -> Bool) -> Bool {
    pasteboard.clearContents()
    let written = operation(pasteboard)
    if written { ClipboardWrites.mark(changeCount: pasteboard.changeCount, pasteboard: pasteboard) }
    return written
  }

  private func writeToPasteboard(_ items: [Clip]) -> Bool {
    guard !items.isEmpty else { return false }
    var writers: [NSPasteboardWriting] = []
    for item in items {
      let itemWriters = pasteboardWriters(for: item)
      guard !itemWriters.isEmpty else { return false }
      writers.append(contentsOf: itemWriters)
    }
    guard !writers.isEmpty else { return false }

    return write { $0.writeObjects(writers) }
  }

  func plainText(for item: Clip) -> String? {
    switch item.kind {
    case .text, .code, .unknown, .url, .file: return nonEmptyPlainText(item.payload) ?? nonEmptyPlainText(item.displayText)
    case .richText:
      if let data = cacheService.data(for: item.payload), let text = richTextPlainString(from: data) { return text }
      return nonEmptyPlainText(richTextFallbackPlainString(for: item))
    case .image: return nonEmptyPlainText(item.ocrText) ?? nonEmptyPlainText(item.displayText)
    case .pdf, .audio, .video: return nonEmptyPlainText(item.displayText)
    case .color: return nonEmptyPlainText(ColorPayload.displayHex(from: item.payload)) ?? nonEmptyPlainText(item.displayText)
    }
  }

  @discardableResult private func writePlainTextToPasteboard(_ text: String) -> Bool {
    guard !text.clipboardTrimmed.isEmpty else { return false }
    return write { $0.setString(text, forType: .string) }
  }

  private func schedulePaste(into targetApp: NSRunningApplication) {
    let changeCount = pasteboard.changeCount
    keyboardPasteScheduler { [weak self] in
      guard let self, !targetApp.isTerminated,
        Self.shouldDeliverPaste(
          targetPID: targetApp.processIdentifier, frontmostPID: self.frontmostPID(), expectedChangeCount: changeCount,
          actualChangeCount: self.pasteboard.changeCount)
      else { return }
      if self.keyboardPastePoster() { self.feedback(.paste) }
    }
  }

  static func shouldDeliverPaste(targetPID: pid_t, frontmostPID: pid_t?, expectedChangeCount: Int, actualChangeCount: Int) -> Bool {
    targetPID == frontmostPID && expectedChangeCount == actualChangeCount
  }

  private func dragLabel(for item: Clip) -> String {
    let display = item.displayText.clipboardTrimmed
    if !display.isEmpty { return display }
    return item.kind.displayName.capitalized
  }

  private func urlTitleForPasteboard(_ title: String?, payload: String) -> String? {
    guard let title else { return nil }
    let normalized = title.split { $0.isWhitespace }.joined(separator: " ").clipboardTrimmed
    guard !normalized.isEmpty, normalized != payload else { return nil }
    guard !normalized.contains("://") else { return nil }
    return normalized
  }

  private func nonEmptyPlainText(_ value: String?) -> String? {
    guard let value, !value.clipboardTrimmed.isEmpty else { return nil }
    return value
  }

  private func richTextPlainString(from data: Data) -> String? {
    guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
    let text = attributed.string.clipboardTrimmed
    return text.isEmpty ? nil : text
  }

  private func richTextFallbackPlainString(for item: Clip) -> String {
    let payload = item.payload.clipboardTrimmed
    if looksLikeRichTextCachePath(payload) { return item.displayText.clipboardTrimmed }
    if !payload.isEmpty { return payload }
    return item.displayText.clipboardTrimmed
  }

  private func looksLikeRichTextCachePath(_ payload: String) -> Bool {
    let url = URL(fileURLWithPath: payload)
    return payload.contains("/") && url.pathExtension.lowercased() == "rtf"
  }

  private static func activateForAutomaticPaste(_ targetApp: NSRunningApplication) -> Bool {
    if #available(macOS 14, *) { return targetApp.activate() } else { return targetApp.activate(options: [.activateIgnoringOtherApps]) }
  }

  static func pasteViaKeyboard() -> Bool {
    let keyCode: UInt16 = 9
    guard let srcDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
      let srcUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else { return false }

    srcDown.flags = .maskCommand
    srcDown.post(tap: .cghidEventTap)
    srcUp.flags = .maskCommand
    srcUp.post(tap: .cghidEventTap)
    return true
  }
}
