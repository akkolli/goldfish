import AppKit
import Carbon
import WebKit
import XCTest

@testable import Goldfish

final class ClipboardPanelControllerTests: XCTestCase {
  func testHorizontalShelfSpansEachDisplayRegardlessOfSideDock() {
    for screen in [
      CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -3440, y: 200, width: 3440, height: 1440),
      CGRect(x: 100, y: -2160, width: 5120, height: 2160),
    ] {
      for sideDock: CGFloat in [-100, 0, 100] {
        let visible = CGRect(
          x: screen.minX + max(0, sideDock), y: screen.minY, width: screen.width - abs(sideDock), height: screen.height - 32)
        let frame = ClipboardPanelController.panelFrames(forScreenFrame: screen, visibleFrame: visible, layout: .cards).shown
        XCTAssertEqual(frame.minX, screen.minX + 12)
        XCTAssertEqual(frame.maxX, screen.maxX - 12)
        XCTAssertEqual(frame.minY, screen.minY + 12)
      }
    }
  }

  func testShelfLevelClearsDockWithoutCoveringSystemMenus() {
    let level = ClipboardPanelController.shelfWindowLevel.rawValue
    XCTAssertGreaterThan(level, Int(CGWindowLevelForKey(.dockWindow)))
    XCTAssertLessThan(level, NSWindow.Level.popUpMenu.rawValue)
  }

  func testStatusItemClickOwnsDismissalBeforeToggle() {
    let statusFrame = NSRect(x: -900, y: 760, width: 24, height: 24)
    let point = NSPoint(x: -888, y: 772)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      XCTAssertTrue(
        ClipboardPanelController.isPrimaryStatusItemClick(eventType: type, modifiers: [], location: point, statusItemFrame: statusFrame))
      XCTAssertFalse(
        ClipboardPanelController.isPrimaryStatusItemClick(
          eventType: type, modifiers: .control, location: point, statusItemFrame: statusFrame))
      XCTAssertFalse(
        ClipboardPanelController.isPrimaryStatusItemClick(eventType: type, modifiers: [], location: .zero, statusItemFrame: statusFrame))
      XCTAssertFalse(
        ClipboardPanelController.isPrimaryStatusItemClick(eventType: type, modifiers: [], location: point, statusItemFrame: nil))
    }
    for type in [NSEvent.EventType.keyDown, .rightMouseDown, .otherMouseUp, .leftMouseDragged] {
      XCTAssertFalse(
        ClipboardPanelController.isPrimaryStatusItemClick(eventType: type, modifiers: [], location: point, statusItemFrame: statusFrame))
    }
  }

  func testVerticalShelfGeometryAcrossDockPositionsDisplaysAndConfiguredSides() {
    let width = 420 + ClipboardShelfControls.contentTypeRailAllowance
    let cases: [(String, CGRect, CGRect?, ClipboardPanelSide?, CGRect)] = [
      (
        "Default right side", CGRect(x: -1200, y: -200, width: 1200, height: 800), nil, nil,
        CGRect(x: -12 - width, y: -188, width: width, height: 776)
      ),
      (
        "Side dock", CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 80, y: 0, width: 1432, height: 957), nil,
        CGRect(x: 1500 - width, y: 12, width: width, height: 933)
      ),
      (
        "Bottom dock", CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 96, width: 1512, height: 861), nil,
        CGRect(x: 1500 - width, y: 12, width: width, height: 933)
      ),
      (
        "Auto-hidden bottom dock", CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 4, width: 1512, height: 953), nil,
        CGRect(x: 1500 - width, y: 12, width: width, height: 933)
      ),
      ("Tall display", CGRect(x: 0, y: 0, width: 3008, height: 2000), nil, nil, CGRect(x: 2996 - width, y: 12, width: width, height: 1976)),
      (
        "Tiny display", CGRect(x: 0, y: 0, width: 640, height: 320), CGRect(x: 0, y: 48, width: 640, height: 220), nil,
        CGRect(x: 309, y: 11, width: 320, height: 246)
      ),
      (
        "Configured right", CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 96, width: 1512, height: 861), .right,
        CGRect(x: 1500 - width, y: 12, width: width, height: 933)
      ),
      (
        "Configured left", CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 80, y: 0, width: 1432, height: 957), .left,
        CGRect(x: 92, y: 12, width: width, height: 933)
      ),
      (
        "Offset display with no dock", CGRect(x: -1512, y: -120, width: 1512, height: 982), nil, .right,
        CGRect(x: -12 - width, y: -108, width: width, height: 958)
      ),
    ]
    for (name, screen, visible, side, expected) in cases {
      let frames =
        side.map { ClipboardPanelController.panelFrames(forScreenFrame: screen, visibleFrame: visible ?? screen, side: $0) }
        ?? ClipboardPanelController.panelFrames(forScreenFrame: screen, visibleFrame: visible ?? screen)
      XCTAssertEqual(frames.shown, expected, name)
      XCTAssertEqual(frames.hidden, expected.offsetBy(dx: side == .left ? -18 : 18, dy: 0), name)
      XCTAssertLessThanOrEqual(frames.shown.width, (visible ?? screen).width, name)
    }
  }

  func testOpenScreenSelectionPrefersExplicitThenPointerScreen() {
    XCTAssertEqual(
      ClipboardPanelController.selectedOpenScreen(
        explicit: "status-item-screen", preferred: nil, pointer: "pointer-screen", fallback: "fallback-screen"), "status-item-screen")
    XCTAssertEqual(
      ClipboardPanelController.selectedOpenScreen(
        explicit: Optional<String>.none, preferred: nil, pointer: "pointer-screen", fallback: "fallback-screen"), "pointer-screen")
  }

  func testReflowScreenSelectionKeepsCurrentPanelScreenAheadOfPointer() {
    XCTAssertEqual(
      ClipboardPanelController.selectedReflowScreen(
        currentPanel: "current-panel-screen", lastKnown: "last-known-screen", preferred: nil, pointer: "pointer-screen",
        fallback: "fallback-screen"), "current-panel-screen")
    XCTAssertEqual(
      ClipboardPanelController.selectedReflowScreen(
        currentPanel: Optional<String>.none, lastKnown: "last-known-screen", preferred: nil, pointer: "pointer-screen",
        fallback: "fallback-screen"), "last-known-screen")
  }

  func testPanelFrameBottomDoesNotDependOnDockHeightOnOffsetScreen() {
    let screenFrame = CGRect(x: -1512, y: 166, width: 1512, height: 982)
    for dockHeight: CGFloat in [0, 4, 48, 84, 140] {
      let visibleFrame = CGRect(
        x: screenFrame.minX, y: screenFrame.minY + dockHeight, width: screenFrame.width, height: screenFrame.height - dockHeight - 32)
      let frames = ClipboardPanelController.panelFrames(forScreenFrame: screenFrame, visibleFrame: visibleFrame)

      XCTAssertEqual(frames.shown.minY, screenFrame.minY + 12, "Dock height: \(dockHeight)")
      XCTAssertEqual(frames.shown.maxY, visibleFrame.maxY - 12, "Dock height: \(dockHeight)")
      XCTAssertEqual(frames.shown.height, 926, "Dock height: \(dockHeight)")
    }
  }

  func testPanelCollectionBehaviorStaysLocalToActiveSpaceAndSupportsFullscreen() {
    let behavior = ClipboardPanelController.panelCollectionBehavior

    XCTAssertTrue(behavior.contains(.moveToActiveSpace))
    XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(behavior.contains(.transient))
    XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
  }

  func testContentBottomInsetHandlesBottomAndSideDock() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visibleFrame = CGRect(x: 0, y: 96, width: 1512, height: 861)

    let inset = ClipboardPanelController.contentBottomInset(forScreenFrame: screenFrame, visibleFrame: visibleFrame)

    XCTAssertEqual(inset, 16)
    XCTAssertEqual(
      ClipboardPanelController.contentBottomInset(forScreenFrame: screenFrame, visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 957)),
      16)
  }

  func testPanelSharingTypeHidesWindowFromScreenCaptureWhenEnabled() {
    XCTAssertEqual(ClipboardPanelController.panelSharingType(hideFromScreenCapture: false), .readOnly)
    XCTAssertEqual(ClipboardPanelController.panelSharingType(hideFromScreenCapture: true), .none)
  }

  func testLinkPreviewFrameSitsAboveBottomShelfWhenSpaceAllows() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let shelfFrame = NSRect(x: 0, y: 0, width: 1512, height: 408)

    let frame = LinkPreviewWindowController.previewFrame(parentFrame: shelfFrame, visibleFrame: visibleFrame)

    XCTAssertGreaterThanOrEqual(frame.minY, shelfFrame.maxY + 14)
    XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - 24)
    XCTAssertEqual(frame.width, 1088)
    XCTAssertEqual(frame.height, 536)
    XCTAssertEqual(frame.midX, shelfFrame.midX, accuracy: 0.5)
  }

  func testPreviewSitsBesideAVerticalShelfWhenSpaceAllows() {
    let visible = NSRect(x: -1512, y: 80, width: 1512, height: 902)
    for side in [ClipboardPanelSide.left, .right] {
      let shelf = ClipboardPanelController.panelFrames(forScreenFrame: visible, visibleFrame: visible, side: side).shown
      let preview = LinkPreviewWindowController.previewFrame(parentFrame: shelf, visibleFrame: visible)
      XCTAssertTrue(visible.contains(preview))
      XCTAssertFalse(preview.intersects(shelf))
      XCTAssertEqual(preview.height, 560)
    }
  }

  func testLinkPreviewOnlyOpensCustomSchemesAfterExplicitLinkActivation() {
    XCTAssertEqual(LinkPreviewWindowController.navigationDecision(scheme: "mailto", navigationType: .linkActivated), .openExternally)
    XCTAssertEqual(LinkPreviewWindowController.navigationDecision(scheme: "mailto", navigationType: .other), .cancel)
    XCTAssertEqual(LinkPreviewWindowController.navigationDecision(scheme: "https", navigationType: .other), .allow)
  }

  func testCommandNumberShortcutsMapToQuickPasteSlots() {
    assertShortcutMappings(
      [
        (18, .command, 0), (19, .command, 1), (20, .command, 2), (21, .command, 3), (23, .command, 4), (22, .command, 5), (26, .command, 6),
        (28, .command, 7), (25, .command, 8),
      ], using: ClipboardPanelController.quickPasteIndex)
  }

  func testShiftCommandNumberShortcutsMapToPlainTextQuickPasteSlots() {
    assertShortcutMappings(
      [(18, [.command, .shift], 0), (25, [.command, .shift], 8), (18, .command, nil), (18, [.command, .option, .shift], nil)],
      using: ClipboardPanelController.quickPastePlainTextIndex)
  }

  func testCommandOptionNumberShortcutsMapToCollections() {
    assertShortcutMappings(
      [
        (18, [.command, .option], .mostRecent), (19, [.command, .option], .mostUsed), (20, [.command, .option], .text),
        (21, [.command, .option], .links), (23, [.command, .option], .images), (22, [.command, .option], .files),
        (26, [.command, .option], .pinned), (28, [.command, .option], .audio), (25, [.command, .option], .colors),
        (29, [.command, .option], .code), (18, [], nil), (18, .command, nil), (29, .command, nil),
      ], using: ClipboardPanelController.collectionShortcutMode)
  }

  func testSearchFieldSpacePreviewShortcutRequiresEmptySearchAndNoModifiers() {
    XCTAssertTrue(ClipboardPanelController.searchFieldPreviewShortcut(forKeyCode: 49, modifiers: [], searchText: ""))
    XCTAssertTrue(ClipboardPanelController.searchFieldPreviewShortcut(forKeyCode: 49, modifiers: [], searchText: "   "))
    XCTAssertFalse(ClipboardPanelController.searchFieldPreviewShortcut(forKeyCode: 49, modifiers: [], searchText: "release note"))
    XCTAssertFalse(ClipboardPanelController.searchFieldPreviewShortcut(forKeyCode: 49, modifiers: .command, searchText: ""))
    XCTAssertFalse(ClipboardPanelController.searchFieldPreviewShortcut(forKeyCode: 36, modifiers: [], searchText: ""))
  }

  func testNavigationShortcutsMapToShelfMovement() {
    assertShortcutMappings(
      [
        (115, [], .endpoint(last: false, extend: false)), (119, [], .endpoint(last: true, extend: false)),
        (124, [], .move(1, extend: false)), (121, [], .page(1, extend: false)), (116, [], .page(-1, extend: false)),
        (123, [], .move(-1, extend: false)), (126, .command, .endpoint(last: false, extend: false)),
        (125, .command, .endpoint(last: true, extend: false)), (124, .command, nil), (126, [], nil), (125, [], nil), (121, .shift, nil),
        (35, [], nil),
      ], using: ClipboardPanelController.navigationShortcutAction)
  }

  func testSelectionShortcutsMapToRangeAndSelectAllActions() {
    assertShortcutMappings(
      [
        (0, .command, .all), (115, .shift, .endpoint(last: false, extend: true)), (119, .shift, .endpoint(last: true, extend: true)),
        (124, .shift, .move(1, extend: true)), (121, .shift, .page(1, extend: true)), (116, .shift, .page(-1, extend: true)),
        (123, .shift, .move(-1, extend: true)), (0, [], nil), (0, [.command, .shift], nil), (124, [], nil), (124, [.command, .shift], nil),
      ], using: ClipboardPanelController.selectionShortcutAction)
  }

  func testCommandActionShortcutsMapToSelectedClipActions() {
    assertShortcutMappings(
      [
        (13, .command, .close), (8, .command, .copy), (14, .command, .editText), (3, .command, .focusSearch), (45, .command, .newText),
        (5, .command, .showInClipboard), (35, .command, .togglePin), (35, [], nil), (16, .command, .preview), (31, .command, .open),
        (15, .command, .rename), (17, .command, .toggleCapturePause), (6, .command, .undoDelete), (123, .command, .adjacentCollection(-1)),
        (124, .command, .adjacentCollection(1)), (8, [], nil), (8, [.command, .shift], nil), (9, .command, nil),
      ], using: ClipboardPanelController.commandShortcutAction)
  }

  func testSettingsShortcutMatchesOnlyItsExactLocalBinding() {
    let binding = AppConfiguration.defaultSettingsShortcut

    XCTAssertTrue(ClipboardPanelController.matchesShortcut(keyCode: UInt16(kVK_ANSI_Comma), modifiers: .command, binding: binding))
    XCTAssertFalse(
      ClipboardPanelController.matchesShortcut(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command, .shift], binding: binding))
    XCTAssertFalse(ClipboardPanelController.matchesShortcut(keyCode: UInt16(kVK_ANSI_Period), modifiers: .command, binding: binding))
  }

  func testModifiedShortcutsMapToPanelActions() {
    assertShortcutMappings(
      [
        (36, .shift, .pastePlainText), (9, [.command, .shift], .pastePlainText), (45, [.command, .shift], .createCollection), (36, [], nil),
        (8, .shift, nil), (8, .command, nil), (8, [.command, .option, .shift], nil), (31, [.command, .shift], nil),
      ], using: ClipboardPanelController.modifiedShortcutAction)
  }

  private func assertShortcutMappings<Value: Equatable>(
    _ cases: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, expected: Value?)],
    using mapping: (UInt16, NSEvent.ModifierFlags) -> Value?, file: StaticString = #filePath, line: UInt = #line
  ) {
    for testCase in cases {
      XCTAssertEqual(
        mapping(testCase.keyCode, testCase.modifiers), testCase.expected,
        "keyCode \(testCase.keyCode), modifiers \(testCase.modifiers.rawValue)", file: file, line: line)
    }
  }
}
