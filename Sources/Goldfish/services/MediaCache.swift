import AVFoundation
import AppKit
import Foundation

final class MediaCache {
  typealias VideoThumbnailProvider = (URL) -> NSImage?

  private let thumbnailCache = NSCache<NSString, NSImage>()
  private let fileManager = FileManager.default
  private let queue = DispatchQueue(label: "clipboard.cache.service", qos: .utility)
  private let imageDirectory: URL
  private let thumbnailDirectory: URL
  private let attachmentDirectory: URL
  private let temporaryPreviewDirectory: URL
  private let encryptionService: HistoryEncryption
  private let videoThumbnailProvider: VideoThumbnailProvider

  init(
    baseURL: URL? = nil, encryptionService: HistoryEncryption = HistoryEncryption(), videoThumbnailProvider: VideoThumbnailProvider? = nil
  ) {
    let base = baseURL ?? HistoryStore.storageDirectory()
    imageDirectory = base.appendingPathComponent("images", isDirectory: true)
    thumbnailDirectory = base.appendingPathComponent("thumbnails", isDirectory: true)
    attachmentDirectory = base.appendingPathComponent("attachments", isDirectory: true)
    temporaryPreviewDirectory = (baseURL ?? FileManager.default.temporaryDirectory).appendingPathComponent(
      AppConfig.storageDirectoryName, isDirectory: true
    ).appendingPathComponent("Previews", isDirectory: true)
    self.encryptionService = encryptionService
    self.videoThumbnailProvider = videoThumbnailProvider ?? Self.makeVideoThumbnail
    thumbnailCache.countLimit = 128
    for directory in [imageDirectory, thumbnailDirectory, attachmentDirectory] {
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      hardenDirectory(directory)
    }
    clearTemporaryPreviews(wait: true)
  }

  func cacheImage(_ image: NSImage, id: UUID) -> (full: String, thumb: String)? {
    let fullURL = imageDirectory.appendingPathComponent("\(id.uuidString).png")
    let thumbURL = thumbnailDirectory.appendingPathComponent("\(id.uuidString).png")

    let boundedFullImage = image.resized(to: .init(width: AppConfig.maxFullImagePixelSize, height: AppConfig.maxFullImagePixelSize))
    guard let fullData = boundedFullImage.pngData() else { return nil }
    let thumbnail = image.resized(to: .init(width: 320, height: 320))
    guard let thumbData = thumbnail.pngData() else { return nil }

    do {
      try writeProtected(fullData, to: fullURL)
      try writeProtected(thumbData, to: thumbURL)
      thumbnailCache.setObject(thumbImage(thumbData) ?? image, forKey: thumbURL.path as NSString)
      return (full: fullURL.path, thumb: thumbURL.path)
    } catch { return nil }
  }

  func cacheMedia(_ kind: ClipKind, _ data: Data, id: UUID, fileExtension: String? = nil) -> String? {
    guard let ext = kind.attachmentExtension() else { return nil }
    return cacheAttachmentData(data, id: id, fileExtension: fileExtension ?? ext)
  }

  func cacheAttachmentData(_ data: Data, id: UUID, fileExtension: String) -> String? {
    let sanitizedExtension = fileExtension.split { $0 == "." || $0 == "/" || $0 == "\\" }.last.map(String.init) ?? "dat"
    let normalizedExtension = sanitizedExtension.clipboardTrimmed.isEmpty ? "dat" : sanitizedExtension
    return cacheAttachment(data, id: id, fileExtension: normalizedExtension)
  }

  func cacheImageSidecarData(_ data: Data, id: UUID, fileNamePrefix: String? = nil) -> String? {
    let prefix = fileNamePrefix?.clipboardTrimmed ?? ""
    let fileName: String
    if prefix.isEmpty || prefix == "thumb" { fileName = "\(id.uuidString).png" } else { fileName = "\(prefix)-\(id.uuidString).png" }
    let directory = prefix == "thumb" ? thumbnailDirectory : imageDirectory
    let url = directory.appendingPathComponent(fileName)
    do {
      try writeProtected(data, to: url)
      if let image = thumbImage(data) { thumbnailCache.setObject(image, forKey: url.path as NSString) }
      return url.path
    } catch { return nil }
  }

  private func cacheAttachment(_ data: Data, id: UUID, fileExtension: String) -> String? {
    let url = attachmentDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    do {
      try writeProtected(data, to: url)
      return url.path
    } catch { return nil }
  }

  private func cachedThumbnail(_ key: String, load: () -> NSImage?) -> NSImage? {
    if let cached = thumbnailCache.object(forKey: key as NSString) { return cached }
    guard let image = load() else { return nil }
    thumbnailCache.setObject(image, forKey: key as NSString)
    return image
  }

  func image(for path: String) -> NSImage? { cachedThumbnail(path) { data(for: path).flatMap(NSImage.init(data:)) } }

