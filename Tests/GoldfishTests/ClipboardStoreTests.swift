import CryptoKit
import XCTest
import Foundation
import AppKit
@testable import Goldfish

final class ClipboardStoreTests: IsolatedTestCase {
  private var defaults: UserDefaults!
  private var cacheService: ClipboardCacheService!
  private var baseURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    defaults = makeTestDefaults()
    baseURL = try makeTempDirectory()
    cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
  }

  override func tearDownWithError() throws {
    cacheService = nil
    defaults = nil
    baseURL = nil
    try super.tearDownWithError()
  }

  func testUpsertMovesDuplicateToFrontAndPersists() throws {
    let settings = makeSettings(maxHistory: 4)
    let store = makeStore(settings: settings)
    let start = Date()

    store.upsert(makeItem("one", displayText: "One", created: start))
    store.upsert(makeItem("two", displayText: "Two", created: start.addingTimeInterval(-10)))
    store.upsert(makeItem("three", displayText: "Three", created: start.addingTimeInterval(-20)))

    store.upsert(makeItem("one", displayText: "One (updated)", created: start.addingTimeInterval(-30)))
    store.flushPersistenceForTesting()

    XCTAssertEqual(store.items.count, 3)
    XCTAssertEqual(store.items.map(\.payload), ["one", "three", "two"])
    XCTAssertEqual(store.items.first?.useCount, 2)

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.count, 3)
    XCTAssertEqual(restored.items.first?.payload, "one")
    XCTAssertEqual(restored.items.first?.useCount, 2)
  }

  func testHistoryLimitIsEnforcedByOverflowPurge() throws {
    let settings = makeSettings(maxHistory: 50)
    let store = makeStore(settings: settings)
    let start = Date()

    (0...50).forEach { i in
      store.upsert(makeItem("item-\(i)", displayText: "\(i)", created: start.addingTimeInterval(-Double(i))))
    }
    store.flushPersistenceForTesting()

    XCTAssertEqual(store.items.count, 50)
    XCTAssertEqual(store.items.first?.payload, "item-50")
    XCTAssertEqual(store.items.last?.payload, "item-1")

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.count, 50)
    XCTAssertFalse(restored.items.contains(where: { $0.payload == "item-0" }))
    XCTAssertTrue(restored.items.contains(where: { $0.payload == "item-50" }))
    XCTAssertTrue(restored.items.contains(where: { $0.payload == "item-1" }))
  }

  func testLegacyJSONHistoryMigratesToSQLite() throws {
    let settings = makeSettings(maxHistory: 50)
    let itemID = UUID()
    let legacyJSON = """
      [
        {
          "id": "\(itemID.uuidString)",
          "kind": 0,
          "displayText": "Legacy Note",
          "payload": "legacy payload",
          "payloadHash": "legacy-hash",
          "createdAt": "2026-06-27T12:00:00Z",
          "lastUsedAt": "2026-06-27T12:01:00Z",
          "useCount": 3,
          "sourceApp": "Notes",
          "imagePath": null,
          "thumbnailPath": null
        }
      ]
      """
    try legacyJSON.data(using: .utf8)!.write(to: baseURL.appendingPathComponent("history.json"))

    let store = makeStore(settings: settings)
    store.flushPersistenceForTesting()

    XCTAssertEqual(store.items.count, 1)
    XCTAssertEqual(store.items.first?.id, itemID)
    XCTAssertEqual(store.items.first?.payload, "legacy payload")
    XCTAssertEqual(store.items.first?.useCount, 3)
    XCTAssertEqual(store.items.first?.sourceDeviceName, ClipboardItem.localDeviceName)

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.first?.payload, "legacy payload")
    XCTAssertEqual(restored.items.first?.sourceDeviceName, ClipboardItem.localDeviceName)
  }

  func testHistoryRetentionPrunesExpiredUnpinnedItems() {
    let settings = makeSettings(maxHistory: 50)
    settings.historyRetention = .oneDay
    let store = makeStore(settings: settings)
    let now = Date()

    store.upsert(makeItem("old", displayText: "Old", created: now.addingTimeInterval(-2 * 24 * 60 * 60)))
    store.upsert(makeItem("recent", displayText: "Recent", created: now.addingTimeInterval(-60)))
    store.flushPersistenceForTesting()

    XCTAssertEqual(store.items.map(\.payload), ["recent"])
    XCTAssertFalse(store.items.contains(where: { $0.payload == "old" }))

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.map(\.payload), ["recent"])
  }

  func testHistoryRetentionKeepsPinnedAndCollectionItems() {
    let settings = makeSettings(maxHistory: 50)
    settings.historyRetention = .oneDay
    let store = makeStore(settings: settings)
    let oldDate = Date().addingTimeInterval(-2 * 24 * 60 * 60)
    var pinned = makeItem("pinned-old", displayText: "Pinned", created: oldDate)
    pinned.isPinned = true
    var saved = makeItem("collection-old", displayText: "Saved", created: oldDate)
    saved.collectionName = "Client Work"

    store.upsert(makeItem("plain-old", displayText: "Plain", created: oldDate))
    store.upsert(pinned)
    store.upsert(saved)
    store.flushPersistenceForTesting()

    XCTAssertFalse(store.items.contains(where: { $0.payload == "plain-old" }))
    XCTAssertTrue(store.items.contains(where: { $0.payload == "pinned-old" && $0.isPinned }))
    XCTAssertTrue(store.items.contains(where: { $0.payload == "collection-old" && $0.collectionName == "Client Work" }))

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertFalse(restored.items.contains(where: { $0.payload == "plain-old" }))
    XCTAssertTrue(restored.items.contains(where: { $0.payload == "pinned-old" && $0.isPinned }))
    XCTAssertTrue(restored.items.contains(where: { $0.payload == "collection-old" && $0.collectionName == "Client Work" }))
  }

  func testStorageFilesUsePrivatePermissions() throws {
    let settings = makeSettings(maxHistory: 50)
    let store = makeStore(settings: settings)

    store.upsert(makeItem("private", displayText: "Private", created: Date()))
    store.flushPersistenceForTesting()

    XCTAssertEqual(try testPermissions(baseURL), 0o700)
    XCTAssertEqual(try testPermissions(baseURL.appendingPathComponent("history.sqlite")), 0o600)
  }

  func testRemoveAllResetsEncryptionKeyAfterClearingDatabase() throws {
    let settings = makeSettings(maxHistory: 50)
    var resetCount = 0
    let keyData = Data(repeating: 7, count: 32)
    let encryptionService = ClipboardEncryptionService(
      keyProvider: { SymmetricKey(data: keyData) },
      resetProvider: { resetCount += 1 }
    )
    let store = makeStore(settings: settings, encryptionService: encryptionService)

    store.upsert(makeItem("first", displayText: "First", created: Date()))
    store.upsert(makeItem("second", displayText: "Second", created: Date()))
    store.flushPersistenceForTesting()

    let firstID = try XCTUnwrap(store.items.first?.id)
    store.remove(firstID)
    store.flushPersistenceForTesting()
    XCTAssertEqual(resetCount, 0)

    store.removeAll()
    store.flushPersistenceForTesting()

    XCTAssertEqual(resetCount, 1)
    XCTAssertTrue(store.items.isEmpty)
    let restored = makeStore(settings: settings, encryptionService: encryptionService)
    restored.flushPersistenceForTesting()
    XCTAssertTrue(restored.items.isEmpty)
  }

  func testPersistedTextFieldsAreEncryptedAndReload() throws {
    let settings = makeSettings(maxHistory: 50)
    let encryptionService = testEncryption(byte: 7)
    let store = makeStore(settings: settings, encryptionService: encryptionService)
    let item = testItem(
      displayText: "Displayed secret \(UUID().uuidString)", payload: "Payload secret \(UUID().uuidString)",
      payloadHash: "Hash secret \(UUID().uuidString)", createdAt: Date(timeIntervalSince1970: 100),
      sourceApp: "Secret app \(UUID().uuidString)",
      sourceAppBundleId: "com.example.secret.\(UUID().uuidString)",
      ocrText: "OCR secret \(UUID().uuidString)", collectionName: "Collection secret \(UUID().uuidString)",
      sourceDeviceName: "Device secret \(UUID().uuidString)")

    store.upsert(item)
    store.flushPersistenceForTesting()

    let rawDatabaseText = try databaseText()
    XCTAssertTrue(rawDatabaseText.contains(ClipboardEncryptionService.marker))
    XCTAssertFalse(rawDatabaseText.contains(item.displayText))
    XCTAssertFalse(rawDatabaseText.contains(item.payload))
    XCTAssertFalse(rawDatabaseText.contains(item.payloadHash))
    XCTAssertFalse(rawDatabaseText.contains(item.sourceApp!))
    XCTAssertFalse(rawDatabaseText.contains(item.sourceAppBundleId!))
    XCTAssertFalse(rawDatabaseText.contains(item.ocrText!))
    XCTAssertFalse(rawDatabaseText.contains(item.collectionName!))
    XCTAssertFalse(rawDatabaseText.contains(item.sourceDeviceName!))

    let restored = makeStore(settings: settings, encryptionService: encryptionService)
    restored.flushPersistenceForTesting()

    XCTAssertEqual(restored.items.first?.displayText, item.displayText)
    XCTAssertEqual(restored.items.first?.payload, item.payload)
    XCTAssertEqual(restored.items.first?.payloadHash, item.payloadHash)
    XCTAssertEqual(restored.items.first?.sourceApp, item.sourceApp)
    XCTAssertEqual(restored.items.first?.sourceAppBundleId, item.sourceAppBundleId)
    XCTAssertEqual(restored.items.first?.ocrText, item.ocrText)
    XCTAssertEqual(restored.items.first?.collectionName, item.collectionName)
    XCTAssertEqual(restored.items.first?.sourceDeviceName, item.sourceDeviceName)
  }

  func testWrongEncryptionKeyReportsLoadWarningWithoutDeletingDatabase() throws {
    let settings = makeSettings(maxHistory: 50)
    let writer = makeStore(settings: settings, encryptionService: testEncryption(byte: 7))
    let item = makeItem("encrypted history", displayText: "Encrypted", created: Date())
    writer.upsert(item)
    writer.flushPersistenceForTesting()
    let databaseSizeBeforeReload = try fileSize(baseURL.appendingPathComponent("history.sqlite"))

    let reader = makeStore(settings: settings, encryptionService: testEncryption(byte: 9))
    reader.flushPersistenceForTesting()

    XCTAssertTrue(reader.items.isEmpty)
    XCTAssertNotNil(reader.loadWarningMessage)
    XCTAssertEqual(
      try fileSize(baseURL.appendingPathComponent("history.sqlite")),
      databaseSizeBeforeReload
    )
  }

  func testImportCannotReplaceUnreadableHistory() throws {
    let settings = makeSettings(maxHistory: 50)
    let writer = makeStore(settings: settings, encryptionService: testEncryption(byte: 7))
    writer.upsert(makeItem("must remain recoverable", displayText: "Private", created: Date()))
    writer.flushPersistenceForTesting()
    let archive = baseURL.appendingPathComponent("backup.clipboredarchive")
    try writer.exportArchive(to: archive)
    let reader = makeStore(settings: settings, encryptionService: testEncryption(byte: 9))
    XCTAssertThrowsError(try reader.exportArchive(to: archive))
    XCTAssertThrowsError(try reader.exportCollection(named: "Private", to: archive))
    XCTAssertThrowsError(try reader.importArchive(from: archive)) { error in
      guard case ClipboardStoreArchiveError.unreadableHistory = error else {
        return XCTFail("Expected a recoverable-history protection error")
      }
    }
    let restored = makeStore(settings: settings, encryptionService: testEncryption(byte: 7))
    XCTAssertEqual(restored.items.map(\.payload), ["must remain recoverable"])
  }

  func testUnavailableEncryptionKeyDoesNotSavePlaintextOrPretendToCapture() throws {
    let settings = makeSettings(maxHistory: 50)
    let encryption = ClipboardEncryptionService(keyProvider: { nil }, allowsUnencryptedStorage: false)
    let store = makeStore(settings: settings, encryptionService: encryption)
    store.upsert(makeItem("never persist this plaintext", displayText: "Private", created: Date()))
    store.flushPersistenceForTesting()
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertFalse(try databaseText().contains("never persist this plaintext"))
    XCTAssertTrue(settings.captureStatusMessage.contains("encryption key"))
    let secureCache = ClipboardCacheService(baseURL: baseURL, encryptionService: encryption)
    XCTAssertNil(secureCache.cachePDF(Data("private attachment".utf8), id: UUID()))
  }

  func testPlaintextDatabaseMigratesToEncryptedFieldsOnLoad() throws {
    let settings = makeSettings(maxHistory: 50)
    let plaintextStore = makeStore(settings: settings, encryptionService: testEncryption())
    let item = testItem(
      displayText: "Legacy display \(UUID().uuidString)", payload: "Legacy payload \(UUID().uuidString)",
      payloadHash: "Legacy hash \(UUID().uuidString)", createdAt: Date(timeIntervalSince1970: 200),
      sourceApp: "Legacy source \(UUID().uuidString)",
      sourceAppBundleId: "com.example.legacy.\(UUID().uuidString)",
      ocrText: "Legacy OCR \(UUID().uuidString)", collectionName: "Legacy collection \(UUID().uuidString)",
      sourceDeviceName: "Legacy device \(UUID().uuidString)")

    plaintextStore.upsert(item)
    plaintextStore.flushPersistenceForTesting()
    XCTAssertTrue(try databaseText().contains(item.payload))

    let encryptionService = testEncryption(byte: 7)
    let restored = makeStore(settings: settings, encryptionService: encryptionService)
    restored.flushPersistenceForTesting()

    XCTAssertEqual(restored.items.first?.displayText, item.displayText)
    XCTAssertEqual(restored.items.first?.payload, item.payload)
    XCTAssertEqual(restored.items.first?.payloadHash, item.payloadHash)
    XCTAssertEqual(restored.items.first?.sourceApp, item.sourceApp)
    XCTAssertEqual(restored.items.first?.sourceAppBundleId, item.sourceAppBundleId)
    XCTAssertEqual(restored.items.first?.ocrText, item.ocrText)
    XCTAssertEqual(restored.items.first?.collectionName, item.collectionName)
    XCTAssertEqual(restored.items.first?.sourceDeviceName, item.sourceDeviceName)

    let migratedDatabaseText = try databaseText()
    XCTAssertTrue(migratedDatabaseText.contains(ClipboardEncryptionService.marker))
    XCTAssertFalse(migratedDatabaseText.contains(item.displayText))
    XCTAssertFalse(migratedDatabaseText.contains(item.payload))
    XCTAssertFalse(migratedDatabaseText.contains(item.payloadHash))
    XCTAssertFalse(migratedDatabaseText.contains(item.sourceApp!))
    XCTAssertFalse(migratedDatabaseText.contains(item.sourceAppBundleId!))
    XCTAssertFalse(migratedDatabaseText.contains(item.ocrText!))
    XCTAssertFalse(migratedDatabaseText.contains(item.collectionName!))
    XCTAssertFalse(migratedDatabaseText.contains(item.sourceDeviceName!))
  }

  func testDuplicatePDFReplacementRemovesOldAttachment() throws {
    let settings = makeSettings(maxHistory: 50)
    let store = makeStore(settings: settings)
    let hash = "same-pdf"
    let oldPath = try XCTUnwrap(cacheService.cachePDF(Data("old".utf8), id: UUID()))
    let newPath = try XCTUnwrap(cacheService.cachePDF(Data("new".utf8), id: UUID()))

    store.upsert(makePDFItem(path: oldPath, hash: hash, created: Date(timeIntervalSince1970: 10)))
    store.upsert(makePDFItem(path: newPath, hash: hash, created: Date(timeIntervalSince1970: 20)))
    store.flushPersistenceForTesting()
    cacheService.flushForTesting()

    XCTAssertEqual(store.items.count, 1)
    XCTAssertEqual(store.items.first?.payload, newPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
  }

  func testRemoveCanDeferManagedCachePurgeForUndoRestore() throws {
    let settings = makeSettings(maxHistory: 50)
    let store = makeStore(settings: settings)
    let cachedImage = try XCTUnwrap(cacheService.cacheImage(testImage(color: .systemBlue), id: UUID()))
    let item = makeImageItem(
      fullPath: cachedImage.full,
      thumbPath: cachedImage.thumb,
      hash: "undo-image",
      ocrText: "undo searchable text",
      created: Date(timeIntervalSince1970: 10)
    )
    store.upsert(item)
    store.flushPersistenceForTesting()

    let removal = try XCTUnwrap(store.remove(item.id, purgeManagedCache: false))
    store.flushPersistenceForTesting()
    cacheService.flushForTesting()

    XCTAssertTrue(store.items.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedImage.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedImage.thumb))

    store.restore([removal])
    store.flushPersistenceForTesting()

    XCTAssertEqual(store.items.map(\.id), [item.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedImage.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedImage.thumb))

    let restored = makeStore(settings: settings)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.map(\.id), [item.id])

    _ = store.remove(item.id)
    store.flushPersistenceForTesting()
    cacheService.flushForTesting()

    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedImage.full))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedImage.thumb))
  }

  func testArchiveExportImportMovesHistoryAndManagedAttachmentsToNewStorage() throws {
    let settings = makeSettings(maxHistory: 50)
    let store = makeStore(settings: settings)
    let cachedImage = try XCTUnwrap(cacheService.cacheImage(testImage(color: .systemBlue), id: UUID()))
    let sourceFullImageData = try XCTUnwrap(cacheService.data(for: cachedImage.full))
    let sourceThumbData = try XCTUnwrap(cacheService.data(for: cachedImage.thumb))
    let sourcePDFData = Data("%PDF archive payload".utf8)
    let sourcePDFPath = try XCTUnwrap(cacheService.cachePDF(sourcePDFData, id: UUID()))
    let created = Date(timeIntervalSince1970: 300)

    var note = makeItem("archive note", displayText: "Archive Note", created: created)
    note.collectionName = "Read Later"
    note.customTitle = "Migration Note"
    note.sourceDeviceName = "Studio Mac"
    var image = makeImageItem(
      fullPath: cachedImage.full,
      thumbPath: cachedImage.thumb,
      hash: "archive-image",
      ocrText: "blue archive image",
      created: created.addingTimeInterval(1)
    )
    image.isPinned = true
    image.collectionName = "Client Work"
    image.customTitle = "Launch Screenshot"
    image.sourceDeviceName = "MacBook Pro"
    var pdf = makePDFItem(
      path: sourcePDFPath,
      hash: "archive-pdf",
      created: created.addingTimeInterval(2)
    )
    pdf.collectionName = "Research"
    pdf.sourceDeviceName = "Design Mac"

    store.upsert(note)
    store.upsert(image)
    store.upsert(pdf)
    store.flushPersistenceForTesting()

    let archiveURL = baseURL.appendingPathComponent("backup.clipboredarchive")
    let exportSummary = try store.exportArchive(to: archiveURL)

    XCTAssertEqual(exportSummary.itemCount, 3)
    XCTAssertEqual(exportSummary.sidecarCount, 3)
    XCTAssertEqual(try testPermissions(archiveURL), 0o600)

    let destinationBaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboredtests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: destinationBaseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destinationBaseURL) }

    let destinationDefaultsSuite = "com.clipbored.archiveimport.\(UUID().uuidString)"
    let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationDefaultsSuite))
    destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite)
    defer { destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite) }

    let destinationSettings = SettingsModel(defaults: destinationDefaults)
    destinationSettings.maxHistoryItems = 50
    destinationSettings.historyRetention = .forever
    let destinationCache = ClipboardCacheService(
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )
    let destinationStore = ClipboardStore(
      settings: destinationSettings,
      cacheService: destinationCache,
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )
    destinationStore.upsert(makeItem("destination only", displayText: "Destination", created: created.addingTimeInterval(3)))
    destinationStore.flushPersistenceForTesting()

    let importSummary = try destinationStore.importArchive(from: archiveURL)
    destinationStore.flushPersistenceForTesting()

    XCTAssertEqual(importSummary.itemCount, 3)
    XCTAssertEqual(importSummary.sidecarCount, 3)
    XCTAssertEqual(destinationStore.items.count, 4)
    XCTAssertTrue(destinationStore.items.contains { $0.payload == "destination only" })

    let importedNote = try XCTUnwrap(destinationStore.items.first { $0.id == note.id })
    XCTAssertEqual(importedNote.collectionName, "Read Later")
    XCTAssertEqual(importedNote.customTitle, "Migration Note")
    XCTAssertEqual(importedNote.sourceDeviceName, "Studio Mac")

    let importedImage = try XCTUnwrap(destinationStore.items.first { $0.id == image.id })
    XCTAssertTrue(importedImage.isPinned)
    XCTAssertEqual(importedImage.collectionName, "Client Work")
    XCTAssertEqual(importedImage.customTitle, "Launch Screenshot")
    XCTAssertEqual(importedImage.sourceDeviceName, "MacBook Pro")
    let importedImagePath = try XCTUnwrap(importedImage.imagePath)
    let importedThumbPath = try XCTUnwrap(importedImage.thumbnailPath)
    XCTAssertTrue(importedImagePath.hasPrefix(destinationBaseURL.path))
    XCTAssertTrue(importedThumbPath.hasPrefix(destinationBaseURL.path))
    XCTAssertNotEqual(importedImagePath, cachedImage.full)
    XCTAssertEqual(destinationCache.data(for: importedImagePath), sourceFullImageData)
    XCTAssertEqual(destinationCache.data(for: importedThumbPath), sourceThumbData)

    let importedPDF = try XCTUnwrap(destinationStore.items.first { $0.id == pdf.id })
    XCTAssertEqual(importedPDF.collectionName, "Research")
    XCTAssertTrue(importedPDF.payload.hasPrefix(destinationBaseURL.path))
    XCTAssertNotEqual(importedPDF.payload, sourcePDFPath)
    XCTAssertEqual(destinationCache.data(for: importedPDF.payload), sourcePDFData)

    let reloaded = ClipboardStore(
      settings: destinationSettings,
      cacheService: destinationCache,
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )
    reloaded.flushPersistenceForTesting()
    XCTAssertEqual(reloaded.items.count, 4)
    XCTAssertTrue(reloaded.items.contains { $0.id == image.id && $0.collectionName == "Client Work" })
    XCTAssertTrue(reloaded.items.contains { $0.id == pdf.id && $0.collectionName == "Research" })
  }

  func testArchiveImportRejectsOversizedFileBeforeLoadingIt() throws {
    let archiveURL = baseURL.appendingPathComponent("oversized.clipboredarchive")
    XCTAssertTrue(FileManager.default.createFile(atPath: archiveURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: archiveURL)
    try handle.truncate(atOffset: UInt64(AppConfiguration.maxPortableArchiveBytes + 1))
    try handle.close()

    XCTAssertThrowsError(
      try ClipboardArchiveService().importArchive(from: archiveURL, cacheService: cacheService)
    ) { error in
      guard case ClipboardArchiveError.archiveTooLarge = error else {
        return XCTFail("Expected archiveTooLarge, got \(error)")
      }
    }
  }

  func testPinboardExportImportsOnlyThatCollectionAndPreservesAppearance() throws {
    let settings = makeSettings(maxHistory: 50)
    settings.ensureCollection(named: "Client Work", colorHex: "#3366FF", icon: "briefcase.fill")
    let store = makeStore(settings: settings)
    let created = Date(timeIntervalSince1970: 500)
    var client = makeItem("client note", displayText: "Client Note", created: created)
    client.collectionName = "Client Work"
    let unrelated = makeItem("other note", displayText: "Other Note", created: created.addingTimeInterval(1))

    store.upsert(client)
    store.upsert(unrelated)
    store.flushPersistenceForTesting()

    let archiveURL = baseURL.appendingPathComponent("client-work.clipboredarchive")
    let exportSummary = try store.exportCollection(named: "Client Work", to: archiveURL)

    XCTAssertEqual(exportSummary.itemCount, 1)
    XCTAssertEqual(exportSummary.sidecarCount, 0)

    let destinationDefaultsSuite = "com.clipbored.pinboardimport.\(UUID().uuidString)"
    let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationDefaultsSuite))
    destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite)
    defer { destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite) }
    let destinationSettings = SettingsModel(defaults: destinationDefaults)
    destinationSettings.maxHistoryItems = 50
    destinationSettings.historyRetention = .forever
    let destinationBaseURL = baseURL.appendingPathComponent("pinboard-destination", isDirectory: true)
    let destinationCache = ClipboardCacheService(
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )
    let destinationStore = ClipboardStore(
      settings: destinationSettings,
      cacheService: destinationCache,
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )

    let importSummary = try destinationStore.importArchive(from: archiveURL)

    XCTAssertEqual(importSummary.itemCount, 1)
    XCTAssertEqual(destinationStore.items.map(\.payload), ["client note"])
    XCTAssertEqual(destinationStore.items.first?.collectionName, "Client Work")
    XCTAssertEqual(destinationSettings.customCollectionNames, ["Client Work"])
    XCTAssertEqual(destinationSettings.collectionColorHex(forCollectionNamed: "Client Work"), "#3366FF")
    XCTAssertEqual(destinationSettings.collectionIcon(forCollectionNamed: "Client Work"), "briefcase.fill")
  }

  func testEmptyPinboardExportImportsCollectionMetadata() throws {
    let settings = makeSettings(maxHistory: 50)
    settings.ensureCollection(named: "Read Later", colorHex: "#0A9EB8", icon: "book.closed.fill")
    let store = makeStore(settings: settings)
    let archiveURL = baseURL.appendingPathComponent("read-later-empty.clipboredarchive")

    let exportSummary = try store.exportCollection(named: "Read Later", to: archiveURL)

    XCTAssertEqual(exportSummary.itemCount, 0)

    let destinationDefaultsSuite = "com.clipbored.emptypinboard.\(UUID().uuidString)"
    let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationDefaultsSuite))
    destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite)
    defer { destinationDefaults.removePersistentDomain(forName: destinationDefaultsSuite) }
    let destinationSettings = SettingsModel(defaults: destinationDefaults)
    let destinationBaseURL = baseURL.appendingPathComponent("empty-pinboard-destination", isDirectory: true)
    let destinationStore = ClipboardStore(
      settings: destinationSettings,
      cacheService: ClipboardCacheService(baseURL: destinationBaseURL, encryptionService: testEncryption()),
      baseURL: destinationBaseURL,
      encryptionService: testEncryption()
    )

    let importSummary = try destinationStore.importArchive(from: archiveURL)

    XCTAssertEqual(importSummary.itemCount, 0)
    XCTAssertTrue(destinationStore.items.isEmpty)
    XCTAssertEqual(destinationSettings.customCollectionNames, ["Read Later"])
    XCTAssertEqual(destinationSettings.collectionColorHex(forCollectionNamed: "Read Later"), "#0A9EB8")
    XCTAssertEqual(destinationSettings.collectionIcon(forCollectionNamed: "Read Later"), "book.closed.fill")
  }

  private func makeSettings(maxHistory: Int) -> SettingsModel {
    let settings = SettingsModel(defaults: defaults)
    settings.maxHistoryItems = maxHistory
    settings.historyRetention = .forever
    settings.pruneDuplicates = true
    settings.keepFirstImage = true
    return settings
  }

  private func makeStore(settings: SettingsModel) -> ClipboardStore {
    makeStore(settings: settings, encryptionService: testEncryption())
  }

  private func makeStore(settings: SettingsModel, encryptionService: ClipboardEncryptionService) -> ClipboardStore {
    ClipboardStore(
      settings: settings,
      cacheService: cacheService,
      baseURL: baseURL,
      encryptionService: encryptionService
    )
  }

  private func makeItem(_ payload: String, displayText: String, created: Date) -> ClipboardItem {
    let hash = settingsHash(for: payload)
    return testItem(displayText: displayText, payload: payload, payloadHash: hash, createdAt: created)
  }

  private func makePDFItem(path: String, hash: String, created: Date) -> ClipboardItem {
    testItem(kind: .pdf, displayText: "PDF", payload: path, payloadHash: hash, createdAt: created)
  }

  private func makeImageItem(fullPath: String, thumbPath: String, hash: String, ocrText: String?, created: Date) -> ClipboardItem {
    testItem(
      kind: .image, displayText: "Image", payload: fullPath, payloadHash: hash, createdAt: created,
      sourceApp: "Preview", imagePath: fullPath, thumbnailPath: thumbPath,
      sourceAppBundleId: "com.apple.Preview", ocrText: ocrText)
  }

  private func settingsHash(for payload: String) -> String {
    payload
  }

  private func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = try XCTUnwrap(attributes[.size] as? NSNumber)
    return size.int64Value
  }

  private func databaseText() throws -> String {
    let data = try Data(contentsOf: baseURL.appendingPathComponent("history.sqlite"))
    return String(decoding: data, as: UTF8.self)
  }

}
