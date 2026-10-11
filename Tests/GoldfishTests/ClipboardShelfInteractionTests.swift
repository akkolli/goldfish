import AppKit
import CryptoKit
import XCTest

@testable import Goldfish

final class ClipboardShelfInteractionTests: StoredClipboardTestCase {
  private var model: ClipboardPanelViewModel!
  override var encryptionByte: UInt8? { 57 }
  override func setUpWithError() throws {
    _ = NSApplication.shared
    try super.setUpWithError()
    settings.shelfLayout = .sidebar
    model = ClipboardPanelViewModel(pasteboard: pasteboard, store: store, settings: settings, cacheService: cache)
  }

  override func tearDownWithError() throws {
    model = nil
    try super.tearDownWithError()
  }

  func testDirectSymbolTypesStayInsideThePinboardAndSearch() throws {
    store.upsert(item("Alpha text", kind: .text, collection: "Work"))
    store.upsert(item("Alpha picture", kind: .image, collection: "Work"))
    store.upsert(item("Other picture", kind: .image, collection: "Work"))
    store.upsert(item("Alpha elsewhere", kind: .image, collection: "Personal"))
    settle()
    model.selectCollection(named: "Work")
    model.searchText = "Alpha"
    let (window, panel) = fixture()
    defer {
      panel.dismissMenus()
      window.close()
    }
    let images = try navigationButton("Images", in: panel)
    let allTypes = try navigationButton("All types", in: panel)
    XCTAssertEqual(images.title, "")
    XCTAssertEqual(images.accessibilityHelp(), "1 clip")
    XCTAssertEqual(allTypes.accessibilityHelp(), "2 clips")
    let typeRail = try XCTUnwrap(allTypes.superview as? NSStackView)
    XCTAssertEqual(typeRail.orientation, .vertical)
    XCTAssertEqual(typeRail.arrangedSubviews.count, 9)
    XCTAssertEqual(typeRail.spacing, 10)
    XCTAssertEqual(panel.convert(typeRail.bounds, from: typeRail).midY, panel.bounds.midY, accuracy: 0.5)
    let allClips = try navigationButton("All clips", in: panel)
    let sort = try button("Sort order", in: panel)
    XCTAssertEqual(allClips.bounds.size, NSSize(width: 34, height: 34))
    XCTAssertEqual(images.bounds.size, NSSize(width: 30, height: 30))
    let destinationsRail = try XCTUnwrap(
      descendants(panel).compactMap { $0 as? NSScrollView }.first { $0.accessibilityLabel() == "Clipboard destinations" })
    XCTAssertEqual(destinationsRail.bounds.height, 34)
    XCTAssertEqual(sort.bounds.size, NSSize(width: 34, height: 34))
    let topRow = try XCTUnwrap(sort.superview as? NSStackView)
    XCTAssertTrue(topRow.arrangedSubviews.last === sort)
    XCTAssertEqual(sort.frame.maxX, topRow.bounds.maxX, accuracy: 0.5)
    let firstCard = try XCTUnwrap(descendants(panel).compactMap { $0 as? ClipboardItemCardView }.first)
    XCTAssertLessThan(panel.convert(typeRail.bounds, from: typeRail).maxX, panel.convert(firstCard.bounds, from: firstCard).minX)
    XCTAssertEqual(
      descendants(panel).compactMap { $0 as? ShelfNavigationButton }.filter {
        ["All types", "Text", "Links", "Images", "Code", "Files", "Colors", "Audio", "Videos"].contains($0.accessibilityLabel() ?? "")
      }.count, 9)
    images.performClick(nil)
    settle()
    XCTAssertEqual(model.contentFilter, .images)
    XCTAssertEqual(model.selectedCollectionName, "Work")
    XCTAssertEqual(model.searchText, "Alpha")
    XCTAssertEqual(model.visibleItems.count, 1)
    XCTAssertNil(panel.presentedMenuWindow)
    let text = try navigationButton("Text", in: panel)
    XCTAssertEqual(text.accessibilityHelp(), "1 clip")
    text.performClick(nil)
    settle()
    XCTAssertEqual(model.contentFilter, .text)
  }

