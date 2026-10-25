import AppKit
import Foundation
import SQLite3

/// Old names exist only at the import boundary. All new writes use Goldfish.
enum GoldfishMigration {
  static let legacyDirectoryName = "ClipBored"
  static let legacyBundleIdentifier = "com.local.clipbored"
  static let legacyEncryptionMarker = "clipbored:v1:"
  static let legacyArchiveExtension = "clipboredarchive"
  private static let completionKey = "goldfishIdentityMigrationComplete"
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  enum Failure: LocalizedError {
    case olderAppRunning, invalidStorage, unreadableHistory, unavailableEncryption
    var errorDescription: String? {
      switch self {
      case .olderAppRunning: return "An older app copy is still running."
      case .invalidStorage: return "The old data folder contains an unsupported file or symbolic link."
      case .unreadableHistory: return "The old history database could not be read or verified."
      case .unavailableEncryption: return "The existing encryption key is unavailable or does not decrypt the saved history."
      }
    }
  }

  static func prepare() throws {
    // Development and test storage must never import the user's real profile.
    guard Bundle.main.bundleIdentifier == "com.local.goldfish",
      ProcessInfo.processInfo.environment[AppConfig.storageDirectoryOverrideEnvironmentKey] == nil
    else { return }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleIdentifier).isEmpty else {
      throw Failure.olderAppRunning
    }
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: completionKey) else { return }
    let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try migrateDirectory(
      from: parent.appendingPathComponent(legacyDirectoryName), to: parent.appendingPathComponent(AppConfig.storageDirectoryName))
    migratePreferences(from: defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:], to: defaults)
    defaults.set(true, forKey: completionKey)
  }

  static func migratePreferences(from legacy: [String: Any], to defaults: UserDefaults) {
    // Preserve any settings already chosen in the new profile, including false.
    for (key, value) in legacy where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
  }

  static func migrateDirectory(
    from source: URL, to destination: URL, encryptionProvider: (URL) throws -> HistoryEncryption = HistoryEncryption.migrationEncryption
  ) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { return }
    let stage = destination.deletingLastPathComponent().appendingPathComponent(".Goldfish-migration-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: stage) }
    guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.invalidStorage }
    try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
      try fm.copyItem(at: child, to: stage.appendingPathComponent(child.lastPathComponent))
    }
    let files = try contents(of: stage)
    for url in [stage] + files {
      let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard info.isSymbolicLink != true else { throw Failure.invalidStorage }
      try fm.setAttributes([.posixPermissions: info.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
    let database = stage.appendingPathComponent("history.sqlite")
    let sidecars = try ["images", "thumbnails", "attachments"].flatMap { name -> [URL] in
      let directory = stage.appendingPathComponent(name)
      guard fm.fileExists(atPath: directory.path) else { return [] }
      return try contents(of: directory).filter { (try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    if fm.fileExists(atPath: database.path) || !sidecars.isEmpty {
      let encryption: HistoryEncryption
      do { encryption = try encryptionProvider(stage) } catch { throw Failure.unavailableEncryption }
      guard encryption.isAvailable else { throw Failure.unavailableEncryption }
      if fm.fileExists(atPath: database.path) {
        try rewriteDatabase(database, source: source, destination: destination, encryption: encryption)
      }
      for url in sidecars {
        let stored = try Data(contentsOf: url)
        // The prefix is format metadata, not authenticated ciphertext. Carry the
        // encrypted body unchanged: old, unreferenced cache files may use a
        // retired key and must not prevent recovery of the live history.
        let legacyPrefix = Data(legacyEncryptionMarker.utf8)
        let migrated: Data
        if stored.starts(with: legacyPrefix) {
          migrated = Data(HistoryEncryption.marker.utf8) + stored.dropFirst(legacyPrefix.count)
        } else if HistoryEncryption.isProtected(stored) {
          migrated = stored
        } else {
          migrated = try encryption.protectDataForStorage(stored)
        }
        try migrated.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    }
    let json = stage.appendingPathComponent("history.json")
    if fm.fileExists(atPath: json.path) {
      guard var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]] else {
        throw Failure.unreadableHistory
      }
      for index in rows.indices {
        for field in ["payload", "imagePath", "thumbnailPath"] {
          if field == "payload", !isMedia(rows[index]["kind"] as? Int ?? -1) { continue }
          if let path = rows[index][field] as? String { rows[index][field] = relocated(path, from: source, to: destination) }
        }
      }
      try JSONSerialization.data(withJSONObject: rows).write(to: json, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: json.path)
    }
    // Atomic publication: an interrupted/failed migration never exposes a partial profile.
    try fm.moveItem(at: stage, to: destination)
  }

  private static func contents(of directory: URL) throws -> [URL] {
    var failure: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        errorHandler: { _, error in
          failure = error
          return false
        })
    else { throw Failure.invalidStorage }
    let files = enumerator.allObjects.compactMap { $0 as? URL }
    if let failure { throw failure }
    return files
  }

  private static func relocated(_ path: String, from source: URL, to destination: URL) -> String {
    for root in Set([source.path, source.resolvingSymlinksInPath().path]) {
      for directory in ["images", "thumbnails", "attachments"] {
        let prefix = root + "/" + directory + "/"
        if path.hasPrefix(prefix) { return destination.appendingPathComponent(directory).path + "/" + path.dropFirst(prefix.count) }
      }
    }
    return path
  }

  private static func isMedia(_ kind: Int) -> Bool { [.image, .richText, .audio, .pdf, .video].contains(ClipKind(rawValue: kind)) }

  private static func rewriteDatabase(_ url: URL, source: URL, destination: URL, encryption: HistoryEncryption) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      if let db { sqlite3_close(db) }
      throw Failure.unreadableHistory
    }
    defer { sqlite3_close(db) }
    func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unreadableHistory } }
    try execute("PRAGMA secure_delete=ON; PRAGMA journal_mode=DELETE; BEGIN IMMEDIATE;")
    var committed = false
    defer { if !committed { try? execute("ROLLBACK;") } }
    var schema: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(clipboard_items);", -1, &schema, nil) == SQLITE_OK else {
      throw Failure.unreadableHistory
    }
    var available = Set<String>()
    while sqlite3_step(schema) == SQLITE_ROW { if let text = sqlite3_column_text(schema, 1) { available.insert(String(cString: text)) } }
    sqlite3_finalize(schema)
    guard Set(["id", "kind", "display_text", "payload", "payload_hash"]).isSubset(of: available) else { throw Failure.unreadableHistory }
    let columns = [
      "display_text", "payload", "payload_hash", "source_app", "source_app_bundle_id", "image_path", "thumbnail_path", "ocr_text",
      "collection_name", "custom_title", "source_device_name",
    ].filter { available.contains($0) }
    var read: OpaquePointer?
    var write: OpaquePointer?
    defer {
      sqlite3_finalize(read)
      sqlite3_finalize(write)
    }
    guard
      sqlite3_prepare_v2(db, "SELECT rowid, kind, \(columns.joined(separator: ",")) FROM clipboard_items;", -1, &read, nil) == SQLITE_OK,
      sqlite3_prepare_v2(
        db, "UPDATE clipboard_items SET \(columns.map { $0 + "=?" }.joined(separator: ",")) WHERE rowid=?;", -1, &write, nil) == SQLITE_OK
    else { throw Failure.unreadableHistory }
    var result = sqlite3_step(read)
    while result == SQLITE_ROW {
      sqlite3_reset(write)
      sqlite3_clear_bindings(write)
      for (index, column) in columns.enumerated() {
        guard let raw = sqlite3_column_text(read, Int32(index + 2)) else { continue }
        let stored = String(cString: raw)
        guard var value = encryption.unprotect(stored), !HistoryEncryption.isProtected(value) else { throw Failure.unavailableEncryption }
        if ["image_path", "thumbnail_path"].contains(column) || (column == "payload" && isMedia(Int(sqlite3_column_int(read, 1)))) {
          value = relocated(value, from: source, to: destination)
        }
        guard let encrypted = encryption.protect(value), sqlite3_bind_text(write, Int32(index + 1), encrypted, -1, transient) == SQLITE_OK
        else { throw Failure.unavailableEncryption }
      }
      sqlite3_bind_int64(write, Int32(columns.count + 1), sqlite3_column_int64(read, 0))
      guard sqlite3_step(write) == SQLITE_DONE else { throw Failure.unreadableHistory }
      result = sqlite3_step(read)
    }
    guard result == SQLITE_DONE else { throw Failure.unreadableHistory }
    sqlite3_finalize(read)
    read = nil
    sqlite3_finalize(write)
    write = nil
    try execute("COMMIT;")
    committed = true
    // Do not carry old plaintext in free pages into the published profile.
    try execute("VACUUM;")
    var check: OpaquePointer?
    defer { sqlite3_finalize(check) }
    guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &check, nil) == SQLITE_OK, sqlite3_step(check) == SQLITE_ROW,
      let text = sqlite3_column_text(check, 0), String(cString: text) == "ok"
    else { throw Failure.unreadableHistory }
  }
}
