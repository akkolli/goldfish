import AppKit
import SQLite3
import XCTest

@testable import Goldfish

final class HistoryStoreTests: StoredClipboardTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    settings.maxHistoryItems = 50
  }
  func testUpsertReplacesAnExistingIdentifierWithoutDuplicatingIt() throws {
    for prune in [false, true] {
      try resetStorage()
      settings.pruneDuplicates = prune
      let original = testItem(payload: "old", createdAt: Date(timeIntervalSince1970: 100))
      store.upsert(original)
      let replacement = testItem(id: original.id, payload: "updated", createdAt: Date(timeIntervalSince1970: 200))
      XCTAssertEqual(store.upsert(replacement), replacement)
      XCTAssertEqual(store.items, [replacement], "One ID must have one live record; pruneDuplicates=\(prune)")
      XCTAssertEqual(reopen().items, [replacement])
    }
  }

  func testLegacyJSONHistoryMigratesToSQLite() throws {
    let itemID = UUID()
    let row: [String: Any] = [
      "id": itemID.uuidString, "kind": 0, "displayText": "Legacy Note", "payload": "legacy payload", "payloadHash": "legacy-hash",
      "createdAt": "2026-06-27T12:00:00Z", "lastUsedAt": "2026-06-27T12:01:00Z", "useCount": 3, "sourceApp": "Notes", "imagePath": NSNull(),
      "thumbnailPath": NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: [row]).write(to: directory.appendingPathComponent("history.json"))

    XCTAssertEqual(store.items.count, 1)
    XCTAssertEqual(store.items.first?.id, itemID)
    XCTAssertEqual(store.items.first?.payload, "legacy payload")
    XCTAssertEqual(store.items.first?.useCount, 3)
    XCTAssertEqual(store.items.first?.sourceDeviceName, Clip.localDeviceName)

    let restored = makeStore()
    XCTAssertEqual(restored.items.first?.payload, "legacy payload")
    XCTAssertEqual(restored.items.first?.sourceDeviceName, Clip.localDeviceName)
  }

  func testImportCannotReplaceUnreadableHistory() throws {
    let writer = makeStore(encryptionService: testEncryption(byte: 7))
    writer.upsert(makeItem("must remain recoverable", displayText: "Private", created: Date()))
    let archive = directory.appendingPathComponent("backup.goldfisharchive")
    try writer.exportArchive(to: archive)
    let reader = makeStore(encryptionService: testEncryption(byte: 9))
    XCTAssertThrowsError(try reader.exportArchive(to: archive))
    XCTAssertThrowsError(try reader.exportCollection(named: "Private", to: archive))
    XCTAssertThrowsError(try reader.importArchive(from: archive)) { error in
      guard case HistoryWriteError.unreadableHistory = error else { return XCTFail("Expected a recoverable-history protection error") }
    }
    let restored = makeStore(encryptionService: testEncryption(byte: 7))
    XCTAssertEqual(restored.items.map(\.payload), ["must remain recoverable"])
  }

  func testUnavailableEncryptionKeyDoesNotSavePlaintextOrPretendToCapture() throws {
    let encryption = HistoryEncryption(keyProvider: { nil }, allowsUnencryptedStorage: false)
    let store = makeStore(encryptionService: encryption)
    store.upsert(makeItem("never persist this plaintext", displayText: "Private", created: Date()))
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertFalse(try databaseText().contains("never persist this plaintext"))
    XCTAssertTrue(settings.status(.capture).contains("encryption key"))
    let secureCache = MediaCache(baseURL: directory, encryptionService: encryption)
    XCTAssertNil(secureCache.cacheMedia(.pdf, Data("private attachment".utf8), id: UUID()))
  }

  func testRemoveCanDeferManagedCachePurgeForUndoRestore() throws {
    let cachedImage = try XCTUnwrap(cache.cacheImage(testImage(color: .systemBlue), id: UUID()))
    let item = makeImageItem(
      fullPath: cachedImage.full, thumbPath: cachedImage.thumb, hash: "undo-image", ocrText: "undo searchable text",
      created: Date(timeIntervalSince1970: 10))
    store.upsert(item)

    let removal = try XCTUnwrap(store.remove(item.id, purgeManagedCache: false))
    cache.flushForTesting()

    XCTAssertTrue(store.items.isEmpty)
    for path in [cachedImage.full, cachedImage.thumb] { XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }
    store.restore([removal])
    for history in [store, makeStore()] { XCTAssertEqual(history.items, [item]) }
    for path in [cachedImage.full, cachedImage.thumb] { XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }
    _ = store.remove(item.id)
    cache.flushForTesting()
    for path in [cachedImage.full, cachedImage.thumb] { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
  }

  func testArchiveExportImportMovesHistoryAndManagedAttachmentsToNewStorage() throws {
    let cachedImage = try XCTUnwrap(cache.cacheImage(testImage(color: .systemBlue), id: UUID()))
    let sourceFullImageData = try XCTUnwrap(cache.data(for: cachedImage.full))
    let sourceThumbData = try XCTUnwrap(cache.data(for: cachedImage.thumb))
    let sourcePDFData = Data("%PDF archive payload".utf8)
    let sourcePDFPath = try XCTUnwrap(cache.cacheMedia(.pdf, sourcePDFData, id: UUID()))
    let created = Date(timeIntervalSince1970: 300)

    var note = makeItem("archive note", displayText: "Archive Note", created: created)
    note.collectionName = "Read Later"
    note.customTitle = "Migration Note"
    note.sourceDeviceName = "Studio Mac"
    var image = makeImageItem(
      fullPath: cachedImage.full, thumbPath: cachedImage.thumb, hash: "archive-image", ocrText: "blue archive image",
      created: created.addingTimeInterval(1))
    image.isPinned = true
    image.collectionName = "Client Work"
    image.customTitle = "Launch Screenshot"
    image.sourceDeviceName = "MacBook Pro"
    var pdf = makePDFItem(path: sourcePDFPath, hash: "archive-pdf", created: created.addingTimeInterval(2))
    pdf.collectionName = "Research"
    pdf.sourceDeviceName = "Design Mac"

    store.upsert(note)
    store.upsert(image)
    store.upsert(pdf)

    let archiveURL = directory.appendingPathComponent("backup.goldfisharchive")
    let exportSummary = try store.exportArchive(to: archiveURL)

    XCTAssertEqual(exportSummary.itemCount, 3)
    XCTAssertEqual(exportSummary.sidecarCount, 3)
    XCTAssertEqual(try testPermissions(archiveURL), 0o600)

    let destination = try makeStorage(retention: .forever, limit: 50)
    let localNote = makeItem("destination only", displayText: "Destination", created: created.addingTimeInterval(3))
    destination.store.upsert(localNote)
    let imported = try destination.store.importArchive(from: archiveURL)
    XCTAssertEqual(imported.itemCount, 3)
    XCTAssertEqual(imported.sidecarCount, 3)
    let importedImage = try XCTUnwrap(destination.store.items.first { $0.id == image.id })
    let imagePath = try XCTUnwrap(importedImage.imagePath)
    let thumbPath = try XCTUnwrap(importedImage.thumbnailPath)
    let importedPDF = try XCTUnwrap(destination.store.items.first { $0.id == pdf.id })
    for (path, originalPath, bytes) in [
      (imagePath, cachedImage.full, sourceFullImageData), (thumbPath, cachedImage.thumb, sourceThumbData),
      (importedPDF.payload, sourcePDFPath, sourcePDFData),
    ] {
      XCTAssertTrue(path.hasPrefix(destination.directory.path))
      XCTAssertNotEqual(path, originalPath)
      XCTAssertEqual(destination.cache.data(for: path), bytes)
    }
    image.payload = imagePath
    image.imagePath = imagePath
    image.thumbnailPath = thumbPath
    pdf.payload = importedPDF.payload
    let expected = [localNote, pdf, image, note]
    for history in [destination.store, destination.reopen()] { XCTAssertEqual(history.items, expected) }
  }
  private func makeStore(encryptionService: HistoryEncryption = testEncryption()) -> HistoryStore {
    HistoryStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryptionService)
  }

  private func makeItem(_ payload: String, displayText: String, created: Date) -> Clip {
    testItem(displayText: displayText, payload: payload, createdAt: created)
  }

  private func makePDFItem(path: String, hash: String, created: Date) -> Clip {
    testItem(kind: .pdf, displayText: "PDF", payload: path, payloadHash: hash, createdAt: created)
  }

  private func makeImageItem(fullPath: String, thumbPath: String, hash: String, ocrText: String?, created: Date) -> Clip {
    testItem(
      kind: .image, displayText: "Image", payload: fullPath, payloadHash: hash, createdAt: created, sourceApp: "Preview",
      imagePath: fullPath, thumbnailPath: thumbPath, sourceAppBundleId: "com.apple.Preview", ocrText: ocrText)
  }

  private func databaseText() throws -> String {
    let data = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
    return String(decoding: data, as: UTF8.self)
  }

}
final class PersistenceSafetyTests: StoredClipboardTestCase {
  func testFailedMutationsPreserveMemoryDatabaseAndAttachments() throws {
    let note = item("original")
    let path = try XCTUnwrap(cache.cacheMedia(.pdf, Data("attachment".utf8), id: UUID()))
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
    let archive = directory.appendingPathComponent("test.goldfisharchive")
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
      let archive = directory.appendingPathComponent("unsafe.goldfisharchive")
      _ = try HistoryArchive().exportArchive(items: [image], to: archive, cacheService: cache)
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
    let archive = directory.appendingPathComponent("invalid-count.goldfisharchive")
    for (key, invalid) in [("useCount", Int.max), ("useCount", -1), ("kind", 999)] {
      try store.exportArchive(to: archive)
      try editArchive(archive) { json in
        var rows = json["items"] as! [[String: Any]]
        XCTAssertEqual(rows[0]["kind"] as? Int, ClipKind.text.rawValue)
        XCTAssertNil(rows[0]["kindValue"])
        XCTAssertNil(rows[0]["item"], "Version 1 metadata must remain flat")
        rows[0][key] = invalid
        json["items"] = rows
      }
      XCTAssertEqual(try store.importArchive(from: archive).skippedItemCount, 1, key)
      XCTAssertEqual(store.items, [note], key)
    }
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
      let damaged = HistoryStore(settings: settings, cacheService: cache, baseURL: base, encryptionService: encryption)
      XCTAssertFalse(damaged.canPersistHistory)
      XCTAssertNotNil(damaged.loadWarningMessage)
      XCTAssertNil(damaged.upsert(item("must not save")))
      XCTAssertFalse(damaged.removeAll())
      if corrupt { XCTAssertEqual(try Data(contentsOf: database), Data("not a database".utf8)) }
    }
  }
  private func item(_ text: String, kind: ClipKind = .text, imagePath: String? = nil) -> Clip {
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
final class DataCoordinatorTests: IsolatedTestCase {
  func testQueuedBackupIsCancelledAndArchiveOperationsStaySerialized() {
    let coordinator = DataCoordinator()
    coordinator.setBackupEnabled(true)
    let entered = expectation(description: "first archive operation entered")
    let finished = expectation(description: "first archive operation finished")
    let cancelled = expectation(description: "queued backup cancelled")
    let release = DispatchSemaphore(value: 0)
    coordinator.perform({
      entered.fulfill()
      release.wait()
      return 1
    }) { value in
      XCTAssertEqual(value, 1)
      finished.fulfill()
    }
    wait(for: [entered], timeout: 2)
    let operation = coordinator.backupOperation { _ -> Int in
      XCTFail("Disabled queued backup must never start")
      return 2
    }
    coordinator.perform(operation) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(error as? CloudBackupError, .cancelled)
      } else {
        XCTFail("Expected cancellation")
      }
      cancelled.fulfill()
    }
    coordinator.setBackupEnabled(false)
    coordinator.setBackupEnabled(true)
    release.signal()
    wait(for: [finished, cancelled], timeout: 2, enforceOrder: true)
  }

  func testDisablingBackupBeforePublicationKeepsPreviousArchive() throws {
    let root = try makeTempDirectory()
    let fixture = try makeStorage(at: root.appendingPathComponent("local"))
    let cloud = CloudBackup(containerProvider: { root.appendingPathComponent("cloud") })
    let archive = try cloud.syncArchiveURL()
    let original = Data("previous backup".utf8)
    try original.write(to: archive)
    let coordinator = DataCoordinator()
    coordinator.setBackupEnabled(true)
    let operation = coordinator.backupOperation { write in
      coordinator.setBackupEnabled(false)
      return try cloud.push(store: fixture.store, write: write)
    }
    if case .failure(let error) = operation() {
      XCTAssertEqual(error as? CloudBackupError, .cancelled)
    } else {
      XCTFail("Expected cancellation before publishing")
    }
    XCTAssertEqual(try Data(contentsOf: archive), original)
  }

}