  func testAttachedTypeNotchAndHeaderShareCardEdgesAtEveryShelfWidth() throws {
    for name in ["Work", "Personal", "Ideas", "Saved", "Research", "Drafts"] {
      store.upsert(item("A short saved clip", kind: .text, collection: name))
    }
    settle()
    let (window, panel) = fixture()
    defer { window.close() }
    let notch = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier() == "shelf-type-notch" })
    let search = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSSearchField }.first?.superview)
    let trash = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Clear History" })
    let sort = try button("Sort order", in: panel)
    let allClips = try navigationButton("All clips", in: panel)
    let allTypes = try navigationButton("All types", in: panel)
    let typeRail = try XCTUnwrap(allTypes.superview as? NSStackView)
    let destinations = try XCTUnwrap(
      descendants(panel).compactMap { $0 as? NSScrollView }.first { $0.accessibilityLabel() == "Clipboard destinations" })

    for width: CGFloat in [320, 382, 466, 586] {
      for filtered in [false, true] {
        model.searchText = filtered ? "short" : ""
        window.setContentSize(NSSize(width: width, height: 760))
        panel.layoutSubtreeIfNeeded()
        settle(0.03)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.bounds.width, width, accuracy: 0.5)
        let cards = descendants(panel).compactMap { $0 as? ClipboardItemCardView }
        let leading = try XCTUnwrap(cards.map { panel.convert($0.bounds, from: $0).minX }.min())
        let trailing = try XCTUnwrap(cards.map { panel.convert($0.bounds, from: $0).maxX }.max())
        XCTAssertEqual(panel.convert(search.bounds, from: search).minX, leading, accuracy: 0.5)
        XCTAssertEqual(panel.convert(destinations.bounds, from: destinations).minX, leading, accuracy: 0.5)
        XCTAssertEqual(panel.convert(trash.bounds, from: trash).maxX, trailing, accuracy: 0.5)
        XCTAssertEqual(panel.convert(sort.bounds, from: sort).maxX, trailing, accuracy: 0.5)
        XCTAssertEqual(
          allClips.bounds.height, destinations.bounds.height, accuracy: 0.5,
          "Navigation highlights must not be clipped by native button alignment insets")
        XCTAssertEqual(notch.frame.midY, panel.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThan(notch.frame.minY, 100)
        XCTAssertLessThan(notch.frame.maxY, panel.bounds.maxY - 100)
        let center = panel.convert(NSPoint(x: allTypes.bounds.midX, y: allTypes.bounds.midY), from: allTypes)
        XCTAssertTrue(panel.hitTest(center) === allTypes, "The clear layout container must not intercept icon clicks")
        let buttons = typeRail.arrangedSubviews.sorted { $0.frame.minY < $1.frame.minY }
        for button in buttons {
          XCTAssertEqual(
            panel.convert(button.bounds, from: button).midX, notch.frame.midX, accuracy: 0.5,
            "Icons and their highlights must share the attached notch's centerline")
        }
        for pair in zip(buttons, buttons.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1.frame.minY - pair.0.frame.maxY, 9.5) }
      }
    }
    // The notch remains usable when the shelf is shorter than its contents.
    window.setContentSize(NSSize(width: 466, height: 340))
    panel.layoutSubtreeIfNeeded()
    settle(0.03)
    panel.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(notch.frame.maxY, panel.bounds.maxY - 16)
    XCTAssertGreaterThanOrEqual(notch.frame.minY, 16)
    let videos = try navigationButton("Videos", in: panel)
    videos.scrollToVisible(videos.bounds)
    let clip = try XCTUnwrap(typeRail.superview as? NSClipView)
    XCTAssertTrue(clip.documentVisibleRect.contains(videos.frame))
  }

  func testNotchJoinsTheShelfAndKeepsTheRestOfTheColumnClearInBothAppearances() throws {
    store.upsert(item("A little room for better ideas.", kind: .text))
    store.upsert(item("Save a useful thought. Keep the next action close.", kind: .text))
    store.upsert(item("https://example.com/design", kind: .url))
    store.upsert(
      item(
        "A longer note stays wide, while shorter clips share a row.\n\nSearch, destinations, and sort follow the same card edges.",
        kind: .text))
    settle()
    let (window, panel) = fixture()
    defer { window.close() }
    window.isOpaque = false
    window.backgroundColor = .clear
    window.setContentSize(NSSize(width: 466, height: 760))
    XCTAssertEqual(
      descendants(panel).compactMap { $0 as? ClipboardShelfSurfaceView }.count, 1,
      "The notch and body must share their material, without overlapping surfaces")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: appearance)
      panel.layoutSubtreeIfNeeded()
      settle(0.03)
      panel.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
      panel.cacheDisplay(in: panel.bounds, to: bitmap)
      let scale = CGFloat(bitmap.pixelsWide) / panel.bounds.width
      for y in [16, 744] {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(19 * scale), y: Int(CGFloat(y) * scale)))
        XCTAssertLessThan(color.alphaComponent, 0.01, "The rail's empty column must not draw a full-height material or tint")
      }
      for x in [36, 40, 44, 48] {
        let bridge = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(380 * scale)))
        XCTAssertGreaterThan(bridge.alphaComponent, 0.01, "The notch must join the shelf without a transparent gap")
      }
      // Optional native render for visual review, without changing system appearance.
      if let path = ProcessInfo.processInfo.environment["GOLDFISH_LAYOUT_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("shelf-\(appearance.rawValue).png"))
      }
    }
  }

  func testRefineMenuKeyboardNavigationAndEscapeDoNotApplyUntilConfirmed() throws {
    store.upsert(item("A text clip", kind: .text))
    settle()
    let (window, panel) = fixture()
    defer {
      panel.dismissMenus()
      window.close()
    }
    let filters = try button("Filters and sorting", in: panel)
    filters.performClick(nil)
    settle()
    let menu = try XCTUnwrap(panel.presentedMenuWindow)
    menu.sendEvent(try key(125, characters: "\u{f701}", window: menu))
    XCTAssertEqual((menu.firstResponder as? ShelfMenuRow)?.title, "Last 7 days")
    menu.sendEvent(try key(53, characters: "\u{1b}", window: menu))
    XCTAssertTrue(model.searchText.isEmpty)
    XCTAssertNil(panel.presentedMenuWindow)
    XCTAssertTrue(window.firstResponder === filters)
    filters.performClick(nil)
    settle()
    let reopened = try XCTUnwrap(panel.presentedMenuWindow)
    reopened.sendEvent(try key(125, characters: "\u{f701}", window: reopened))
    reopened.sendEvent(try key(36, characters: "\r", window: reopened))
    XCTAssertTrue(model.searchText.contains("after:"))
    XCTAssertNil(panel.presentedMenuWindow)
  }

  func testDateAndSourceChoicesReplaceTheirOwnFilterAndPreserveSearch() throws {
    store.upsert(item("Alpha text", kind: .text))
    settle()
    model.searchText = "Alpha app:\"Old App\" after:2020-01-01"
    let (window, panel) = fixture()
    defer {
      panel.dismissMenus()
      window.close()
    }
    let filters = try button("Filters and sorting", in: panel)
    filters.performClick(nil)
    settle()
    try row("Copied today", in: XCTUnwrap(panel.presentedMenuWindow)).performClick(nil)
    XCTAssertTrue(model.searchText.contains("Alpha"))
    XCTAssertTrue(model.searchText.contains("app:\"Old App\""))
    XCTAssertTrue(model.searchText.contains("on:"))
    XCTAssertFalse(model.searchText.contains("after:"))
    filters.performClick(nil)
    settle()
    try row("Source app", in: XCTUnwrap(panel.presentedMenuWindow)).performClick(nil)
    settle()
    try row("Design \"Notes\"", in: XCTUnwrap(panel.presentedMenuWindow)).performClick(nil)
    XCTAssertFalse(model.searchText.contains("Old App"))
    XCTAssertTrue(model.searchText.contains("app:\"Design \\\"Notes\\\"\""))
    XCTAssertTrue(model.searchText.contains("on:"))
    filters.performClick(nil)
    settle()
    try row("Source app", in: XCTUnwrap(panel.presentedMenuWindow)).performClick(nil)
    settle()
    try row("All apps", in: XCTUnwrap(panel.presentedMenuWindow)).performClick(nil)
    XCTAssertFalse(model.searchText.contains("app:"))
    XCTAssertTrue(model.searchText.contains("Alpha"))
  }

  func testFilterWindowBelongsToShelfAndClosesWithIt() throws {
    store.upsert(item("A text clip", kind: .text))
    settle()
    let before = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = ClipboardPanelController(
      pasteboard: pasteboard, store: store, settings: settings, cacheService: cache, preferredScreen: { self.interfaceScreen })
    let parent = try XCTUnwrap(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0 is NSPanel })
    let panel = try XCTUnwrap(parent.contentView as? ClipboardPanelView)
    defer {
      controller.hide(immediate: true)
      parent.close()
    }
    controller.show()
    settle(0.3)
    try button("Filters and sorting", in: panel).performClick(nil)
    settle()
    let menu = try XCTUnwrap(panel.presentedMenuWindow)
    XCTAssertEqual(parent.level, ClipboardPanelController.shelfWindowLevel)
    XCTAssertEqual(menu.level, parent.level)
    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(parent.childWindows?.contains(menu) == true)
    XCTAssertTrue(menu.isKeyWindow)
    // Activation during a mouse click can briefly return focus to the owner.
    // The open menu must retain keyboard navigation rather than paste a clip.
    parent.makeKeyAndOrderFront(nil)
    settle()
    XCTAssertTrue(menu.isKeyWindow)
    controller.hide(immediate: true)
    settle()
    XCTAssertFalse(menu.isVisible)
    XCTAssertNil(panel.presentedMenuWindow)
    XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
  }

  func testStatusClickDoesNotReopenShelfAlreadyDismissedByThatClick() throws {
    for dismissalDelay in [0.02, 0.3] {
      let (controller, window) = try controllerFixture()
      defer {
        controller.hide(immediate: true)
        window.close()
      }
      controller.show()
      settle(0.3)
      let click = try statusClick()

      // macOS can notify focus loss before delivering the status-button action.
      window.resignKey()
      controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
      settle(dismissalDelay)
      XCTAssertFalse(controller.isVisible)
      controller.toggleFromStatusItem(click)
      XCTAssertFalse(controller.isVisible, "One click must dismiss only once, even after the animation ends")
      settle(0.3)
      XCTAssertFalse(window.isVisible)
    }
  }

  func testNewStatusClickReopensDuringAutomaticDismissal() throws {
    let (controller, window) = try controllerFixture()
    defer {
      controller.hide(immediate: true)
      window.close()
    }
    controller.show()
    settle(0.3)
    window.resignKey()
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    settle(0.02)
    XCTAssertFalse(controller.isVisible)

    controller.toggleFromStatusItem(try statusClick())
    XCTAssertTrue(controller.isVisible, "A later click is a new request, without a debounce delay")
    settle(0.35)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
  }

  func testOldFocusDismissalCannotCloseANewPresentation() throws {
    let (controller, window) = try controllerFixture()
    defer {
      controller.hide(immediate: true)
      window.close()
    }
    controller.show()
    settle(0.3)
    window.resignKey()
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    controller.hide(immediate: true)
    controller.show()

    // Focus is still settling; only the queued notification from the old opening
    // should run. A fresh resignation would be a separate dismissal request.
    window.delegate = nil
    window.resignKey()
    settle(0.05)
    XCTAssertTrue(controller.isVisible)
    window.delegate = controller
    window.makeKeyAndOrderFront(nil)
    settle(0.3)
    XCTAssertTrue(window.isVisible)
  }

  func testStatusToggleClosesComposerAndSupportsRapidReopening() throws {
    let (controller, window) = try controllerFixture()
    let panel = try XCTUnwrap(window.contentView as? ClipboardPanelView)
    defer {
      controller.hide(immediate: true)
      window.close()
    }
    controller.toggleFromStatusItem(nil)
    settle(0.3)
    panel.createTextClip()
    settle()
    let composer = try XCTUnwrap(panel.presentedTextEditorWindow)
    controller.toggleFromStatusItem(try statusClick())
    XCTAssertFalse(controller.isVisible)
    XCTAssertFalse(composer.isVisible)

    controller.toggleFromStatusItem(try statusClick())
    controller.toggleFromStatusItem(try statusClick())
    controller.toggleFromStatusItem(try statusClick())
    settle(0.35)
    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(window.isVisible)
    controller.toggleFromStatusItem(nil)
    settle(0.25)
    XCTAssertFalse(window.isVisible)
  }

  private func controllerFixture() throws -> (ClipboardPanelController, NSWindow) {
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = ClipboardPanelController(
      pasteboard: pasteboard, store: store, settings: settings, cacheService: cache, preferredScreen: { self.interfaceScreen })
    let window = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
    return (controller, window)
  }

  private func statusClick() throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }

  private func fixture() -> (NSWindow, ClipboardPanelView) {
    let panel = ClipboardPanelView(viewModel: model, onClose: {})
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 420, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = panel
    positionInterfaceWindow(window)
    window.makeKeyAndOrderFront(nil)
    panel.layoutSubtreeIfNeeded()
    settle()
    return (window, panel)
  }
  private func item(_ text: String, kind: ClipboardItemKind, collection: String? = nil) -> ClipboardItem {
    let now = Date()
    return testItem(
      kind: kind, payload: text, payloadHash: UUID().uuidString, createdAt: now, useCount: 0, sourceApp: "Design \"Notes\"",
      collectionName: collection)
  }
  private func button(_ label: String, in view: NSView) throws -> ShelfFilterButton {
    try XCTUnwrap(descendants(view).compactMap { $0 as? ShelfFilterButton }.first { $0.accessibilityLabel() == label })
  }
  private func navigationButton(_ label: String, in view: NSView) throws -> ShelfNavigationButton {
    try XCTUnwrap(descendants(view).compactMap { $0 as? ShelfNavigationButton }.first { $0.accessibilityLabel() == label })
  }
  private func row(_ title: String, in window: NSWindow) throws -> ShelfMenuRow {
    try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? ShelfMenuRow }.first { $0.title == title })
  }
  private func key(_ code: UInt16, characters: String, window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [125, 126].contains(code) ? [.numericPad, .function] : [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: code))
  }
  override func settle(_ seconds: TimeInterval = 0.1) { super.settle(seconds) }
}
