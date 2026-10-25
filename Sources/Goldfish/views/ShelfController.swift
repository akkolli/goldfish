import AppKit

struct ShelfReflow {
  let frame: NSRect
  let bottomSafeInset: CGFloat
}

final class ShelfController: NSObject, NSWindowDelegate {
  // The shelf is a transient menu-bar overlay. The Dock sits above floating
  // windows, so use the lowest standard level above it while the shelf is open.
  static let shelfWindowLevel: NSWindow.Level = .statusBar

  private enum Animation {
    static let showDuration: TimeInterval = 0.28
    static let hideDuration: TimeInterval = 0.20
    static let reflowDuration: TimeInterval = 0.18
    static let easing: CAMediaTimingFunctionName = .easeInEaseOut

    static func duration(_ preferredDuration: TimeInterval) -> TimeInterval {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : preferredDuration
    }
  }
  private enum Metrics {
    static let minimumVerticalShelfWidth: CGFloat = 320
    static let maximumVerticalShelfWidthRatio: CGFloat = 0.50
  }

  private var panel: KeyablePanel!
  private var panelView: ShelfView!
  private let settings: SettingsModel
  private(set) var isVisible = false
  var statusItemFrameProvider: () -> NSRect? = { nil }
  private var clickMonitor: Any?
  private var keyMonitor: Any?
  private let pointerObserver = ShelfPointerObserver()
  private var targetApplication: NSRunningApplication?
  private var activeScreenSnapshot: (screenFrame: CGRect, visibleFrame: CGRect)?
  private let pollClipboardNow: () -> Void
  private let preferredScreenProvider: () -> NSScreen?
  private let openSettings: () -> Void
  private var isAnimating = false
  private var visibilityAnimationGeneration = 0
  private var lastAutomaticDismissalUptime: TimeInterval?
  private var previewController: PreviewController?
  private var isPresentingPreview = false
  private var isDismissingPreviews = false
  private var screenParametersObserver: NSObjectProtocol?

  private let viewModel: ShelfModel

  init(
    pasteboard: NSPasteboard = .general, store: HistoryStore, settings: SettingsModel, cacheService: MediaCache,
    dataCoordinator: DataCoordinator = DataCoordinator(), preferredScreen: @escaping () -> NSScreen? = { nil },
    pollClipboardNow: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {},
    transferFeedback: @escaping (TransferSound) -> Void = { _ in }
  ) {
    self.settings = settings
    self.viewModel = ShelfModel(
      pasteboard: pasteboard, store: store, settings: settings, cacheService: cacheService, dataCoordinator: dataCoordinator,
      transferFeedback: transferFeedback)
    self.pollClipboardNow = pollClipboardNow
    self.openSettings = openSettings
    self.preferredScreenProvider = preferredScreen
    super.init()

    viewModel.targetApplicationProvider = { [weak self] in self?.targetApplication }
    viewModel.willPasteToTarget = { [weak self] in self?.hide(immediate: true) }

    panelView = ShelfView(
      viewModel: viewModel, onClose: { [weak self] in self?.hide() }, onPreview: { [weak self] in self?.previewSelected() })

    let initialScreen = NSScreen.main
    let initialScreenFrame = initialScreen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let contentSize =
      settings.shelfLayout == .cards
      ? Self.panelFrames(
        forScreenFrame: initialScreenFrame, visibleFrame: initialScreen?.visibleFrame ?? initialScreenFrame,
        preferredWidth: CGFloat(settings.shelfWidth.rawValue), layout: .cards, largerText: settings.largerShelfText
      ).shown.size : NSSize(width: 336 + ShelfControls.contentTypeRailAllowance, height: 760)
    panel = KeyablePanel(
      contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    panel.contentView = panelView
    panelView.onMenuDismiss = { [weak self] in self?.dismissIfFocusLeftShelf() }
    panel.hasShadow = false
    panel.isFloatingPanel = true
    panel.level = Self.shelfWindowLevel
    panel.acceptsMouseMovedEvents = true
    pointerObserver.onMove = { [weak self] location in
      guard let self, self.isVisible else { return }
      self.panelView.updateHoverForPointer(atWindowLocation: location)
    }
    panel.onPointerMoved = { [weak self] location in self?.pointerObserver.observe(location) }
    panel.hidesOnDeactivate = false
    panel.delegate = self
    panel.isOpaque = false
    panel.backgroundColor = NSColor.clear
    panel.collectionBehavior = Self.panelCollectionBehavior
    panel.becomesKeyOnlyIfNeeded = false
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    applyPanelSharingSetting()

    settings.observe { [weak self] change in
      guard change == .hideFromScreenCapture || change == .panelSide || change == .other else { return }
      DispatchQueue.main.async {
        if change == .hideFromScreenCapture { self?.applyPanelSharingSetting() } else { self?.reflowPanelForScreenChange() }
      }
    }

    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.reflowPanelForScreenChange() }
  }

