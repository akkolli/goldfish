import Foundation

struct CloudBackupStatus: Equatable {
  let isAvailable: Bool
  let archiveURL: URL?
  let lastModifiedAt: Date?
  let message: String
}

protocol CloudBackupServicing {
  func syncArchiveURL() throws -> URL
  func status() -> CloudBackupStatus
  @discardableResult func push(store: HistoryStore, write: ArchiveWrite) throws -> ArchiveSummary
  @discardableResult func pull(store: HistoryStore) throws -> ArchiveSummary
}

extension CloudBackupServicing {
  @discardableResult func push(store: HistoryStore) throws -> ArchiveSummary { try push(store: store, write: { try $0() }) }
}

enum CloudBackupError: LocalizedError, Equatable {
  case unavailable
  case cancelled
  case noRemoteArchive(URL)

  var errorDescription: String? {
    switch self {
    case .cancelled: return "iCloud Backup was cancelled because its settings changed."
    case .unavailable:
      return "iCloud Backup is unavailable. Sign Goldfish with an iCloud container entitlement and make sure iCloud Drive is enabled."
    case .noRemoteArchive: return "No Goldfish iCloud archive has been created yet."
    }
  }
}

final class CloudBackup: CloudBackupServicing {
  static let archiveFileName = "Goldfish.\(HistoryArchive.fileExtension)"

  private let fileManager: FileManager
  private let containerProvider: () -> URL?

  init(
    fileManager: FileManager = .default,
    containerProvider: @escaping () -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: nil) }
  ) {
    self.fileManager = fileManager
    self.containerProvider = containerProvider
  }

  func syncArchiveURL() throws -> URL {
    guard let containerURL = containerProvider() else { throw CloudBackupError.unavailable }

    let directory = containerURL.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(
      AppConfig.storageDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let target = directory.appendingPathComponent(Self.archiveFileName)
    let legacy = containerURL.appendingPathComponent("Documents").appendingPathComponent(GoldfishMigration.legacyDirectoryName)
      .appendingPathComponent(GoldfishMigration.legacyDirectoryName + "." + GoldfishMigration.legacyArchiveExtension)
    if !fileManager.fileExists(atPath: target.path), fileManager.fileExists(atPath: legacy.path) {
      startDownloadingIfNeeded(legacy)
      try fileManager.copyItem(at: legacy, to: target)
    }
    return target
  }

  func status() -> CloudBackupStatus {
    do {
      let url = try syncArchiveURL()
      let attributes = try? fileManager.attributesOfItem(atPath: url.path)
      let lastModifiedAt = attributes?[.modificationDate] as? Date
      let message: String
      if lastModifiedAt != nil { message = "iCloud Backup is ready." } else { message = "iCloud Backup is ready. No backup archive yet." }
      return CloudBackupStatus(isAvailable: true, archiveURL: url, lastModifiedAt: lastModifiedAt, message: message)
    } catch { return CloudBackupStatus(isAvailable: false, archiveURL: nil, lastModifiedAt: nil, message: error.localizedDescription) }
  }

  @discardableResult func push(store: HistoryStore, write: ArchiveWrite) throws -> ArchiveSummary {
    let url = try syncArchiveURL()
    return try store.exportArchive(to: url, write: write)
  }

  @discardableResult func pull(store: HistoryStore) throws -> ArchiveSummary {
    let url = try syncArchiveURL()
    guard fileManager.fileExists(atPath: url.path) else { throw CloudBackupError.noRemoteArchive(url) }

    startDownloadingIfNeeded(url)
    return try store.importArchive(from: url)
  }

  private func startDownloadingIfNeeded(_ url: URL) {
    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
    guard values?.isUbiquitousItem == true else { return }
    try? fileManager.startDownloadingUbiquitousItem(at: url)
  }
}
