import AppKit
import XCTest

@testable import Goldfish

/// One owner for temporary storage and preference suites used by each scenario.
class IsolatedTestCase: XCTestCase {
  var tempURLs: [URL] = []
  var suiteNames: [String] = []

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

  override func tearDownWithError() throws {
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
  private var history: ClipboardStore?
  var defaults: UserDefaults!
  var settings: SettingsModel!
  var directory: URL!
  var encryption: ClipboardEncryptionService!
  var cache: ClipboardCacheService!
  var store: ClipboardStore {
    if let history { return history }
    let opened = reopen()
    history = opened
    return opened
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    try resetStorage()
  }

  func resetStorage() throws {
    history?.flushPersistenceForTesting()
    history = nil
    cache?.flushForTesting()
    defaults = makeTestDefaults(retention: .forever)
    settings = SettingsModel(defaults: defaults)
    directory = try makeTempDirectory()
    encryption = testEncryption(byte: encryptionByte)
    cache = ClipboardCacheService(baseURL: directory, encryptionService: encryption)
  }

  func reopen() -> ClipboardStore {
    ClipboardStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption)
  }

  override func tearDownWithError() throws {
    history?.flushPersistenceForTesting()
    history = nil
    cache?.flushForTesting()
    cache = nil
    settings = nil
    defaults = nil
    encryption = nil
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