  deinit {
    pointerObserver.stop()
    removeClickMonitor()
    removeKeyMonitor()
    if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
  }

  func toggle(preferredScreen explicitScreen: NSScreen? = nil) { if isVisible { hide() } else { show(preferredScreen: explicitScreen) } }

  func toggleFromStatusItem(_ event: NSEvent?, preferredScreen: NSScreen? = nil) {
    // Focus loss can reach us before the status button's mouse-down action.
    // If that click already dismissed the shelf, it must not toggle it open.
    // Compare event ordering, not an animation duration or debounce interval:
    // a genuinely later click can reopen immediately, even while closing.
    if let event, event.type == .leftMouseDown, let dismissedAt = lastAutomaticDismissalUptime, event.timestamp <= dismissedAt { return }
    toggle(preferredScreen: preferredScreen)
  }

  func createCollection() {
    performWhenVisible { [weak self] in
      guard let self else { return }
      self.panelView.createCollection()
    }
  }

  func createTextClip() { performWhenVisible { [weak self] in self?.panelView.createTextClip() } }

  func didCaptureItem(_ item: Clip) { viewModel.didCaptureItem(item) }

  func show(preferredScreen explicitScreen: NSScreen? = nil) {
    if isVisible { return }
    lastAutomaticDismissalUptime = nil
    let wasAnimating = isAnimating
    visibilityAnimationGeneration += 1
    isAnimating = true
    isVisible = true

    rememberTargetApplication()
    pollClipboardNow()

    guard let screen = preferredScreen(explicitScreen: explicitScreen) else {
      isVisible = false
      isAnimating = false
      return
    }
    activeScreenSnapshot = (screen.frame, screen.visibleFrame)
    let frames = Self.panelFrames(
      forScreenFrame: screen.frame, visibleFrame: screen.visibleFrame, side: settings.panelSide,
      preferredWidth: CGFloat(settings.shelfWidth.rawValue), layout: settings.shelfLayout, largerText: settings.largerShelfText)
    panelView.setBottomSafeInset(
      settings.shelfLayout == .cards ? 14 : Self.contentBottomInset(forScreenFrame: screen.frame, visibleFrame: screen.visibleFrame))
    if !wasAnimating {
      panel.setFrame(frames.hidden, display: false)
      panel.alphaValue = 0.0
    }
    panel.makeKeyAndOrderFront(nil)
    panelView.prepareForShow()
    viewModel.selectFirstItem()
    panelView.beginOpeningTransition(fromLeft: settings.panelSide == .left)
    pointerObserver.start(in: panel)

    animatePanel(
      to: frames.shown, opacity: 1, duration: Animation.showDuration, timing: CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
    ) { controller in
      controller.panelView.finishOpeningTransition()
      guard controller.isVisible else { return }
      controller.installClickMonitor()
      if !controller.panelView.resumeTextEditorIfNeeded() { controller.panelView.focusSelectedCardForKeyboardNavigation() }
    }

    installKeyMonitor()
  }

  func hide() { hide(immediate: false) }

  @discardableResult func dismissForSettings() -> Bool {
    guard panel.attachedSheet == nil, !panelView.hasActiveTextEditor else {
      (panel.attachedSheet ?? panelView.presentedTextEditorWindow)?.makeKeyAndOrderFront(nil)
      return false
    }
    hide(immediate: true)
    return true
  }

  private func requestSettings() {
    guard dismissForSettings() else { return }
    openSettings()
  }