  func previewThumbnail(for item: Clip) -> NSImage? {
    switch item.kind {
    case .url, .image:
      if let path = item.thumbnailPath, let thumbnail = image(for: path) { return thumbnail }
      guard let path = item.imagePath, let fullImage = image(for: path) else { return nil }
      return fullImage.resized(to: CGSize(width: 320, height: 320))

    case .pdf:
      if let thumbnail = cachedThumbnail(
        "pdf-preview:\(item.id.uuidString):\(item.payload)",
        load: {
          guard let data = data(for: item.payload), let image = NSImage(data: data), hasDrawableSize(image) else { return nil }
          return image.resized(to: CGSize(width: 260, height: 132))
        })
      {
        return thumbnail
      }
      return filePreviewThumbnail(for: item.payload)

    case .file: return filePreviewThumbnail(for: item.payload)

    case .video: return videoPreviewThumbnail(for: item)

    case .text, .unknown, .audio, .richText, .color, .code: return nil
    }
  }

  func data(for path: String) -> Data? {
    let url = URL(fileURLWithPath: path)
    guard let stored = try? Data(contentsOf: url) else { return nil }

    if HistoryEncryption.isProtected(stored) { return encryptionService.unprotectData(stored) }

    if isManagedSidecar(path: path), encryptionService.isAvailable {
      try? writeProtected(stored, to: url)
      hardenFile(url)
    }
    return stored
  }

  private func filePreviewThumbnail(for path: String) -> NSImage? {
    guard let url = fileURL(from: path), fileManager.fileExists(atPath: url.path) else { return nil }

    return cachedThumbnail("file-preview:\(url.standardizedFileURL.path)") {
      if let decoded = NSImage(contentsOf: url), decoded.isValid, hasDrawableSize(decoded) {
        return decoded.resized(to: CGSize(width: 260, height: 132))
      }
      let icon = NSWorkspace.shared.icon(forFile: url.path)
      icon.size = NSSize(width: 96, height: 96)
      return icon
    }
  }

  private func videoPreviewThumbnail(for item: Clip) -> NSImage? {
    cachedThumbnail("video-preview:\(item.id.uuidString):\(item.payload)") {
      guard let data = data(for: item.payload),
        let temporaryURL = writeTemporaryCopy(data: data, id: item.id, fileExtension: VideoPayload.fileExtension(from: item.payload))
      else { return nil }
      defer { removeTemporaryCopyIfPossible(temporaryURL) }
      guard let image = videoThumbnailProvider(temporaryURL), hasDrawableSize(image) else { return nil }
      return image.resized(to: CGSize(width: 260, height: 132))
    }
  }

