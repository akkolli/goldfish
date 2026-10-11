import AppKit
import CryptoKit
import XCTest

@testable import Goldfish

/// One owner for temporary storage and preference suites used by each scenario.
class IsolatedTestCase: XCTestCase {
  var tempURLs: [URL] = []
  var suiteNames: [String] = []
  private var storageFixtures: [ClipboardTestStorage] = []

  func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GoldfishTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    tempURLs.append(url)
    return url
  }

  func makeTestDefaults(retention: HistoryRetention? = nil) -> UserDefaults {
    let suite = "GoldfishTests.\(UUID())"
    suiteNames.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    if let retention { defaults.set(retention.rawValue, forKey: SettingsModel.Keys.historyRetention) }
    return defaults
  }

  func makeStorage(at directory: URL? = nil, retention: HistoryRetention? = nil, limit: Int? = nil, encryptionByte: UInt8? = nil) throws
    -> ClipboardTestStorage
  {
    let fixture = ClipboardTestStorage(
      defaults: makeTestDefaults(retention: retention), directory: try directory ?? makeTempDirectory(),
      encryption: testEncryption(byte: encryptionByte))
    if let limit { fixture.settings.maxHistoryItems = limit }
    storageFixtures.append(fixture)
    return fixture
  }

  override func tearDownWithError() throws {
    storageFixtures.forEach { $0.flush() }
    storageFixtures.removeAll()
    tempURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    tempURLs.removeAll()
    suiteNames.removeAll()
    try super.tearDownWithError()
  }
}

/// Transfers and capture use a named board, never the user's clipboard.
class ClipboardTestCase: IsolatedTestCase {
  let pasteboard = NSPasteboard.withUniqueName()

  override func tearDownWithError() throws {
    pasteboard.releaseGlobally()
    try super.tearDownWithError()
  }
}

/// Shared storage ownership for capture, persistence and interface scenarios.
/// The history opens lazily, so key-failure tests can supply their own stores.
class StoredClipboardTestCase: ClipboardTestCase {
  var encryptionByte: UInt8? { nil }
  private var storage: ClipboardTestStorage!
  var defaults: UserDefaults { storage.defaults }
  var settings: SettingsModel { storage.settings }
  var directory: URL { storage.directory }
  var encryption: HistoryEncryption { storage.encryption }
  var cache: MediaCache { storage.cache }
  var store: HistoryStore { storage.store }

  override func setUpWithError() throws {
    try super.setUpWithError()
    if let name = ProcessInfo.processInfo.environment["GOLDFISH_TEST_SCREEN"], interfaceScreen == nil {
      throw NSError(domain: "GoldfishTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test display is unavailable: \(name)"])
    }
    try resetStorage()
  }

  func resetStorage() throws {
    storage?.flush()
    storage = try makeStorage(retention: .forever, encryptionByte: encryptionByte)
  }

  func reopen() -> HistoryStore { storage.reopen() }

  override func tearDownWithError() throws {
    storage?.flush()
    storage = nil
    try super.tearDownWithError()
  }

  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  var interfaceScreen: NSScreen? {
    guard let name = ProcessInfo.processInfo.environment["GOLDFISH_TEST_SCREEN"] else { return nil }
    return NSScreen.screens.first { $0.localizedName == name }
  }
  func positionInterfaceWindow(_ window: NSWindow) {
    guard let screen = interfaceScreen else { return }
    window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.maxY - window.frame.height - 40))
  }
  func settle(_ seconds: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
  func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(1.5)
    while !condition() && Date() < deadline { settle(0.01) }
    XCTAssertTrue(condition(), "Workflow did not reach its expected state", file: file, line: line)
  }
}

/// Defaults describe an ordinary new text clip; scenarios supply only their differences.
func testItem(
  id: UUID = UUID(), kind: ClipKind = .text, displayText: String? = nil, payload: String, payloadHash: String? = nil,
  createdAt: Date = Date(), lastUsedAt: Date? = nil, useCount: Int = 1, sourceApp: String? = nil, imagePath: String? = nil,
  thumbnailPath: String? = nil, isPinned: Bool = false, sourceAppBundleId: String? = nil, ocrText: String? = nil,
  collectionName: String? = nil, customTitle: String? = nil, sourceDeviceName: String? = Clip.localDeviceName
) -> Clip {
  Clip(
    id: id, kind: kind, displayText: displayText ?? payload, payload: payload, payloadHash: payloadHash ?? payload, createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? createdAt, useCount: useCount, sourceApp: sourceApp, imagePath: imagePath, thumbnailPath: thumbnailPath,
    isPinned: isPinned, sourceAppBundleId: sourceAppBundleId, ocrText: ocrText, collectionName: collectionName, customTitle: customTitle,
    sourceDeviceName: sourceDeviceName)
}

func testImage(color: NSColor, size: NSSize = NSSize(width: 24, height: 24)) -> NSImage {
  let image = NSImage(size: size)
  image.lockFocus()
  color.setFill()
  NSRect(origin: .zero, size: size).fill()
  image.unlockFocus()
  return image
}

func testEncryption(byte: UInt8? = nil) -> HistoryEncryption {
  HistoryEncryption(keyProvider: { byte.map { SymmetricKey(data: Data(repeating: $0, count: 32)) } })
}

func testPermissions(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try XCTUnwrap(attributes[.posixPermissions] as? Int, file: file, line: line) & 0o777
}

/// Holds storage dependencies together and drains their work before temporary files are removed.
/// Opening history stays lazy, so migration scenarios can write legacy input first.
final class ClipboardTestStorage {
  let defaults: UserDefaults
  let settings: SettingsModel
  let directory: URL
  let encryption: HistoryEncryption
  let cache: MediaCache
  private var history: HistoryStore?
  var store: HistoryStore {
    if let history { return history }
    let opened = reopen()
    history = opened
    return opened
  }

  init(defaults: UserDefaults, directory: URL, encryption: HistoryEncryption) {
    self.defaults = defaults
    settings = SettingsModel(defaults: defaults)
    self.directory = directory
    self.encryption = encryption
    cache = MediaCache(baseURL: directory, encryptionService: encryption)
  }

  func reopen() -> HistoryStore { HistoryStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption) }

  func flush() {
    history?.flushPersistenceForTesting()
    cache.flushForTesting()
  }
}
