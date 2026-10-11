import Foundation
import XCTest
@testable import Goldfish

final class ClipboardCloudSyncServiceTests: IsolatedTestCase {
  private var tempRoot: URL!
  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = try makeTempDirectory()
  }

  func testUnavailableContainerReportsStatusAndThrows() {
    let service = ClipboardCloudSyncService(containerProvider: { nil })

    let status = service.status()

    XCTAssertFalse(status.isAvailable)
    XCTAssertNil(status.archiveURL)
    XCTAssertTrue(status.message.contains("iCloud Backup is unavailable"))
    XCTAssertThrowsError(try service.syncArchiveURL()) { error in
      XCTAssertEqual(error as? ClipboardCloudSyncError, .unavailable)
    }
  }

  func testPushWritesArchiveToPrivateDocumentsFolder() throws {
    let environment = try makeStoreEnvironment(named: "source")
    environment.store.upsert(makeItem("cloud note", created: Date(timeIntervalSince1970: 10)))
    environment.store.flushPersistenceForTesting()

    let cloudRoot = tempRoot.appendingPathComponent("cloud", isDirectory: true)
    let service = ClipboardCloudSyncService(containerProvider: { cloudRoot })

    let summary = try service.push(store: environment.store)
    let archiveURL = try service.syncArchiveURL()
    let status = service.status()

    XCTAssertEqual(summary.itemCount, 1)
    XCTAssertEqual(
      archiveURL,
      cloudRoot
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("ClipBored", isDirectory: true)
        .appendingPathComponent("ClipBored.clipboredarchive")
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    XCTAssertEqual(try posixPermissions(archiveURL), 0o600)
    XCTAssertTrue(status.isAvailable)
    XCTAssertEqual(status.archiveURL, archiveURL)
    XCTAssertNotNil(status.lastModifiedAt)
  }

  func testPullImportsExistingCloudArchiveIntoAnotherStore() throws {
    let source = try makeStoreEnvironment(named: "source")
    let sourceItem = makeItem("shared through icloud", created: Date(timeIntervalSince1970: 20))
    source.store.upsert(sourceItem)
    source.store.flushPersistenceForTesting()

    let cloudRoot = tempRoot.appendingPathComponent("cloud", isDirectory: true)
    let service = ClipboardCloudSyncService(containerProvider: { cloudRoot })
    try service.push(store: source.store)

    let destination = try makeStoreEnvironment(named: "destination")
    let summary = try service.pull(store: destination.store)
    destination.store.flushPersistenceForTesting()

    XCTAssertEqual(summary.itemCount, 1)
    XCTAssertEqual(destination.store.items.count, 1)
    XCTAssertEqual(destination.store.items.first?.id, sourceItem.id)
    XCTAssertEqual(destination.store.items.first?.payload, "shared through icloud")
  }

  func testPullWithoutRemoteArchiveThrowsNoRemoteArchive() throws {
    let destination = try makeStoreEnvironment(named: "destination")
    let cloudRoot = tempRoot.appendingPathComponent("empty-cloud", isDirectory: true)
    let service = ClipboardCloudSyncService(containerProvider: { cloudRoot })

    XCTAssertThrowsError(try service.pull(store: destination.store)) { error in
      guard case ClipboardCloudSyncError.noRemoteArchive(let url) = error else {
        return XCTFail("Expected noRemoteArchive, got \(error)")
      }
      XCTAssertEqual(url.lastPathComponent, ClipboardCloudSyncService.archiveFileName)
    }
  }

  private func makeStoreEnvironment(named name: String) throws -> (settings: SettingsModel, store: ClipboardStore) {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    settings.maxHistoryItems = 50
    settings.historyRetention = .forever
    let baseURL = tempRoot.appendingPathComponent(name, isDirectory: true)
    let encryptionService = ClipboardEncryptionService(keyProvider: { nil })
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: encryptionService)
    let store = ClipboardStore(
      settings: settings,
      cacheService: cacheService,
      baseURL: baseURL,
      encryptionService: encryptionService
    )
    return (settings, store)
  }

  private func makeItem(_ payload: String, created: Date) -> ClipboardItem {
    testItem(payload: payload, payloadHash: String(payload.hashValue), createdAt: created)
  }

  private func posixPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? Int)
  }
}