  func hide(immediate: Bool) {
    guard panel.attachedSheet == nil else {
      panel.attachedSheet?.makeKeyAndOrderFront(nil)
      return
    }
    guard isVisible || (immediate && isAnimating) else { return }
    visibilityAnimationGeneration += 1
    isVisible = false
    pointerObserver.stop()
    panelView.suspendTextEditor()
    panelView.dismissMenus()
    dismissPreviews()
    panelView.clearPointerHoverStates(animated: false)
    removeClickMonitor()
    removeKeyMonitor()
    if immediate {
      isAnimating = false
      panelView.finishOpeningTransition()
      panel.orderOut(nil)
      isVisible = false
      removeClickMonitor()
      removeKeyMonitor()
      activeScreenSnapshot = nil
      return
    }

    let screenFrames = activeScreenSnapshot ?? activeScreenFrames()
    let hidden = Self.panelFrames(
      forScreenFrame: screenFrames.screenFrame, visibleFrame: screenFrames.visibleFrame, side: settings.panelSide,
      preferredWidth: CGFloat(settings.shelfWidth.rawValue), layout: settings.shelfLayout, largerText: settings.largerShelfText
    ).hidden
    isAnimating = true
    panelView.beginClosingTransition()

    animatePanel(to: hidden, opacity: 0, duration: Animation.hideDuration) { controller in
      controller.panel.orderOut(nil)
      controller.panel.alphaValue = 1
      controller.activeScreenSnapshot = nil
      controller.panelView.finishOpeningTransition()
    }
  }

