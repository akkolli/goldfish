import Foundation

typealias ArchiveWrite = (_ write: () throws -> Void) throws -> Void

struct ArchiveSummary: Equatable {
  let itemCount: Int
  let sidecarCount: Int
  let skippedItemCount: Int
  let skippedSidecarCount: Int

  func message(_ verb: String, location: String = "", includingSkipped: Bool = false) -> String {
    var message = "\(verb) \(itemCount) clips and \(sidecarCount) attachments\(location)."
    if includingSkipped, skippedItemCount > 0 || skippedSidecarCount > 0 {
      message += " Skipped \(skippedItemCount) clips and \(skippedSidecarCount) attachments."
    }
    return message
  }
}

struct ArchiveImport {
  let items: [Clip]
  let collections: [ArchivePinboard]
  let summary: ArchiveSummary
  let createdPaths: [String]
}

struct ArchivePinboard: Codable, Equatable {
  let name: String
  let colorHex: String?
  let icon: String?
}

enum ArchiveError: LocalizedError {
  case unsupportedVersion(Int)
  case invalidArchive
  case attachmentWriteFailed
  case archiveTooLarge(Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version): return "This Goldfish archive uses unsupported format version \(version)."
    case .invalidArchive: return "The selected file is not a valid Goldfish archive."
    case .attachmentWriteFailed: return "Goldfish could not save the archive attachments. Existing clips have not been replaced."
    case .archiveTooLarge(let maxBytes):
      let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
      return "This Goldfish archive exceeds the \(limit) safety limit."
    }
  }
}

