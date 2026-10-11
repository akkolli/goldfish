import AppKit
import SQLite3
import XCTest

@testable import Goldfish

final class PersistenceSafetyTests: StoredClipboardTestCase {
  func testFailedMutationsPreserveMemoryDatabaseAndAttachments() throws {
    let note = item("original")
    let path = try XCTUnwrap(cache.cachePDF(Data("attachment".utf8), id: UUID()))
    store.upsert(note)
    store.upsert(item(path, kind: .pdf))
    let original = store.items
    try sql("CREATE TRIGGER reject_insert BEFORE INSERT ON clipboard_items BEGIN SELECT RAISE(ABORT, 'test failure'); END;")
    try sql("CREATE TRIGGER reject_delete BEFORE DELETE ON clipboard_items BEGIN SELECT RAISE(ABORT, 'test failure'); END;")
    XCTAssertFalse(store.updateText(note.id, text: "edited"))
    XCTAssertFalse(store.setCollection(note.id, name: "New board"))
    XCTAssertFalse(store.togglePin(note.id))
    XCTAssertNil(store.upsert(item("new clip")))
    XCTAssertNil(store.remove(note.id))
    XCTAssertFalse(store.removeAll())
    cache.flushForTesting()
    XCTAssertEqual(store.items, original)
    XCTAssertEqual(Set(reopen().items.map(\.payload)), Set(original.map(\.payload)))
    XCTAssertEqual(cache.data(for: path), Data("attachment".utf8))
    XCTAssertNotNil(store.persistenceWarningMessage)
    try sql("DROP TRIGGER reject_insert; DROP TRIGGER reject_delete;")
    XCTAssertTrue(store.updateText(note.id, text: "retry"))
    XCTAssertNil(store.persistenceWarningMessage)
    XCTAssertEqual(reopen().items.first { $0.id == note.id }?.payload, "retry")
    var locked: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &locked), SQLITE_OK)
    defer { sqlite3_close(locked) }
    XCTAssertEqual(sqlite3_exec(locked, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
    XCTAssertFalse(store.updateText(note.id, text: "blocked"))
    XCTAssertEqual(store.items.first { $0.id == note.id }?.payload, "retry")
    XCTAssertEqual(sqlite3_exec(locked, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
    XCTAssertTrue(store.updateText(note.id, text: "after lock"))
  }

  func testFailedImportPreservesAttachmentsAndCollectionPreferences() throws {
    let path = try XCTUnwrap(cache.cacheImageSidecarData(Data("original".utf8), id: UUID()))
    let image = item(path, kind: .image, imagePath: path)
    store.upsert(image)
    let archive = directory.appendingPathComponent("test.clipboredarchive")
    try store.exportArchive(to: archive)
    try editArchive(archive) { json in
      var rows = json["items"] as! [[String: Any]]
      rows[0]["sidecars"] = [["role": "image", "fileExtension": "png", "data": Data("replacement".utf8).base64EncodedString()]]
      rows[0]["collectionName"] = "Imported board"
      json["items"] = rows
      json["collections"] = [["name": "Imported board", "colorHex": "#3366FF"]]
    }
    try sql("CREATE TRIGGER reject_import BEFORE INSERT ON clipboard_items BEGIN SELECT RAISE(ABORT, 'test failure'); END;")
    XCTAssertThrowsError(try store.importArchive(from: archive))
    cache.flushForTesting()
    XCTAssertEqual(cache.data(for: path), Data("original".utf8))
    XCTAssertEqual(store.items, [image])
    XCTAssertFalse(settings.customCollectionNames.contains("Imported board"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("images").path).count, 1)
    try sql("DROP TRIGGER reject_import;")
    try store.importArchive(from: archive)
    let imported = try XCTUnwrap(store.items.first)
    XCTAssertNotEqual(imported.imagePath, path)
    XCTAssertEqual(cache.data(for: imported.payload), Data("replacement".utf8))
    XCTAssertEqual(imported.collectionName, "Imported board")
    XCTAssertTrue(settings.customCollectionNames.contains("Imported board"))
  }

  func testArchiveAndCacheNeverOwnExternalOrSymlinkedFiles() throws {
    let foreign = directory.appendingPathComponent("unrelated.txt")
    try Data("keep me".utf8).write(to: foreign)
    let link = directory.appendingPathComponent("images/link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
    let owned = try XCTUnwrap(cache.cacheImageSidecarData(Data("owned".utf8), id: UUID()))
    let outsideLink = directory.appendingPathComponent("outside-link.png")
    try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: URL(fileURLWithPath: owned))
    for path in [foreign.path, link.path, outsideLink.path] {
      let image = item(path, kind: .image, imagePath: path)
      XCTAssertFalse(cache.isManagedSidecar(path: path))
      cache.removeCachedReferences(image)
      let archive = directory.appendingPathComponent("unsafe.clipboredarchive")
      try ClipboardArchiveService().exportArchive(items: [image], to: archive, cacheService: cache)
      let summary = try store.importArchive(from: archive)
      XCTAssertEqual(summary.skippedItemCount, 1)
      XCTAssertTrue(store.items.isEmpty)
    }
    cache.flushForTesting()
    XCTAssertEqual(try Data(contentsOf: foreign), Data("keep me".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideLink.path))
    XCTAssertEqual(cache.data(for: owned), Data("owned".utf8))
    let note = item("valid")
    store.upsert(note)
    let archive = directory.appendingPathComponent("invalid-count.clipboredarchive")
    try store.exportArchive(to: archive)
    try editArchive(archive) { json in
      var rows = json["items"] as! [[String: Any]]
      rows[0]["useCount"] = Int.max
      json["items"] = rows
    }
    XCTAssertEqual(try store.importArchive(from: archive).skippedItemCount, 1)
    XCTAssertEqual(store.items, [note])
  }

  func testStartupPreservesLegacyAndUserNamedPinboardsBeyondRetention() throws {
    settings.historyRetention = .oneMonth
    for name in ["Useful Links", "Important Notes", "Code Snippets", "Read Later", "My board"] {
      var old = item(name)
      old.collectionName = name
      old.createdAt = Date().addingTimeInterval(-60 * 86400)
      store.upsert(old)
    }
    let original = store.items
    AppDelegate.restoreCollectionMetadata(settings: settings, store: store)
    XCTAssertEqual(store.items, original)
    XCTAssertEqual(Set(settings.customCollectionNames), Set(original.compactMap(\.collectionName)))
    XCTAssertEqual(reopen().items.count, 5)
  }

  func testUnavailableAndCorruptDatabaseStayReadOnly() throws {
    for corrupt in [false, true] {
      let base = directory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let database = base.appendingPathComponent("history.sqlite")
      if corrupt {
        try Data("not a database".utf8).write(to: database)
      } else {
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
      }
      let damaged = ClipboardStore(settings: settings, cacheService: cache, baseURL: base, encryptionService: encryption)
      XCTAssertFalse(damaged.canPersistHistory)
      XCTAssertNotNil(damaged.loadWarningMessage)
      XCTAssertNil(damaged.upsert(item("must not save")))
      XCTAssertFalse(damaged.removeAll())
      if corrupt { XCTAssertEqual(try Data(contentsOf: database), Data("not a database".utf8)) }
    }
  }

  private func item(_ text: String, kind: ClipboardItemKind = .text, imagePath: String? = nil) -> ClipboardItem {
    testItem(kind: kind, payload: text, createdAt: Date(), lastUsedAt: Date(), useCount: 0, imagePath: imagePath)
  }
  private func sql(_ statement: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK)
  }
  private func editArchive(_ url: URL, _ edit: (inout [String: Any]) -> Void) throws {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    edit(&json)
    try JSONSerialization.data(withJSONObject: json).write(to: url)
  }
}