  private static func makeVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 520, height: 264)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

    for time in [CMTime(seconds: 0.08, preferredTimescale: 600), .zero] {
      if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
      }
    }
    return nil
  }

  private func hasDrawableSize(_ image: NSImage) -> Bool { image.size.width > 0 && image.size.height > 0 }

  private func fileURL(from path: String) -> URL? {
    let trimmed = path.clipboardTrimmed
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) { return url }
    return URL(fileURLWithPath: trimmed)
  }

  func temporaryReadableURL(for item: Clip) -> URL? {
    let source: String
    let fileExtension: String
    if item.kind == .image {
      guard let path = item.imagePath else { return nil }
      source = path
      fileExtension = "png"
    } else {
      guard let ext = item.kind.attachmentExtension(for: item.payload) else { return nil }
      source = item.payload
      fileExtension = ext
    }
    guard let contents = data(for: source) else { return nil }
    return writeTemporaryCopy(data: contents, id: item.id, fileExtension: fileExtension)
  }

  func temporaryPreviewURL(for item: Clip) -> URL? {
    switch item.kind {
    case .file:
      let urls = FilePayload.urls(from: item.payload)
      return urls.first { fileManager.fileExists(atPath: $0.path) }
    case .text, .code, .unknown:
      let text = item.payload.clipboardTrimmed.isEmpty ? item.displayText : item.payload
      guard !text.clipboardTrimmed.isEmpty else { return nil }
      return writeTemporaryCopy(data: Data(text.utf8), id: item.id, fileExtension: "txt")
    case .color:
      let text = ColorPayload.previewText(from: item.payload)
      return writeTemporaryCopy(data: Data(text.utf8), id: item.id, fileExtension: "txt")
    case .url:
      guard let data = webLocationData(for: item.payload) else { return nil }
      return writeTemporaryCopy(data: data, id: item.id, fileExtension: "webloc")
    case .image, .pdf, .audio, .richText, .video: return temporaryReadableURL(for: item)
    }
  }

  func encryptCachedReferencesIfNeeded(for items: [Clip]) {
    queue.async { [weak self] in
      guard let self else { return }
      for item in items { for path in self.managedPaths(for: item) { _ = self.data(for: path) } }
    }
  }

  func removeCachedReferences(_ item: Clip, preserving paths: Set<String> = []) {
    removeManagedFiles(managedPaths(for: item).filter { !paths.contains($0) })
  }

  func removeManagedFiles(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      for path in paths where self.isManagedSidecar(path: path) {
        try? self.fileManager.removeItem(atPath: path)
        self.thumbnailCache.removeObject(forKey: NSString(string: path))
      }
    }
  }

  func managedPaths(for item: Clip) -> [String] {
    var paths = [item.imagePath, item.thumbnailPath].compactMap { $0 }
    if item.kind == .image || item.kind.usesManagedPayloadAttachment { paths.append(item.payload) }
    return Array(Set(paths.filter { isManagedSidecar(path: $0) }))
  }

  func purgeIfNeeded(maxBytes: Int64) {
    queue.async {
      let urls = self.thumbnailFileURLs()
      var items: [(url: URL, size: Int64, date: Date)] = []
      var totalSize: Int64 = 0

      for url in urls {
        guard let attrs = try? self.fileManager.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber,
          let mod = attrs[.modificationDate] as? Date
        else { continue }

        let bytes = Int64(size.int64Value)
        totalSize += bytes
        items.append((url, bytes, mod))
      }

      if totalSize <= maxBytes && items.count <= AppConfig.maxImageCacheFiles { return }

      let ordered = items.sorted { $0.date < $1.date }
      var remaining = totalSize
      var pointer = 0

      while (remaining > maxBytes || ordered.count - pointer > AppConfig.maxImageCacheFiles) && pointer < ordered.count {
        let candidate = ordered[pointer]
        try? self.fileManager.removeItem(at: candidate.url)
        self.thumbnailCache.removeObject(forKey: NSString(string: candidate.url.path))
        remaining -= candidate.size
        pointer += 1
      }
    }
  }

  func clearCache() {
    queue.async { [weak self] in
      guard let self else { return }
      thumbnailCache.removeAllObjects()
      let contents = self.thumbnailFileURLs()
      for url in contents { try? self.fileManager.removeItem(at: url) }
      self.removeTemporaryPreviewFiles()
    }
  }

  func clearTemporaryPreviews(wait: Bool = false) {
    let work: () -> Void = { [weak self] in
      guard let self else { return }
      self.removeTemporaryPreviewFiles()
    }
    if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
  }

  func flushForTesting() { queue.sync {} }

  private func thumbImage(_ data: Data) -> NSImage? { NSImage(data: data) }

  private func writeProtected(_ data: Data, to url: URL) throws {
    try encryptionService.protectDataForStorage(data).write(to: url, options: .atomic)
    hardenFile(url)
  }

  private func hardenDirectory(_ url: URL) { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }

  private func hardenFile(_ url: URL) { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

  func isManagedSidecar(path: String) -> Bool {
    let original = URL(fileURLWithPath: path).standardizedFileURL
    let url = original.resolvingSymlinksInPath()
    return [imageDirectory, thumbnailDirectory, attachmentDirectory].contains {
      original.deletingLastPathComponent() == $0.standardizedFileURL
        && url.deletingLastPathComponent() == $0.standardizedFileURL.resolvingSymlinksInPath()
    }
  }

  private func thumbnailFileURLs() -> [URL] {
    let current = (try? fileManager.contentsOfDirectory(at: thumbnailDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
    let legacy = ((try? fileManager.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil, options: [])) ?? []).filter {
      $0.lastPathComponent.hasPrefix("thumb-")
    }
    return current + legacy
  }

  private func writeTemporaryCopy(data: Data, id: UUID, fileExtension: String) -> URL? {
    let url = temporaryPreviewDirectory.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).\(fileExtension)")

    do {
      try fileManager.createDirectory(at: temporaryPreviewDirectory, withIntermediateDirectories: true)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryPreviewDirectory.path)
      try data.write(to: url, options: .atomic)
      hardenFile(url)
      return url
    } catch { return nil }
  }

  private func removeTemporaryCopyIfPossible(_ url: URL) {
    try? fileManager.removeItem(at: url)
    removeEmptyTemporaryPreviewDirectory()
  }

  private func webLocationData(for value: String) -> Data? {
    let trimmed = value.clipboardTrimmed
    guard !trimmed.isEmpty else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: ["URL": trimmed], format: .xml, options: 0)
  }

  private func removeTemporaryPreviewFiles() {
    guard fileManager.fileExists(atPath: temporaryPreviewDirectory.path) else { return }

    let contents = (try? fileManager.contentsOfDirectory(at: temporaryPreviewDirectory, includingPropertiesForKeys: nil, options: [])) ?? []

    for url in contents { try? fileManager.removeItem(at: url) }

    removeEmptyTemporaryPreviewDirectory()
  }

  private func removeEmptyTemporaryPreviewDirectory() {
    if ((try? fileManager.contentsOfDirectory(at: temporaryPreviewDirectory, includingPropertiesForKeys: nil)) ?? []).isEmpty {
      try? fileManager.removeItem(at: temporaryPreviewDirectory)
    }
  }
}