final class HistoryArchive {
  static let fileExtension = "clipboredarchive"
  private static let currentFormatVersion = 1

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  func exportArchive(
    items: [Clip], to url: URL, cacheService: MediaCache, collections: [ArchivePinboard] = [], write: ArchiveWrite = { try $0() }
  ) throws -> ArchiveSummary {
    var sidecarCount = 0
    var totalSidecarBytes = 0
    var archivedItems: [ArchiveItem] = []
    archivedItems.reserveCapacity(items.count)
    for item in items {
      let sidecars = archivedSidecars(for: item, cacheService: cacheService)
      totalSidecarBytes += sidecars.reduce(0) { $0 + $1.data.count }
      guard totalSidecarBytes <= AppConfig.maxPortableArchiveSidecarBytes else {
        throw ArchiveError.archiveTooLarge(AppConfig.maxPortableArchiveBytes)
      }
      sidecarCount += sidecars.count
      archivedItems.append(ArchiveItem(item: item, sidecars: sidecars))
    }

    let archive = ArchivePayload(
      formatVersion: Self.currentFormatVersion, createdBy: AppConfig.appName, exportedAt: Date(), collections: collections,
      items: archivedItems)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(archive)
    guard Self.isArchiveSizeAllowed(data.count) else { throw ArchiveError.archiveTooLarge(AppConfig.maxPortableArchiveBytes) }
    try write {
      try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    return ArchiveSummary(itemCount: items.count, sidecarCount: sidecarCount, skippedItemCount: 0, skippedSidecarCount: 0)
  }

  func importArchive(from url: URL, cacheService: MediaCache) throws -> ArchiveImport {
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, !Self.isArchiveSizeAllowed(size) {
      throw ArchiveError.archiveTooLarge(AppConfig.maxPortableArchiveBytes)
    }
    let data = try Data(contentsOf: url)
    guard Self.isArchiveSizeAllowed(data.count) else { throw ArchiveError.archiveTooLarge(AppConfig.maxPortableArchiveBytes) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let archive: ArchivePayload
    do { archive = try decoder.decode(ArchivePayload.self, from: data) } catch { throw ArchiveError.invalidArchive }
    guard archive.formatVersion <= Self.currentFormatVersion else { throw ArchiveError.unsupportedVersion(archive.formatVersion) }
    guard archive.formatVersion > 0 else { throw ArchiveError.invalidArchive }

    var importedItems: [Clip] = []
    var sidecarCount = 0
    var skippedItemCount = 0
    var skippedSidecarCount = 0
    var createdPaths: [String] = []
    var completed = false
    defer { if !completed { cacheService.removeManagedFiles(createdPaths) } }
    importedItems.reserveCapacity(archive.items.count)

    for archivedItem in archive.items {
      guard var item = archivedItem.clipboardItem() else {
        skippedItemCount += 1
        continue
      }

      // Storage identities are local. Never overwrite a live attachment with an
      // imported UUID, or trust absolute paths from a portable archive.
      let storageID = UUID()
      var roles = Set<String>()
      for sidecar in archivedItem.sidecars {
        guard roles.insert(sidecar.role.rawValue).inserted else { throw ArchiveError.invalidArchive }
        let path: String?
        switch sidecar.role {
        case .image:
          guard item.kind == .image || item.kind == .url else { throw ArchiveError.invalidArchive }
          path = cacheService.cacheImageSidecarData(sidecar.data, id: storageID)
          item.imagePath = path
          if item.kind == .image { item.payload = path ?? "" }
        case .thumbnail:
          guard item.kind == .image || item.kind == .url else { throw ArchiveError.invalidArchive }
          path = cacheService.cacheImageSidecarData(sidecar.data, id: storageID, fileNamePrefix: "thumb")
          item.thumbnailPath = path
        case .attachment:
          guard item.kind.usesManagedPayloadAttachment else { throw ArchiveError.invalidArchive }
          path = cacheService.cacheAttachmentData(sidecar.data, id: storageID, fileExtension: sidecar.fileExtension)
          item.payload = path ?? ""
        }
        guard let path else { throw ArchiveError.attachmentWriteFailed }
        createdPaths.append(path)
        sidecarCount += 1
      }
      if item.kind == .image || item.kind.usesManagedPayloadAttachment, item.payload.isEmpty {
        skippedItemCount += 1
        skippedSidecarCount += archivedItem.sidecars.count
        cacheService.removeCachedReferences(item)
        continue
      }
      importedItems.append(item)
    }

    let summary = ArchiveSummary(
      itemCount: importedItems.count, sidecarCount: sidecarCount, skippedItemCount: skippedItemCount,
      skippedSidecarCount: skippedSidecarCount)
    completed = true
    return ArchiveImport(items: importedItems, collections: archive.collections ?? [], summary: summary, createdPaths: createdPaths)
  }

  private func archivedSidecars(for item: Clip, cacheService: MediaCache) -> [ArchiveSidecar] {
    var sidecars: [ArchiveSidecar] = []
    var archivedPaths = Set<String>()

    func append(_ role: ArchiveSidecarRole, path: String?, fallbackExtension: String) {
      guard let path, cacheService.isManagedSidecar(path: path), !archivedPaths.contains(path) else { return }
      guard let data = cacheService.data(for: path) else { return }
      archivedPaths.insert(path)
      sidecars.append(ArchiveSidecar(role: role, fileExtension: fileExtension(for: path, fallback: fallbackExtension), data: data))
    }

    if item.kind == .image {
      append(.image, path: item.imagePath ?? item.payload, fallbackExtension: "png")
      append(.thumbnail, path: item.thumbnailPath, fallbackExtension: "png")
    } else if item.kind == .url {
      append(.thumbnail, path: item.thumbnailPath, fallbackExtension: "png")
    } else if let ext = item.kind.attachmentExtension(for: item.payload) {
      append(.attachment, path: item.payload, fallbackExtension: ext)
    }

    return sidecars
  }

  private func fileExtension(for path: String, fallback: String) -> String {
    let ext = URL(fileURLWithPath: path).pathExtension.clipboardTrimmed
    return ext.isEmpty ? fallback : ext
  }

  static func isArchiveSizeAllowed(_ byteCount: Int) -> Bool { byteCount >= 0 && byteCount <= AppConfig.maxPortableArchiveBytes }
}

private struct ArchivePayload: Codable {
  let formatVersion: Int
  let createdBy: String
  let exportedAt: Date
  let collections: [ArchivePinboard]?
  let items: [ArchiveItem]

  init(formatVersion: Int, createdBy: String, exportedAt: Date, collections: [ArchivePinboard], items: [ArchiveItem]) {
    self.formatVersion = formatVersion
    self.createdBy = createdBy
    self.exportedAt = exportedAt
    self.collections = collections.isEmpty ? nil : collections
    self.items = items
  }
}

/// Archives flatten the same clip record used by history; only sidecars belong
/// to the portable envelope. Unknown kinds remain skippable, not decode errors.
private struct ArchiveItem: Codable {
  let item: Clip
  let sidecars: [ArchiveSidecar]
  private enum CodingKeys: String, CodingKey { case sidecars }

  init(item: Clip, sidecars: [ArchiveSidecar]) {
    self.item = item
    self.sidecars = sidecars
  }

  init(from decoder: Decoder) throws {
    item = try Clip(from: decoder)
    sidecars = try decoder.container(keyedBy: CodingKeys.self).decode([ArchiveSidecar].self, forKey: .sidecars)
  }

  func encode(to encoder: Encoder) throws {
    try item.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sidecars, forKey: .sidecars)
  }

  func clipboardItem() -> Clip? {
    guard item.hasKnownKind, (0...Int(Int32.max)).contains(item.useCount), item.createdAt.timeIntervalSince1970.isFinite,
      item.lastUsedAt.timeIntervalSince1970.isFinite, item.createdAt >= .distantPast, item.createdAt <= .distantFuture,
      item.lastUsedAt >= .distantPast, item.lastUsedAt <= .distantFuture
    else { return nil }
    var restored = item
    if item.kind == .image || item.kind.usesManagedPayloadAttachment { restored.payload = "" }
    restored.imagePath = nil
    restored.thumbnailPath = nil
    restored.customTitle = Clip.normalizedCustomTitle(item.customTitle)
    restored.sourceDeviceName = Clip.normalizedDeviceName(item.sourceDeviceName)
    return restored
  }
}

private struct ArchiveSidecar: Codable {
  let role: ArchiveSidecarRole
  let fileExtension: String
  let data: Data
}

private enum ArchiveSidecarRole: String, Codable {
  case image
  case thumbnail
  case attachment
}
