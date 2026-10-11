import AppKit
import XCTest

@testable import Goldfish

final class GoldfishWorkflowTests: StoredClipboardTestCase {
  override var encryptionByte: UInt8? { 71 }
  override func setUpWithError() throws {
    _ = NSApplication.shared
    try super.setUpWithError()
  }

  func testCopyCaptureSearchTransferAndEncryptedRelaunch() throws {
    let monitor = ClipboardMonitor(
      pasteboard: pasteboard, store: store, cacheService: cache, settings: settings, frontmostApp: { (nil, nil) })
    defer { monitor.stop() }
    let text = "Goldfish quartz workflow \(UUID().uuidString)"
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(text, forType: .string))
    monitor.pollNowAndWait()
    waitUntil { self.store.items.count == 1 }
    XCTAssertEqual(store.items.first?.payload, text)

    let panel = ShelfModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
    panel.searchText = "quartz"
    waitUntil { panel.visibleItems.count == 1 }
    XCTAssertEqual(panel.selectedItem?.payload, text)
    panel.copySelected()
    XCTAssertEqual(pasteboard.string(forType: .string), text)
    XCTAssertEqual(panel.statusMessage, "Copied")
    monitor.pollNowAndWait()
    settle()
    XCTAssertEqual(store.items.count, 1, "Goldfish must not capture its own transfer again")
    let database = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
    XCTAssertNil(database.range(of: Data(text.utf8)), "Saved clipboard text must stay encrypted")
    let restored = HistoryStore(settings: settings, cacheService: cache, baseURL: directory, encryptionService: encryption)
    XCTAssertEqual(restored.items.map(\.payload), [text])
  }

  func testImageCommandsPublishCompletedChangesAndCleanFailedRotation() throws {
    let paths = try XCTUnwrap(cache.cacheImage(testImage(color: .blue, size: NSSize(width: 28, height: 16)), id: UUID()))
    let originalSize = try XCTUnwrap(cache.image(for: paths.full)).size
    let clip = testItem(
      kind: .image, payload: paths.full, createdAt: Date(timeIntervalSince1970: 1_700_000_000), imagePath: paths.full,
      thumbnailPath: paths.thumb)
    store.upsert(clip)
    let model = ShelfModel(
      pasteboard: pasteboard, store: store, settings: settings, cacheService: cache, imageTextExtractor: { _ in " New\n label " })
    func completed(_ action: (@escaping () -> Void) -> Void) {
      var finished = false
      action {
        XCTAssertTrue(Thread.isMainThread)
        finished = true
      }
      waitUntil { finished }
    }
    completed { model.extractTextFromSelectedImage(completion: $0) }
    XCTAssertEqual(store.items.first?.ocrText, "New label")
    XCTAssertEqual(model.statusMessage, "Extracted text from image")
    completed { model.rotateSelectedImageClockwise(completion: $0) }
    XCTAssertEqual(model.statusMessage, "Rotated image")
    let rotated = try XCTUnwrap(store.items.first)
    XCTAssertEqual(rotated.id, clip.id)
    XCTAssertEqual(rotated.ocrText, "New label")
    XCTAssertEqual(cache.image(for: rotated.payload)?.size, NSSize(width: originalSize.height, height: originalSize.width))
    XCTAssertEqual(reopen().items, [rotated])
    cache.flushForTesting()

    // A file at the thumbnail directory blocks only the second sidecar write.
    let thumbnails = directory.appendingPathComponent("thumbnails")
    let savedThumbnails = directory.appendingPathComponent("saved-thumbnails")
    try FileManager.default.moveItem(at: thumbnails, to: savedThumbnails)
    try Data().write(to: thumbnails)
    defer {
      try? FileManager.default.removeItem(at: thumbnails)
      try? FileManager.default.moveItem(at: savedThumbnails, to: thumbnails)
    }
    let images = directory.appendingPathComponent("images")
    let before = try FileManager.default.contentsOfDirectory(atPath: images.path).sorted()
    completed { model.rotateSelectedImageClockwise(completion: $0) }
    cache.flushForTesting()
    XCTAssertEqual(model.statusMessage, "Could not rotate image")
    XCTAssertEqual(store.items, [rotated])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: images.path).sorted(), before)
    XCTAssertNotNil(cache.data(for: rotated.payload))
  }

  func testShelfCardsComposerMenusAndClosingAcrossLayouts() throws {
    store.upsert(item("A saved shelf clip"))
    for layout in [ShelfLayout.sidebar, .cards] {
      settings.shelfLayout = layout
      let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
      let controller = ShelfController(
        pasteboard: pasteboard, store: store, settings: settings, cacheService: cache, preferredScreen: { self.interfaceScreen })
      let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
      defer {
        controller.hide(immediate: true)
        window.close()
      }
      controller.show()
      settle(0.32)
      let panel = try XCTUnwrap(window.contentView as? ShelfView)
      XCTAssertTrue(window.isVisible)
      window.sharingType = .none
      XCTAssertTrue(descendants(panel).contains { $0 is CardView })

      try button("New Text Clip", in: panel).performClick(nil)
      XCTAssertTrue(panel.presentedTextEditorWindow?.isVisible == true)
      XCTAssertEqual(panel.presentedTextEditorWindow?.sharingType, NSWindow.SharingType.none)
      try button("Clear History", in: panel).performClick(nil)
      waitUntil { panel.presentedTextEditorWindow?.isVisible != true }
      XCTAssertTrue(panel.presentedMenuWindow?.isVisible == true)
      XCTAssertEqual(panel.presentedMenuWindow?.sharingType, NSWindow.SharingType.none)
      let menu = try XCTUnwrap(panel.presentedMenuWindow)
      XCTAssertEqual(menu.level, window.level)
      XCTAssertTrue(menu.isKeyWindow)
      XCTAssertFalse(panel.resumeTextEditorIfNeeded())
      window.makeKeyAndOrderFront(nil)
      waitUntil { menu.isKeyWindow }
      controller.hide(immediate: true)
      XCTAssertNil(panel.presentedMenuWindow)
      XCTAssertTrue(window.childWindows?.isEmpty ?? true)
      controller.show()
      settle(0.32)
      XCTAssertTrue(window.isVisible)
      controller.toggle()
      waitUntil { !window.isVisible }
      XCTAssertFalse(window.isVisible)
    }
  }
  private func item(_ text: String, kind: ClipKind = .text, sourceApp: String = "Workflow Tests") -> Clip {
    let now = Date()
    return testItem(kind: kind, payload: text, payloadHash: UUID().uuidString, createdAt: now, useCount: 0, sourceApp: sourceApp)
  }

  private func button(_ toolTip: String, in view: NSView) throws -> NSButton {
    try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.toolTip == toolTip })
  }
}
