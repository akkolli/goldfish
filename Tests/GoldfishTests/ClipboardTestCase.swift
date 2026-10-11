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
