import AppKit
import SQLite3
import XCTest

@testable import Goldfish

final class GoldfishMigrationTests: IsolatedTestCase {
  private let encryption = testEncryption(byte: 71)

  func testEncryptedHistoryAndAttachmentsMoveWithoutChangingOriginals() throws {
    let parent = try makeTempDirectory()
    let source = parent.appendingPathComponent(GoldfishMigration.legacyDirectoryName)
    let target = parent.appendingPathComponent("Goldfish")
    let defaults = makeTestDefaults(retention: .forever)
    let item = try seed(source, defaults: defaults)
    let database = source.appendingPathComponent("history.sqlite")
    try convertToLegacyMarker(database)
    let oldSidecar = try XCTUnwrap(item.imagePath)
    let sidecarData = try Data(contentsOf: URL(fileURLWithPath: oldSidecar))
    try (Data(GoldfishMigration.legacyEncryptionMarker.utf8) + sidecarData.dropFirst(HistoryEncryption.marker.utf8.count)).write(
      to: URL(fileURLWithPath: oldSidecar))
    let orphan = source.appendingPathComponent("images/retired-key-cache.bin")
    let orphanBody = try testEncryption(byte: 99).protectDataForStorage(Data("unused older cache".utf8)).dropFirst(
      HistoryEncryption.marker.utf8.count)
    try (Data(GoldfishMigration.legacyEncryptionMarker.utf8) + orphanBody).write(to: orphan)
    let originalDatabase = try Data(contentsOf: database)
    let originalSidecar = try Data(contentsOf: URL(fileURLWithPath: oldSidecar))
    try GoldfishMigration.migrateDirectory(from: source, to: target, encryptionProvider: { _ in self.encryption })
    XCTAssertEqual(try Data(contentsOf: database), originalDatabase)
    let migratedOrphan = try Data(contentsOf: target.appendingPathComponent("images/retired-key-cache.bin"))
    XCTAssertTrue(migratedOrphan.starts(with: Data(HistoryEncryption.marker.utf8)))
    XCTAssertEqual(Data(migratedOrphan.dropFirst(HistoryEncryption.marker.utf8.count)), Data(orphanBody))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: oldSidecar)), originalSidecar)
    let settings = SettingsModel(defaults: defaults)
    let cache = MediaCache(baseURL: target, encryptionService: encryption)
    let store = HistoryStore(settings: settings, cacheService: cache, baseURL: target, encryptionService: encryption)
    XCTAssertNil(store.loadWarningMessage)
    let restored = try XCTUnwrap(store.items.first)
    XCTAssertEqual(restored.id, item.id)
    XCTAssertEqual(restored.sourceApp, "legacy plaintext migration fixture")
    XCTAssertNil(
      try Data(contentsOf: target.appendingPathComponent("history.sqlite")).range(of: Data("legacy plaintext migration fixture".utf8)))
    XCTAssertEqual(restored.collectionName, "Examples")
    XCTAssertTrue(restored.isPinned)
    XCTAssertEqual(restored.payload, target.appendingPathComponent("images/example.png").path)
    XCTAssertEqual(restored.imagePath, restored.payload)
    XCTAssertEqual(cache.data(for: restored.payload), Data("private attachment".utf8))
    XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: restored.payload)).starts(with: Data(HistoryEncryption.marker.utf8)))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: restored.payload)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try GoldfishMigration.migrateDirectory(
      from: source, to: target,
      encryptionProvider: { _ in
        XCTFail("Must not rerun migration")
        return self.encryption
      })
  }

  func testMissingWrongKeysAndCorruptDatabaseNeverPublishPartialProfile() throws {
    for scenario in ["missing", "wrong", "corrupt"] {
      let parent = try makeTempDirectory()
      let source = parent.appendingPathComponent("Old")
      let target = parent.appendingPathComponent("Goldfish")
      _ = try seed(source, defaults: makeTestDefaults(retention: .forever))
      let db = source.appendingPathComponent("history.sqlite")
      if scenario == "corrupt" { try Data("not a database".utf8).write(to: db) }
      let before = try Data(contentsOf: db)
      let key =
        scenario == "missing"
        ? HistoryEncryption(keyProvider: { nil }, allowsUnencryptedStorage: false)
        : (scenario == "wrong" ? testEncryption(byte: 99) : encryption)
      XCTAssertThrowsError(try GoldfishMigration.migrateDirectory(from: source, to: target, encryptionProvider: { _ in key }))
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      XCTAssertEqual(try Data(contentsOf: db), before)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Old"])
    }
  }

  func testLegacyJSONRelocatesOnlyManagedMediaAndRejectsSymlinks() throws {
    let parent = try makeTempDirectory()
    let source = parent.appendingPathComponent("Old")
    let target = parent.appendingPathComponent("Goldfish")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let oldPath = source.appendingPathComponent("images/example.png").path
    let rows: [[String: Any]] = [
      ["kind": ClipKind.image.rawValue, "payload": oldPath], ["kind": ClipKind.text.rawValue, "payload": oldPath],
    ]
    try JSONSerialization.data(withJSONObject: rows).write(to: source.appendingPathComponent("history.json"))
    try GoldfishMigration.migrateDirectory(from: source, to: target)
    let migrated = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("history.json"))) as? [[String: Any]])
    XCTAssertEqual(migrated[0]["payload"] as? String, target.appendingPathComponent("images/example.png").path)
    XCTAssertEqual(migrated[1]["payload"] as? String, oldPath)
    let link = source.appendingPathComponent("external")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
    XCTAssertThrowsError(try GoldfishMigration.migrateDirectory(from: source, to: parent.appendingPathComponent("Other")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Other").path))
  }

  func testPreferencesAndCloudBackupPreserveExistingGoldfishChoices() throws {
    let defaults = makeTestDefaults()
    defaults.set(false, forKey: "launchAtLogin")
    GoldfishMigration.migratePreferences(
      from: ["launchAtLogin": true, "onboardingCompleted": true, "customCollectionNames": ["Examples"]], to: defaults)
    XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
    XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted"))
    XCTAssertEqual(defaults.stringArray(forKey: "customCollectionNames"), ["Examples"])
    let container = try makeTempDirectory()
    let old = container.appendingPathComponent(
      "Documents/\(GoldfishMigration.legacyDirectoryName)/\(GoldfishMigration.legacyDirectoryName).\(GoldfishMigration.legacyArchiveExtension)"
    )
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old portable archive".utf8).write(to: old)
    let backup = CloudBackup(containerProvider: { container })
    let new = try backup.syncArchiveURL()
    XCTAssertEqual(new.lastPathComponent, "Goldfish.goldfisharchive")
    XCTAssertEqual(try Data(contentsOf: new), try Data(contentsOf: old))
    try Data("newer backup".utf8).write(to: new)
    _ = try backup.syncArchiveURL()
    XCTAssertEqual(try Data(contentsOf: new), Data("newer backup".utf8))
    XCTAssertEqual(HistoryArchive.fileExtension, "goldfisharchive")
  }

  func testMigrationKeepsOnlyAnExistingDurableFallbackWhenKeychainIsUnavailable() {
    let original = Data(repeating: 71, count: 32)
    let different = Data(repeating: 99, count: 32)
    XCTAssertEqual(HistoryEncryption.migrationKeyData(legacyData: original, savedData: original, hasExistingFallback: false), original)
    XCTAssertEqual(HistoryEncryption.migrationKeyData(legacyData: original, savedData: nil, hasExistingFallback: true), original)
    XCTAssertNil(HistoryEncryption.migrationKeyData(legacyData: original, savedData: nil, hasExistingFallback: false))
    XCTAssertNil(HistoryEncryption.migrationKeyData(legacyData: original, savedData: different, hasExistingFallback: true))
  }

  private func seed(_ directory: URL, defaults: UserDefaults) throws -> Clip {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("images/example.png")
    try encryption.protectDataForStorage(Data("private attachment".utf8)).write(to: path)
    let item = testItem(kind: .image, payload: path.path, imagePath: path.path, isPinned: true, collectionName: "Examples")
    let settings = SettingsModel(defaults: defaults)
    let cache = MediaCache(baseURL: directory, encryptionService: encryption)
    let store = HistoryStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption)
    XCTAssertNotNil(store.upsert(item))
    store.flushPersistence()
    return item
  }

  private func convertToLegacyMarker(_ url: URL) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let fields = [
      "display_text", "payload", "payload_hash", "source_app", "source_app_bundle_id", "image_path", "thumbnail_path", "ocr_text",
      "collection_name", "custom_title", "source_device_name",
    ]
    let update = fields.map { "\($0)=replace(\($0),'\(HistoryEncryption.marker)','\(GoldfishMigration.legacyEncryptionMarker)')" }.joined(
      separator: ",")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE clipboard_items SET \(update);", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "PRAGMA secure_delete=OFF; UPDATE clipboard_items SET source_app='legacy plaintext migration fixture'; CREATE TABLE old_plaintext(value TEXT); INSERT INTO old_plaintext VALUES ('legacy plaintext migration fixture'); DROP TABLE old_plaintext;",
        nil, nil, nil), SQLITE_OK)
  }
}
