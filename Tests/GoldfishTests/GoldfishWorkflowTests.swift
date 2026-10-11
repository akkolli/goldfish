import AppKit
import CryptoKit
import XCTest

@testable import Goldfish

/// Exercises the shipping clipboard, storage, search, transfer, and shelf paths
/// together. Each workflow owns an isolated history and owns a private pasteboard.
final class GoldfishWorkflowTests: ClipboardTestCase {
  private var directory: URL!
  private var defaults: UserDefaults!
  private var settings: SettingsModel!
  private var encryption: ClipboardEncryptionService!
  private var cache: ClipboardCacheService!
  private var store: ClipboardStore!

  override func setUpWithError() throws {
    _ = NSApplication.shared
    defaults = makeTestDefaults()
    directory = try makeTempDirectory()
    settings = SettingsModel(defaults: defaults)
    settings.historyRetention = .forever
    encryption = testEncryption(byte: 71)
    cache = ClipboardCacheService(baseURL: directory, encryptionService: encryption)
    store = ClipboardStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption)

  }

  override func tearDownWithError() throws {
    store.flushPersistenceForTesting()
    cache.flushForTesting()
    store = nil
    cache = nil
    settings = nil
    encryption = nil
    try super.tearDownWithError()
  }

  func testCopyCaptureSearchTransferAndEncryptedRelaunch() throws {
    let monitor = ClipboardMonitorService(
      pasteboard: pasteboard, store: store, cacheService: cache, settings: settings, frontmostApp: { (nil, nil) })
    defer { monitor.stop() }
    let text = "Goldfish quartz workflow \(UUID().uuidString)"
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(text, forType: .string))
    monitor.pollNowAndWait()
    waitUntil { self.store.items.count == 1 }
    XCTAssertEqual(store.items.first?.payload, text)

    let panel = ClipboardPanelViewModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
    panel.searchText = "quartz"
    waitUntil { panel.visibleItems.count == 1 }
    XCTAssertEqual(panel.selectedItem?.payload, text)
    panel.copySelected()
    XCTAssertEqual(pasteboard.string(forType: .string), text)
    XCTAssertEqual(panel.statusMessage, "Copied")
    monitor.pollNowAndWait()
    settle()
    XCTAssertEqual(store.items.count, 1, "Goldfish must not capture its own transfer again")

    store.flushPersistenceForTesting()
    let database = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
    XCTAssertNil(database.range(of: Data(text.utf8)), "Saved clipboard text must stay encrypted")
    let restored = ClipboardStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption)
    XCTAssertEqual(restored.items.map(\.payload), [text])
  }

  func testPinboardHistoryUndoArchiveAndRestore() throws {
    let keep = try XCTUnwrap(store.upsert(item("Reusable client note")))
    store.upsert(item("Disposable note"))
    let panel = ClipboardPanelViewModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
    panel.createCollection(named: "Client Work", colorHex: "#FF9900", icon: "star.fill", selectAfterCreate: false)
    panel.assignItem(withID: keep.id, to: "Client Work")
    panel.selectCollection(named: "Client Work")
    waitUntil { panel.visibleItems.count == 1 }
    XCTAssertEqual(panel.selectedItem?.id, keep.id)
    panel.togglePinSelected()
    panel.deleteSelected()
    XCTAssertNil(store.items.first(where: { $0.id == keep.id }))
    panel.undoLastDelete()
    XCTAssertTrue(store.items.contains { $0.id == keep.id && $0.isPinned })
    panel.clearHistory(since: .distantPast)
    XCTAssertEqual(store.items.map(\.id), [keep.id])

    let archive = directory.appendingPathComponent("client-work.clipboredarchive")
    let summary = try store.exportCollection(named: "Client Work", to: archive)
    XCTAssertEqual(summary.itemCount, 1)
    let restoredDirectory = directory.appendingPathComponent("restored", isDirectory: true)
    let restoredCache = ClipboardCacheService(baseURL: restoredDirectory, encryptionService: encryption)
    let restored = ClipboardStore(
      settings: settings, cacheService: restoredCache, baseURL: restoredDirectory, encryptionService: encryption)
    try restored.importArchive(from: archive)
    restored.flushPersistenceForTesting()
    XCTAssertEqual(restored.items.first?.payload, "Reusable client note")
    XCTAssertEqual(restored.items.first?.collectionName, "Client Work")
  }

  func testStructuredSearchPinboardsAndPreferencesAcrossRelaunch() throws {
    let link = try XCTUnwrap(store.upsert(item("https://example.com/review", kind: .url, sourceApp: "Brave Browser")))
    store.upsert(item("Review the release notes", sourceApp: "Ghostty"))
    let panel = ClipboardPanelViewModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
    panel.createCollection(named: "Research", selectAfterCreate: false)
    panel.assignItem(withID: link.id, to: "Research")
    panel.searchText = "review app:\"Brave Browser\" type:link"
    waitUntil { panel.visibleItems.count == 1 }
    XCTAssertEqual(panel.selectedItem?.id, link.id)

    panel.selectCollection(named: "Research")
    XCTAssertEqual(panel.visibleItems.map(\.id), [link.id])
    panel.searchText = "missing app:\"Brave Browser\" type:link"
    XCTAssertTrue(panel.visibleItems.isEmpty)
    panel.showLatestHiddenCapture()
    panel.searchText = ""
    panel.selectSortMode(.mostUsed)
    XCTAssertNil(panel.selectedCollectionName)
    XCTAssertEqual(panel.visibleItems.count, 2)

    settings.shelfLayout = .cards
    settings.copySoundEnabled = true
    settings.soundVolume = 0.35
    let relaunchedSettings = SettingsModel(defaults: defaults)
    XCTAssertEqual(relaunchedSettings.shelfLayout, .cards)
    XCTAssertTrue(relaunchedSettings.copySoundEnabled)
    XCTAssertEqual(relaunchedSettings.soundVolume, 0.35)
    XCTAssertTrue(relaunchedSettings.customCollectionNames.contains("Research"))
  }

  func testIgnoredPausedAndResumedCapture() {
    let monitor = ClipboardMonitorService(
      pasteboard: pasteboard, store: store, cacheService: cache, settings: settings, frontmostApp: { (nil, nil) })
    defer { monitor.stop() }
    settings.ignoredItemKindsRaw = [ClipboardItemKind.text.rawValue]
    monitor.refreshCaptureConfiguration()
    copy("Skipped text")
    monitor.pollNowAndWait()
    settle()
    XCTAssertTrue(store.items.isEmpty)

    settings.ignoredItemKindsRaw = []
    monitor.refreshCaptureConfiguration()
    copy("Allowed text")
    monitor.pollNowAndWait()
    waitUntil { self.store.items.count == 1 }
    monitor.setPaused(true)
    copy("Paused text")
    monitor.pollNowAndWait()
    settle()
    XCTAssertEqual(store.items.count, 1)
    monitor.setPaused(false)
    copy("Resumed text")
    monitor.pollNowAndWait()
    waitUntil { self.store.items.count == 2 }
    XCTAssertEqual(store.items.map(\.payload), ["Resumed text", "Allowed text"])
  }

  func testShelfCardsComposerMenusAndClosingAcrossLayouts() throws {
    store.upsert(item("A saved shelf clip"))
    for layout in [ClipboardShelfLayout.sidebar, .cards] {
      settings.shelfLayout = layout
      let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
      let controller = ClipboardPanelController(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
      let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
      defer {
        controller.hide(immediate: true)
        window.close()
      }
      controller.show()
      settle(0.32)
      let panel = try XCTUnwrap(window.contentView as? ClipboardPanelView)
      XCTAssertTrue(window.isVisible)
      XCTAssertTrue(descendants(panel).contains { $0 is ClipboardItemCardView })

      try button("New Text Clip", in: panel).performClick(nil)
      XCTAssertTrue(panel.presentedTextEditorWindow?.isVisible == true)
      try button("Clear History", in: panel).performClick(nil)
      waitUntil { panel.presentedTextEditorWindow?.isVisible != true }
      XCTAssertTrue(panel.presentedMenuWindow?.isVisible == true)
      controller.hide(immediate: true)
      XCTAssertNil(panel.presentedMenuWindow)
      XCTAssertTrue(window.childWindows?.isEmpty ?? true)
      controller.show()
      settle(0.32)
      XCTAssertTrue(window.isVisible)
      controller.toggle()
      settle(0.23)
      XCTAssertFalse(window.isVisible)
    }
  }

  func testSearchClearAndPointerHoverWithVirtualCards() throws {
    for index in 0..<40 { store.upsert(item("Workflow clip \(index)")) }
    let model = ClipboardPanelViewModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
    let panel = ClipboardPanelView(viewModel: model, onClose: {})
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 460, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = panel
    defer { window.close() }
    window.makeKeyAndOrderFront(nil)
    panel.layoutSubtreeIfNeeded()

    model.searchText = "Workflow clip 17"
    waitUntil { model.visibleItems.count == 1 }
    let search = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSSearchField }.first)
    XCTAssertEqual(search.stringValue, "Workflow clip 17")
    try button("Clear search", in: panel).performClick(nil)
    waitUntil { model.visibleItems.count == 40 }
    XCTAssertEqual(search.stringValue, "")
    panel.layoutSubtreeIfNeeded()

    let rendered = descendants(panel).compactMap { $0 as? ClipboardItemCardView }
    XCTAssertLessThan(rendered.count, 40, "History browsing should render only the nearby cards")
    let hovered = try XCTUnwrap(
      rendered.first { card in
        guard card.representedIndex != model.selectedIndex,
          let clip = sequence(first: card.superview, next: { $0?.superview }).compactMap({ $0 as? NSClipView }).first
        else { return false }
        let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: clip)
        return clip.bounds.contains(center)
      })
    let point = hovered.convert(NSPoint(x: hovered.bounds.midX, y: hovered.bounds.midY), to: nil)
    panel.updateHoverForPointer(atWindowLocation: point)
    XCTAssertEqual(model.selectedIndex, hovered.representedIndex)
    // The model transform changes synchronously; running the event loop here
    // would let the machine's real pointer replace the simulated hover.
    let layer = try XCTUnwrap(hovered.layer)
    if ClipboardShelfMotion.reducesMotion {
      XCTAssertEqual(layer.transform.m11, 1)
    } else {
      XCTAssertGreaterThan(layer.transform.m11, 1)
    }
    panel.clearPointerHoverStates()
    XCTAssertEqual(layer.transform.m11, 1)
    XCTAssertEqual(model.selectedIndex, hovered.representedIndex)
  }

  func testSettingsWindowNavigationChangesPersistentCaptureAndAppearancePreferences() throws {
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = SettingsWindowController(settings: settings, store: store, cacheService: cache)
    let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.title == "Goldfish Settings — " + AppConfiguration.buildDescription })
    defer { window.close() }
    controller.show()
    XCTAssertTrue(window.isVisible)

    func click(_ title: String) throws {
      let control = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSButton }.first { $0.title == title })
      control.performClick(nil)
      settle()
    }

    try click("Copy sound")
    XCTAssertTrue(settings.copySoundEnabled)
    try click("Capture")
    try click("Exclude likely secrets")
    XCTAssertFalse(settings.excludeSensitive)
    try click("Privacy")
    try click("Hide panel from screen sharing and recordings")
    XCTAssertTrue(settings.hideFromScreenCapture)
    try click("General")
    let reopened = SettingsModel(defaults: defaults)
    XCTAssertTrue(reopened.copySoundEnabled)
    XCTAssertFalse(reopened.excludeSensitive)
    XCTAssertTrue(reopened.hideFromScreenCapture)
  }

  private func item(_ text: String, kind: ClipboardItemKind = .text, sourceApp: String = "Workflow Tests") -> ClipboardItem {
    let now = Date()
    return testItem(
      kind: kind, payload: text, payloadHash: UUID().uuidString, createdAt: now, useCount: 0,
      sourceApp: sourceApp)
  }

  private func copy(_ text: String) {
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(text, forType: .string))
  }

  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(1.5)
    while !condition() && Date() < deadline { settle(0.01) }
    XCTAssertTrue(condition(), "Workflow did not reach its expected state", file: file, line: line)
  }

  private func settle(_ seconds: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  private func button(_ toolTip: String, in view: NSView) throws -> NSButton {
    try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.toolTip == toolTip })
  }
}
