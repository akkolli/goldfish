import AppKit
import Carbon
import XCTest

@testable import Goldfish

final class AppDelegateTests: XCTestCase {
  func testGoldMenuBarIconRendersOrangePixelsInsteadOfATemplate() throws {
    let regular = try XCTUnwrap(AppDelegate.menuBarIcon(gold: false))
    XCTAssertTrue(regular.isTemplate)

    let gold = try XCTUnwrap(AppDelegate.menuBarIcon(gold: true))
    XCTAssertFalse(gold.isTemplate)
    let representation = try XCTUnwrap(gold.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
    let hasTransparentPixel = (0..<bitmap.pixelsHigh).contains { y in
      (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.1 }
    }
    let hasOrangePixel = (0..<bitmap.pixelsHigh).contains { y in
      (0..<bitmap.pixelsWide).contains { x in
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.5 && color.redComponent > color.greenComponent && color.greenComponent > color.blueComponent
      }
    }
    XCTAssertTrue(hasTransparentPixel)
    XCTAssertTrue(hasOrangePixel)
  }

  func testInteractiveLaunchShowsShelfButLoginLaunchStaysQuiet() {
    XCTAssertTrue(AppDelegate.shouldShowShelfOnLaunch(eventID: nil, launchReason: nil))
    XCTAssertTrue(AppDelegate.shouldShowShelfOnLaunch(eventID: kAEOpenApplication, launchReason: nil))
    XCTAssertFalse(AppDelegate.shouldShowShelfOnLaunch(eventID: kAEOpenApplication, launchReason: keyAELaunchedAsLogInItem))
    XCTAssertFalse(AppDelegate.shouldShowShelfOnLaunch(eventID: kAEOpenApplication, launchReason: keyAELaunchedAsServiceItem))
  }
  func testPresentationPlanMapsDockPreferenceToActivationPolicy() {
    let dockless = AppDelegate.presentationPlan(showMenuBarIcon: true, showDockIcon: false, changedSurface: nil)
    XCTAssertTrue(dockless.showMenuBarIcon)
    XCTAssertFalse(dockless.showDockIcon)
    XCTAssertEqual(dockless.activationPolicy, .accessory)

    let dockVisible = AppDelegate.presentationPlan(showMenuBarIcon: true, showDockIcon: true, changedSurface: nil)
    XCTAssertTrue(dockVisible.showMenuBarIcon)
    XCTAssertTrue(dockVisible.showDockIcon)
    XCTAssertEqual(dockVisible.activationPolicy, .regular)
  }

  func testPresentationPlanKeepsOneVisibleEntryPoint() {
    let hidingMenuBar = AppDelegate.presentationPlan(showMenuBarIcon: false, showDockIcon: false, changedSurface: .menuBar)
    XCTAssertFalse(hidingMenuBar.showMenuBarIcon)
    XCTAssertTrue(hidingMenuBar.showDockIcon)
    XCTAssertEqual(hidingMenuBar.activationPolicy, .regular)

    let hidingDock = AppDelegate.presentationPlan(showMenuBarIcon: false, showDockIcon: false, changedSurface: .dock)
    XCTAssertTrue(hidingDock.showMenuBarIcon)
    XCTAssertFalse(hidingDock.showDockIcon)
    XCTAssertEqual(hidingDock.activationPolicy, .accessory)
  }

  func testStatusItemMenuRoutingSeparatesLeftAndRightClick() {
    XCTAssertFalse(AppDelegate.shouldOpenStatusMenu(eventType: .leftMouseUp, modifierFlags: []))
    XCTAssertTrue(AppDelegate.shouldOpenStatusMenu(eventType: .rightMouseUp, modifierFlags: []))
    XCTAssertTrue(AppDelegate.shouldOpenStatusMenu(eventType: .leftMouseUp, modifierFlags: .control))
    XCTAssertTrue(AppDelegate.shouldOpenStatusMenu(eventType: .otherMouseUp, modifierFlags: []))
    XCTAssertFalse(AppDelegate.shouldOpenStatusMenu(eventType: .leftMouseDragged, modifierFlags: .control))
  }

  func testMainMenuPreservesCommandsAndRoutesTextEditingToTheResponder() throws {
    let target = AppDelegate()
    let open = ShortcutBinding(key: "l", modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue)
    let settings = ShortcutBinding(key: "s", modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    let menu = AppDelegate.makeMainMenu(openShortcut: open, settingsShortcut: settings, target: target)
    let submenus = try menu.items.map { try XCTUnwrap($0.submenu) }
    XCTAssertEqual(submenus.map(\.title), ["Goldfish", "File", "Edit"])
    let actions = submenus.flatMap(\.items).filter { !$0.isSeparatorItem }
    XCTAssertEqual(
      actions.map(\.title),
      [
        "Settings…", "Quit Goldfish", "New Text Clip…", "New Pinboard…", "Pause/Resume Capture", "Close", "Undo", "Redo", "Cut", "Copy",
        "Paste", "Select All", "Show Clipboard",
      ])
    for item in actions {
      XCTAssertNotNil(item.action, item.title)
      let isAppCommand = ["Settings…", "Quit Goldfish", "New Text Clip…", "New Pinboard…", "Pause/Resume Capture", "Show Clipboard"]
        .contains(item.title)
      XCTAssertEqual(item.target === target, isAppCommand, item.title)
      if !isAppCommand { XCTAssertNil(item.target, item.title) }
    }
    let settingsItem = try XCTUnwrap(actions.first { $0.title == "Settings…" })
    let openItem = try XCTUnwrap(actions.first { $0.title == "Show Clipboard" })
    XCTAssertEqual(settingsItem.keyEquivalent, "s")
    XCTAssertEqual(settingsItem.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertEqual(openItem.keyEquivalent, "l")
    XCTAssertEqual(openItem.keyEquivalentModifierMask, [.command, .option])
    XCTAssertEqual(actions.first { $0.title == "New Pinboard…" }?.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertEqual(actions.first { $0.title == "Redo" }?.keyEquivalentModifierMask, [.command, .shift])
  }

  func testStatusMenuIncludesStateRowsAndBoundedActions() {
    let settingsTitle = "Settings\u{2026}"
    let presentation = AppDelegate.statusMenuPresentation(
      historyCount: 42, isCapturePaused: false, captureStatus: "Captured text from Safari.", pasteStatus: "", shortcutStatus: "",
      accessibilityStatus: "", launchAtLoginStatus: "")
    let menu = AppDelegate.makeStatusMenu(
      presentation: presentation, isCapturePaused: false, openShortcut: AppConfiguration.defaultOpenShortcut,
      settingsShortcut: AppConfiguration.defaultSettingsShortcut, target: nil)

    XCTAssertEqual(
      menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
      ["42 clips", "-", "Open Goldfish", "Pause Capture", "-", settingsTitle, "Quit Goldfish"])

    let open = menu.items.first { $0.title == "Open Goldfish" }
    XCTAssertEqual(open?.keyEquivalent, "v")
    XCTAssertTrue(open?.keyEquivalentModifierMask.contains(.command) == true)
    XCTAssertTrue(open?.keyEquivalentModifierMask.contains(.option) == true)
    XCTAssertNotNil(open?.image)

    XCTAssertNil(menu.items.first { $0.title == "New Text Clip" })
    XCTAssertNil(menu.items.first { $0.title == "New Pinboard…" })
    XCTAssertEqual(menu.items.first?.toolTip, "Captured text from Safari.")

    let settings = menu.items.first { $0.title == settingsTitle }
    XCTAssertEqual(settings?.keyEquivalent, ",")
    XCTAssertTrue(settings?.keyEquivalentModifierMask.contains(.command) == true)

    let pauseCapture = menu.items.first { $0.title == "Pause Capture" }
    XCTAssertEqual(
      pauseCapture?.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title }, ["5 minutes", "30 minutes", "1 hour", "-", "Until resumed"])
    let indefinite = pauseCapture?.submenu?.items.first { $0.title == "Until resumed" }
    XCTAssertEqual(indefinite?.keyEquivalent, "t")
    XCTAssertTrue(indefinite?.keyEquivalentModifierMask.contains(.command) == true)
  }

  func testStatusMenuPausedStateTakesPriorityOverOlderCaptureStatus() {
    let presentation = AppDelegate.statusMenuPresentation(
      historyCount: 1, isCapturePaused: true, captureStatus: "Captured link from Safari.", pasteStatus: "Copied", shortcutStatus: "",
      accessibilityStatus: "", launchAtLoginStatus: "")
    let menu = AppDelegate.makeStatusMenu(
      presentation: presentation, isCapturePaused: true, openShortcut: AppConfiguration.defaultOpenShortcut,
      settingsShortcut: AppConfiguration.defaultSettingsShortcut, target: nil)

    XCTAssertEqual(presentation.summary, "Paused · 1 clip")
    XCTAssertEqual(presentation.detail, "Capture is paused.")
    let resumeCapture = menu.items.first { $0.title == "Resume Capture" }
    XCTAssertEqual(resumeCapture?.keyEquivalent, "t")
    XCTAssertTrue(resumeCapture?.keyEquivalentModifierMask.contains(.command) == true)
    XCTAssertNil(menu.items.first { $0.title == "Pause Capture" })
    XCTAssertNil(resumeCapture?.submenu)
  }

  func testStatusMenuPresentationShowsTimedPauseRemainingBeforeOlderStatuses() {
    let now = Date(timeIntervalSince1970: 1_000)
    let presentation = AppDelegate.statusMenuPresentation(
      historyCount: 12, isCapturePaused: true, pauseCaptureUntil: now.addingTimeInterval(5 * 60), now: now,
      captureStatus: "Captured text from Safari.", pasteStatus: "", shortcutStatus: "", accessibilityStatus: "", launchAtLoginStatus: "")

    XCTAssertEqual(presentation.summary, "Paused · 12 clips")
    XCTAssertEqual(presentation.detail, "Capture is paused for 5 more minutes.")
  }

  func testCapturePauseExpiryOnlyAppliesToExpiredTimedPauses() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(AppDelegate.shouldResumeExpiredCapturePause(isCapturePaused: true, pauseCaptureUntil: now, now: now))
    XCTAssertFalse(
      AppDelegate.shouldResumeExpiredCapturePause(isCapturePaused: true, pauseCaptureUntil: now.addingTimeInterval(1), now: now))
    XCTAssertFalse(
      AppDelegate.shouldResumeExpiredCapturePause(isCapturePaused: false, pauseCaptureUntil: now.addingTimeInterval(-1), now: now))
    XCTAssertFalse(AppDelegate.shouldResumeExpiredCapturePause(isCapturePaused: true, pauseCaptureUntil: nil, now: now))
  }

  func testStatusMenuPresentationTruncatesLongStatusText() {
    let presentation = AppDelegate.statusMenuPresentation(
      historyCount: 2000, isCapturePaused: false,
      captureStatus: "Skipped:\n" + String(repeating: "A very long ignored source application name ", count: 4), pasteStatus: "",
      shortcutStatus: "", accessibilityStatus: "", launchAtLoginStatus: "")

    XCTAssertEqual(presentation.summary, "2000 clips")
    XCTAssertNotNil(presentation.detail)
    XCTAssertLessThanOrEqual(presentation.detail?.count ?? 0, 68)
    XCTAssertTrue(presentation.detail?.hasSuffix("...") == true)
    XCTAssertFalse(presentation.detail?.contains("\n") == true)
  }
}