  /// One generation guard covers visibility changes and reflows, so an older
  /// animation cannot finish a newer transition or install stale event monitors.
  private func animatePanel(
    to frame: NSRect, opacity: CGFloat? = nil, duration: TimeInterval,
    timing: CAMediaTimingFunction = CAMediaTimingFunction(name: Animation.easing), completion: @escaping (ShelfController) -> Void
  ) {
    let generation = visibilityAnimationGeneration
    isAnimating = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Animation.duration(duration)
      context.allowsImplicitAnimation = true
      context.timingFunction = timing
      panel.animator().setFrame(frame, display: true)
      if let opacity { panel.animator().alphaValue = opacity }
    } completionHandler: { [weak self] in
      guard let self, self.visibilityAnimationGeneration == generation else { return }
      self.isAnimating = false
      completion(self)
    }
  }

  private func performWhenVisible(_ action: @escaping () -> Void) {
    if isVisible, !isAnimating {
      action()
      return
    }

    show()
    let animationDelay = Animation.duration(Animation.showDuration)
    let deadline = DispatchTime.now() + animationDelay + (animationDelay > 0 ? 0.03 : 0)
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
      guard let self, self.isVisible else { return }
      action()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    guard panel.attachedSheet == nil else { return }
    guard !isPrimaryStatusItemClick(NSApp.currentEvent) else { return }
    dismissIfFocusLeftShelf()
  }

  private func dismissIfFocusLeftShelf() {
    // Resignation arrives before the new key window is installed. Give sheets,
    // menus and our preview a chance to take focus before deciding to dismiss.
    let generation = visibilityAnimationGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self, self.visibilityAnimationGeneration == generation, self.isVisible, !self.isPresentingPreview,
        self.panel.attachedSheet == nil
      else { return }
      guard !self.ownedWindows.contains(where: \.isKeyWindow) else { return }
      self.dismissForOutsideInteraction()
    }
  }

  private var ownedWindows: [NSWindow] {
    [panel, previewController?.window, panelView.presentedMenuWindow, panelView.presentedTextEditorWindow].compactMap { $0 }
  }

  private func dismissForOutsideInteraction() {
    guard isVisible, panel.attachedSheet == nil else { return }
    lastAutomaticDismissalUptime = ProcessInfo.processInfo.systemUptime
    hide()
  }

  private func isPrimaryStatusItemClick(_ event: NSEvent?) -> Bool {
    guard let event else { return false }
    let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    return Self.isPrimaryStatusItemClick(
      eventType: event.type, modifiers: event.modifierFlags, location: location, statusItemFrame: statusItemFrameProvider())
  }

  static func isPrimaryStatusItemClick(
    eventType: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, location: NSPoint, statusItemFrame: NSRect?
  ) -> Bool {
    guard eventType == .leftMouseDown || eventType == .leftMouseUp, !modifiers.contains(.control), let statusItemFrame else { return false }
    // Include the boundary pixel: AppKit can deliver a status-button action at
    // the window's max edge, which NSRect.contains excludes.
    return location.x >= statusItemFrame.minX && location.x <= statusItemFrame.maxX
      && location.y >= statusItemFrame.minY && location.y <= statusItemFrame.maxY
  }

  func windowWillBeginSheet(_ notification: Notification) { panel.hidesOnDeactivate = false }
  func windowDidEndSheet(_ notification: Notification) {
    guard isVisible else { return }
    panel.makeKeyAndOrderFront(nil)
    panelView.focusSelectedCardForKeyboardNavigation()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if let child = panelView.presentedTextEditorWindow ?? panelView.presentedMenuWindow, child.isVisible {
      // Nonactivating panels can briefly return focus to their mouse-down owner.
      // Restore the current accessory only; a newer editor/menu owns its scope.
      DispatchQueue.main.async { [weak self, weak child] in
        guard let self, let child, self.isVisible, self.panel.isKeyWindow, child.isVisible,
          (self.panelView.presentedTextEditorWindow ?? self.panelView.presentedMenuWindow) === child
        else { return }
        child.makeKeyAndOrderFront(nil)
      }
      return
    }
    if !panelView.isSearchFieldEditing { panelView.focusSelectedCardForKeyboardNavigation() }
  }

  private func preferredScreen(explicitScreen: NSScreen? = nil) -> NSScreen? {
    let point = NSEvent.mouseLocation
    let pointerScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    return Self.selectedOpenScreen(
      explicit: explicitScreen, preferred: preferredScreenProvider(), pointer: pointerScreen, fallback: NSScreen.screens.first)
  }

  static func selectedOpenScreen<Screen>(explicit: Screen?, preferred: Screen?, pointer: Screen?, fallback: Screen?) -> Screen? {
    explicit ?? preferred ?? pointer ?? fallback
  }

  static func selectedReflowScreen<Screen>(
    currentPanel: Screen?, lastKnown: Screen?, preferred: Screen?, pointer: Screen?, fallback: Screen?
  ) -> Screen? { currentPanel ?? lastKnown ?? preferred ?? pointer ?? fallback }

  static func panelFrames(
    forScreenFrame screenFrame: CGRect, visibleFrame: CGRect, side: ShelfSide = .right, preferredWidth: CGFloat = 420,
    layout: ShelfLayout = .sidebar, largerText: Bool = false
  ) -> (shown: NSRect, hidden: NSRect) {
    let intersectedFrame = visibleFrame.intersection(screenFrame)
    let effectiveFrame = intersectedFrame.width > 0 && intersectedFrame.height > 0 ? intersectedFrame : screenFrame
    if layout == .cards {
      let card = CardLayout.gallery(width: ShelfWidth(rawValue: Int(preferredWidth)) ?? .standard, largerText: largerText)
      let margin = min(12, max(0, screenFrame.width / 20))
      let width = max(1, screenFrame.width - margin * 2)
      // One toolbar row, card lift clearance, and a dedicated scrollbar lane.
      // Span the display, including space reserved for a side or bottom Dock.
      let height = min(max(1, effectiveFrame.maxY - screenFrame.minY - 24), card.height + 102)
      let shown = NSRect(x: screenFrame.minX + margin, y: screenFrame.minY + 12, width: width, height: height)
      return (shown, shown.offsetBy(dx: 0, dy: -22))
    }
    return verticalPanelFrames(forScreenFrame: screenFrame, effectiveFrame: effectiveFrame, side: side, preferredWidth: preferredWidth)
  }

  private static func verticalPanelFrames(
    forScreenFrame screenFrame: CGRect, effectiveFrame: CGRect, side: ShelfSide, preferredWidth: CGFloat
  ) -> (shown: NSRect, hidden: NSRect) {
    let margin: CGFloat = min(12, max(0, min(effectiveFrame.width, effectiveFrame.height) / 20))
    let available = effectiveFrame.insetBy(dx: margin, dy: margin)
    // The vertical type rail expands inward so it never steals width from the
    // clip cards or forces the standard two-column grid back to one column.
    let targetWidth = panelWidth(within: max(1, available.width), preferredWidth: preferredWidth + ShelfControls.contentTypeRailAllowance)
    let shownX = side == .left ? available.minX : available.maxX - targetWidth
    // The shelf is above the Dock. Keep its top below the menu bar, but let
    // its bottom reach the display edge instead of stopping at the Dock's
    // reserved visible-frame boundary.
    let bottom = screenFrame.minY + margin
    let shown = NSRect(x: shownX, y: bottom, width: targetWidth, height: max(1, available.maxY - bottom))
    return (shown, shown.offsetBy(dx: side == .left ? -18 : 18, dy: 0))
  }

  private static func panelWidth(within visibleWidth: CGFloat, preferredWidth: CGFloat) -> CGFloat {
    let available = max(1, visibleWidth)
    let preferred = min(preferredWidth, floor(available * Metrics.maximumVerticalShelfWidthRatio))
    return min(available, max(Metrics.minimumVerticalShelfWidth, preferred))
  }

  static func contentBottomInset(forScreenFrame screenFrame: CGRect, visibleFrame: CGRect) -> CGFloat {
    // Keep the footer comfortably inset from the shelf's rounded bottom edge.
    16
  }

  static var panelCollectionBehavior: NSWindow.CollectionBehavior { [.moveToActiveSpace, .fullScreenAuxiliary, .transient] }

  static func reflowPlan(
    forScreenFrame screenFrame: CGRect, visibleFrame: CGRect, side: ShelfSide = .right, preferredWidth: CGFloat = 420,
    layout: ShelfLayout = .sidebar, largerText: Bool = false
  ) -> ShelfReflow {
    let frames = panelFrames(
      forScreenFrame: screenFrame, visibleFrame: visibleFrame, side: side, preferredWidth: preferredWidth, layout: layout,
      largerText: largerText)
    return ShelfReflow(
      frame: frames.shown,
      bottomSafeInset: layout == .cards ? 14 : contentBottomInset(forScreenFrame: screenFrame, visibleFrame: visibleFrame))
  }

  static func panelSharingType(hideFromScreenCapture: Bool) -> NSWindow.SharingType { hideFromScreenCapture ? .none : .readOnly }

  private func applyPanelSharingSetting() {
    panel.sharingType = Self.panelSharingType(hideFromScreenCapture: settings.hideFromScreenCapture)
  }

  private func rememberTargetApplication() {
    if targetApplication?.isTerminated == true { targetApplication = nil }
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != NSRunningApplication.current.processIdentifier
    else { return }
    targetApplication = frontmost
  }

  private func removeClickMonitor() {
    if let clickMonitor {
      NSEvent.removeMonitor(clickMonitor)
      self.clickMonitor = nil
    }
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleKeyEvent(event)
    }
  }

  private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
    guard shouldHandlePanelKeyEvent(event),
      let action = ShelfKeyAction.key(
        event.keyCode, modifiers: event.modifierFlags, settingsShortcut: settings.settingsShortcut,
        searchText: panelView.isSearchFieldEditing ? panelView.searchTextForKeyboardShortcut : nil)
    else { return event }
    switch action {
    case .command(let command): performShortcutAction(command)
    case .paste(let index, let plain): viewModel.pasteItem(at: index, asPlainText: plain)
    case .destination(let mode): viewModel.sortMode = mode
    case .navigate(let navigation): panelView.navigate(navigation, fromPanel: true)
    case .settings: requestSettings()
    case .cancel: if !panelView.clearSearchForKeyboardCancel() { hide() }
    }
    return nil
  }

  private func performShortcutAction(_ action: ClipCommand) {
    switch action {
    case .close: hide()
    case .preview: previewSelected()
    case .toggleCapturePause: toggleCapturePauseFromShortcut()
    default: panelView.performCommand(action)
    }
  }

  private func toggleCapturePauseFromShortcut() {
    settings.pauseCaptureUntil = nil
    if settings.pauseCapture {
      settings.pauseCapture = false
      settings.setStatus(.capture, "Capture resumed.")
    } else {
      settings.pauseCapture = true
      settings.setStatus(.capture, "Capture is paused.")
    }
  }

  private func previewSelected() {
    guard panel.attachedSheet == nil, !panelView.hasActiveTextEditor else { return }
    isPresentingPreview = true
    defer { isPresentingPreview = false }
    dismissPreviews()
    if let request = viewModel.linkPreviewRequestForSelected() {
      let controller = LinkPreviewWindowController()
      previewController = controller
      configurePreviewLifecycle(controller)
      controller.show(request, relativeTo: panel)
      return
    }
    guard let url = viewModel.previewURLForSelected(), let item = viewModel.selectedItem else {
      viewModel.reportPreviewUnavailable()
      return
    }
    let controller = ClipPreviewController(url: url, title: ClipPresentation().titleText(for: item))
    previewController = controller
    configurePreviewLifecycle(controller)
    controller.present(relativeTo: panel)
  }

  private func configurePreviewLifecycle(_ controller: PreviewController) {
    controller.onClose = { [weak self] in
      guard let self, self.isVisible, !self.isDismissingPreviews else { return }
      self.panel.makeKeyAndOrderFront(nil)
      self.panelView.focusSelectedCardForKeyboardNavigation()
    }
    controller.onResignKey = { [weak self] in self?.dismissIfFocusLeftShelf() }
  }

  private func dismissPreviews() {
    isDismissingPreviews = true
    previewController?.close()
    previewController = nil
    isDismissingPreviews = false
  }

  private func shouldHandlePanelKeyEvent(_ event: NSEvent) -> Bool {
    guard panel.attachedSheet == nil, !panelView.hasActiveTextEditor else { return false }
    if panel.firstResponder is ShelfFilterButton, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
      [36, 49, 125, 126].contains(event.keyCode)
    {
      return false
    }
    guard let keyWindow = NSApp.keyWindow, keyWindow == panel else { return false }

    // If a key event belongs to this panel while it has lost key status temporarily
    // during opening/animations, still allow keyboard shortcuts.
    return event.windowNumber == panel.windowNumber || NSApp.window(withWindowNumber: event.windowNumber) === panel
  }

  private func installClickMonitor() {
    removeClickMonitor()
    guard isVisible else { return }
    let panelWindowNumber = panel.windowNumber
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self else { return }
      guard self.isVisible else { return }
      guard self.panel.attachedSheet == nil else { return }
      // The status button owns this click. Dismissing here would make its
      // toggle action see a hidden shelf and immediately reopen it.
      guard !self.isPrimaryStatusItemClick(event) else { return }

      if event.windowNumber == panelWindowNumber { return }

      if NSApp.window(withWindowNumber: event.windowNumber) === self.panel { return }

      let point = NSEvent.mouseLocation
      if !self.ownedWindows.contains(where: { $0.isVisible && $0.frame.contains(point) }) { self.dismissForOutsideInteraction() }
    }
  }

  private func reflowPanelForScreenChange() {
    guard isVisible else { return }
    guard !isAnimating else { return }
    let point = NSEvent.mouseLocation
    let pointerScreen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    guard
      let screen = Self.selectedReflowScreen(
        currentPanel: panel.screen, lastKnown: screen(matchingFrame: activeScreenSnapshot?.screenFrame),
        preferred: preferredScreenProvider(), pointer: pointerScreen, fallback: NSScreen.screens.first)
    else { return }

    activeScreenSnapshot = (screen.frame, screen.visibleFrame)
    let plan = Self.reflowPlan(
      forScreenFrame: screen.frame, visibleFrame: screen.visibleFrame, side: settings.panelSide,
      preferredWidth: CGFloat(settings.shelfWidth.rawValue), layout: settings.shelfLayout, largerText: settings.largerShelfText)
    panelView.setBottomSafeInset(plan.bottomSafeInset)

    animatePanel(to: plan.frame, duration: Animation.reflowDuration) { $0.installClickMonitor() }
  }

  private func removeKeyMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }

  private func activeScreenFrames() -> (screenFrame: CGRect, visibleFrame: CGRect) {
    let pointer = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
      return (screen.frame, screen.visibleFrame)
    }

    let fallback = preferredScreen() ?? NSScreen.screens.first
    return (fallback?.frame ?? .zero, fallback?.visibleFrame ?? .zero)
  }

  private func screen(matchingFrame frame: CGRect?) -> NSScreen? {
    guard let frame else { return nil }
    return NSScreen.screens.first { $0.frame == frame }
  }
}

private final class KeyablePanel: NSPanel {
  var onPointerMoved: ((NSPoint) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    super.sendEvent(event)
    if event.type == .mouseMoved { onPointerMoved?(event.locationInWindow) }
  }
}
