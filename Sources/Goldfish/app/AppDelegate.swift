import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
  enum PresentationSurface: Equatable {
    case menuBar
    case dock
  }

  struct PresentationPlan: Equatable {
    let showMenuBarIcon: Bool
    let showDockIcon: Bool
    let activationPolicy: NSApplication.ActivationPolicy
  }

  struct StatusMenuPresentation: Equatable {
    let summary: String
    let detail: String?
    let symbolName: String
  }

  struct CapturePauseDuration: Equatable {
    let title: String
    let seconds: TimeInterval
    let symbolName: String
  }

  private static let statusMenuTextLimit = 68
  static let temporaryPauseDurations = [
    CapturePauseDuration(title: "5 minutes", seconds: 5 * 60, symbolName: "timer"),
    CapturePauseDuration(title: "30 minutes", seconds: 30 * 60, symbolName: "timer"),
    CapturePauseDuration(title: "1 hour", seconds: 60 * 60, symbolName: "clock"),
  ]

  private var cacheService: MediaCache!
  private var cloudSyncService: CloudBackup!
  private var settings: SettingsModel!
  private var soundService: TransferSounds!
  private var store: HistoryStore!
  private var monitor: ClipboardMonitor!
  private var panelController: ShelfController!
  private var settingsController: SettingsWindowController!
  private var onboardingController: OnboardingWindowController?
  private var shortcutManager: ShortcutManager!
  private var lifecycleService: AppLifecycleService!
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var pauseResumeTimer: Timer?
  private var cloudSyncPushWorkItem: DispatchWorkItem?
  private let dataCoordinator = DataCoordinator()
  private let cloudSyncStateLock = NSLock()
  private var suppressCloudSyncPush = false
  private var cloudSyncOperationGeneration = 0
  private var didPresentHistoryLoadWarning = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    settings = SettingsModel()
    soundService = TransferSounds(settings: settings)
    cacheService = MediaCache()
    cloudSyncService = CloudBackup()
    store = HistoryStore(settings: settings, cacheService: cacheService)
    Self.restoreCollectionMetadata(settings: settings, store: store)
    monitor = ClipboardMonitor(store: store, cacheService: cacheService, settings: settings)
    panelController = ShelfController(
      store: store, settings: settings, cacheService: cacheService, dataCoordinator: dataCoordinator,
      pollClipboardNow: { [weak self] in
        guard let self, self.settings.onboardingCompleted else { return }
        self.monitor.pollNow()
      }, openSettings: { [weak self] in self?.openSettings() }, transferFeedback: { [weak self] in self?.soundService.play($0) })
    panelController.statusItemFrameProvider = { [weak self] in
      guard let button = self?.statusItem?.button, let window = button.window else { return nil }
      // AppKit tracks the entire status-item window, including its edge padding.
      return window.frame.union(window.convertToScreen(button.convert(button.bounds, to: nil)))
    }
    monitor.onCapturedItem = { [weak self] item in
      self?.panelController.didCaptureItem(item)
      self?.soundService.play(.copy)
    }
    settingsController = SettingsWindowController(
      settings: settings, store: store, cacheService: cacheService, cloudSyncService: cloudSyncService, dataCoordinator: dataCoordinator,
      previewSound: { [weak self] in self?.soundService.play($0, preview: true) })
    lifecycleService = AppLifecycleService()
    shortcutManager = ShortcutManager(
      onOpenClipboardPanel: { [weak self] in DispatchQueue.main.async { self?.showClipboardPanel() } },
      onStatusChange: { [weak self] status in DispatchQueue.main.async { self?.settings.setStatus(.shortcut, status.message) } },
      openShortcut: settings.openShortcut)
    bindSettings()
    bindCloudSync()
    applyPresentation(changedSurface: nil)
    applyCapturePauseSetting()
    shortcutManager.start()
    NotificationCenter.default.addObserver(
      self, selector: #selector(shortcutRecordingChanged(_:)), name: .clipBoredShortcutRecordingChanged, object: nil)

    applyLaunchAtLoginSetting(settings.launchAtLogin)

    refreshStatusItem()
    configureMainMenu()
    presentInitialSetupIfNeeded()
    let event = NSAppleEventManager.shared().currentAppleEvent
    if settings.onboardingCompleted,
      Self.shouldShowShelfOnLaunch(eventID: event?.eventID, launchReason: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue)
    {
      panelController.show()
    }
  }

  static func shouldShowShelfOnLaunch(eventID: AEEventID?, launchReason: OSType?) -> Bool {
    guard eventID == kAEOpenApplication else { return true }
    return launchReason != keyAELaunchedAsLogInItem && launchReason != keyAELaunchedAsServiceItem
  }

  @objc private func shortcutRecordingChanged(_ notification: Notification) {
    if notification.userInfo?["recording"] as? Bool == true { shortcutManager.stop() } else { shortcutManager.start() }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    refreshAccessibilityPermissionMessage()
    onboardingController?.refreshPermissionStatus()
  }

  func applicationWillTerminate(_ notification: Notification) {
    pauseResumeTimer?.invalidate()
    cloudSyncPushWorkItem?.cancel()
    dataCoordinator.cancel()
    monitor.stop()
    shortcutManager.stop()
    cacheService.clearTemporaryPreviews(wait: true)
    if settings.clearHistoryOnQuit, store.removeAll() {
      store.flushPersistence()
      cacheService.clearCache()
      cacheService.flushForTesting()
    }
    store.flushPersistence()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let onboardingController { onboardingController.show() } else if !flag { panelController?.show() }
    return true
  }

  @objc private func showClipboardPanel() {
    guard ensureSetupCompleted() else { return }
    panelController.toggle()
  }

  @objc private func openClipboardPanel() {
    guard ensureSetupCompleted() else { return }
    panelController.show()
  }

  @objc private func createCollection() {
    guard ensureSetupCompleted() else { return }
    panelController.createCollection()
  }

  @objc private func createTextClip() {
    guard ensureSetupCompleted() else { return }
    panelController.createTextClip()
  }

  static func restoreCollectionMetadata(settings: SettingsModel, store: HistoryStore) {
    // Existing assignments are user data, including boards with old preset names.
    guard store.loadWarningMessage == nil else { return }
    for name in Set(store.items.compactMap(\.collectionName)) { settings.ensureCollection(named: name) }
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if shouldOpenStatusMenu(for: event) {
      popStatusMenu(from: sender)
      return
    }

    showClipboardPanelFromStatusButton(sender)
  }

  private func showClipboardPanelFromStatusButton(_ button: NSStatusBarButton) {
    guard ensureSetupCompleted() else { return }
    panelController.toggleFromStatusItem(NSApp.currentEvent, preferredScreen: button.window?.screen)
  }

  private func ensureSetupCompleted() -> Bool {
    guard !settings.onboardingCompleted else { return true }
    if let onboardingController { onboardingController.show() } else { presentInitialSetupIfNeeded() }
    return false
  }

  private func shouldOpenStatusMenu(for event: NSEvent?) -> Bool {
    guard let event else { return false }
    return Self.shouldOpenStatusMenu(eventType: event.type, modifierFlags: event.modifierFlags)
  }

  static func shouldOpenStatusMenu(eventType: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags) -> Bool {
    switch eventType {
    case .rightMouseDown, .rightMouseUp: return true
    case .leftMouseDown, .leftMouseUp: return modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
    case .otherMouseDown, .otherMouseUp: return true
    case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return false
    default: return false
    }
  }

  private func statusMenuTemplate() -> NSMenu {
    Self.makeStatusMenu(
      presentation: Self.statusMenuPresentation(
        historyCount: store.items.count, isCapturePaused: settings.pauseCapture, pauseCaptureUntil: settings.pauseCaptureUntil,
        captureStatus: settings.status(.capture), pasteStatus: settings.status(.paste), shortcutStatus: settings.status(.shortcut),
        accessibilityStatus: settings.status(.accessibility), launchAtLoginStatus: settings.status(.launch),
        onboardingCompleted: settings.onboardingCompleted), isCapturePaused: settings.pauseCapture, openShortcut: settings.openShortcut,
      settingsShortcut: settings.settingsShortcut, target: self)
  }

  private func refreshStatusMenu() { statusMenu = statusMenuTemplate() }

  static func statusMenuPresentation(
    historyCount: Int, isCapturePaused: Bool, pauseCaptureUntil: Date? = nil, now: Date = Date(), captureStatus: String,
    pasteStatus: String, shortcutStatus: String, accessibilityStatus: String, launchAtLoginStatus: String, onboardingCompleted: Bool = true
  ) -> StatusMenuPresentation {
    guard onboardingCompleted else {
      return StatusMenuPresentation(summary: "Setup needed", detail: "Open Goldfish to finish setup.", symbolName: "exclamationmark.circle")
    }
    let count = clipCountText(historyCount)
    let summary = isCapturePaused ? "Paused · \(count)" : count
    let status = firstPresentStatus([
      capturePauseStatusText(isCapturePaused: isCapturePaused, pauseCaptureUntil: pauseCaptureUntil, now: now), captureStatus, pasteStatus,
      shortcutStatus, launchAtLoginStatus, accessibilityStatus,
    ])
    return StatusMenuPresentation(
      summary: boundedStatusText(summary), detail: status.map { boundedStatusText($0) },
      symbolName: isCapturePaused ? "pause.circle" : "checkmark.circle")
  }

  static func makeStatusMenu(
    presentation: StatusMenuPresentation, isCapturePaused: Bool, openShortcut: ShortcutBinding, settingsShortcut: ShortcutBinding,
    target: AnyObject?
  ) -> NSMenu {
    let menu = NSMenu(title: "Goldfish")
    menu.autoenablesItems = false
    @discardableResult func action(
      _ title: String, _ selector: Selector, _ symbol: String, in destination: NSMenu? = nil, key: String = "",
      modifiers: NSEvent.ModifierFlags = [], shortcut: ShortcutBinding? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: shortcut?.key ?? key)
      item.keyEquivalentModifierMask = shortcut.map(modifierFlags) ?? modifiers
      item.target = target
      item.image = menuImage(symbol)
      (destination ?? menu).addItem(item)
      return item
    }
    let status = NSMenuItem(title: presentation.summary, action: nil, keyEquivalent: "")
    status.isEnabled = false
    status.image = menuImage(presentation.symbolName)
    status.toolTip = presentation.detail
    menu.addItem(status)
    menu.addItem(.separator())
    action("Open Goldfish", #selector(openClipboardPanel), "rectangle.bottomthird.inset.filled", shortcut: openShortcut)
    if isCapturePaused {
      action("Resume Capture", #selector(togglePauseCapture), "play.fill", key: "t", modifiers: .command)
    } else {
      let pauseMenu = NSMenu(title: "Pause Capture")
      pauseMenu.autoenablesItems = false
      for duration in temporaryPauseDurations {
        action(duration.title, #selector(pauseCaptureForDuration(_:)), duration.symbolName, in: pauseMenu).representedObject =
          duration.seconds
      }
      pauseMenu.addItem(.separator())
      action("Until resumed", #selector(togglePauseCapture), "pause.fill", in: pauseMenu, key: "t", modifiers: .command)
      let pause = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "")
      pause.image = menuImage("pause.circle")
      pause.submenu = pauseMenu
      menu.addItem(pause)
    }
    menu.addItem(.separator())
    action("Settings…", #selector(openSettings), "gearshape", shortcut: settingsShortcut)
    action("Quit Goldfish", #selector(quitApp), "power", key: "q", modifiers: .command)
    return menu
  }

  @objc private func openSettings() {
    guard panelController?.dismissForSettings() != false else { return }
    refreshAccessibilityPermissionMessage()
    settingsController.show()
  }

  @objc private func togglePauseCapture() {
    guard ensureSetupCompleted() else { return }
    if settings.pauseCapture {
      settings.pauseCapture = false
      settings.pauseCaptureUntil = nil
    } else {
      settings.pauseCaptureUntil = nil
      settings.pauseCapture = true
    }
  }

  @objc private func pauseCaptureForDuration(_ sender: NSMenuItem) {
    guard ensureSetupCompleted() else { return }
    let seconds = sender.representedObject as? TimeInterval ?? 0
    guard seconds > 0 else { return }
    settings.pauseCapture = true
    settings.pauseCaptureUntil = Date().addingTimeInterval(seconds)
  }

  @objc private func quitApp() { NSApp.terminate(nil) }

  private func refreshStatusItem() {
    guard settings.showMenuBarIcon else {
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
      }
      return
    }

    if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }

    if let button = statusItem?.button {
      button.image = Self.menuBarIcon(gold: settings.goldMenuBarIcon)
      button.contentTintColor = nil
      button.toolTip = "Goldfish"
      button.sendAction(on: [.leftMouseDown, .rightMouseUp, .otherMouseUp])
      button.target = self
      button.action = #selector(statusItemClicked(_:))
    }
    refreshStatusMenu()
    statusItem?.menu = nil
  }

  static func menuBarIcon(gold: Bool) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "Goldfish") else { return nil }
    guard gold else {
      symbol.isTemplate = true
      return symbol
    }

    let image = NSImage(size: symbol.size, flipped: false) { rect in
      symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
      guard let context = NSGraphicsContext.current else { return false }
      context.saveGraphicsState()
      context.compositingOperation = .sourceAtop
      NSColor.systemOrange.setFill()
      NSBezierPath(rect: rect).fill()
      context.restoreGraphicsState()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Goldfish"
    return image
  }

  private func popStatusMenu(from button: NSStatusBarButton) {
    refreshStatusMenu()
    statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
  }

  private static func firstPresentStatus(_ candidates: [String?]) -> String? {
    for candidate in candidates {
      guard let value = candidate?.clipboardTrimmed, !value.isEmpty else { continue }
      return value
    }
    return nil
  }

  private static func clipCountText(_ count: Int) -> String {
    if count <= 0 { return "No clips" }
    if count == 1 { return "1 clip" }
    return "\(count) clips"
  }

  static func shouldResumeExpiredCapturePause(isCapturePaused: Bool, pauseCaptureUntil: Date?, now: Date) -> Bool {
    guard isCapturePaused, let pauseCaptureUntil else { return false }
    return pauseCaptureUntil <= now
  }

  static func capturePauseStatusText(isCapturePaused: Bool, pauseCaptureUntil: Date?, now: Date) -> String? {
    guard isCapturePaused else { return nil }
    guard let pauseCaptureUntil, pauseCaptureUntil > now else { return "Capture is paused." }

    let seconds = max(0, pauseCaptureUntil.timeIntervalSince(now))
    if seconds < 60 { return "Capture is paused for less than a minute." }

    let minutes = Int(ceil(seconds / 60))
    if minutes < 60 { return "Capture is paused for \(minutes) more \(pluralized("minute", minutes))." }

    let hours = Int(ceil(Double(minutes) / 60))
    return "Capture is paused for \(hours) more \(pluralized("hour", hours))."
  }

  private static func pluralized(_ singular: String, _ count: Int) -> String { count == 1 ? singular : "\(singular)s" }

  private static func boundedStatusText(_ value: String) -> String {
    let collapsed = value.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ").clipboardTrimmed
    guard collapsed.count > statusMenuTextLimit else { return collapsed }
    return String(collapsed.prefix(statusMenuTextLimit - 3)).clipboardTrimmed + "..."
  }

  private static func menuImage(_ symbolName: String) -> NSImage? {
    guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
    image.size = NSSize(width: 15, height: 15)
    image.isTemplate = true
    return image
  }

  private static func modifierFlags(for binding: ShortcutBinding) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: binding.modifierFlags)
  }

  private func configureMainMenu() {
    NSApp.mainMenu = Self.makeMainMenu(openShortcut: settings.openShortcut, settingsShortcut: settings.settingsShortcut, target: self)
  }

  static func makeMainMenu(openShortcut: ShortcutBinding, settingsShortcut: ShortcutBinding, target: AnyObject?) -> NSMenu {
    func action(_ title: String, _ selector: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command, targeted: Bool = false)
      -> NSMenuItem
    {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = targeted ? target : nil
      return item
    }
    let sections: [(String, [NSMenuItem])] = [
      (
        "Goldfish",
        [
          action(
            "Settings…", #selector(openSettings), settingsShortcut.key, modifiers: modifierFlags(for: settingsShortcut), targeted: true),
          .separator(), action("Quit Goldfish", #selector(quitApp), "q", targeted: true),
        ]
      ),
      (
        "File",
        [
          action("New Text Clip…", #selector(createTextClip), "n", targeted: true),
          action("New Pinboard…", #selector(createCollection), "n", modifiers: [.command, .shift], targeted: true), .separator(),
          action("Pause/Resume Capture", #selector(togglePauseCapture), "t", targeted: true), .separator(),
          action("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
      ),
      (
        "Edit",
        [
          // Nil targets route editing commands through the focused responder.
          action("Undo", Selector(("undo:")), "z"), action("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]), .separator(),
          action("Cut", #selector(NSText.cut(_:)), "x"), action("Copy", #selector(NSText.copy(_:)), "c"),
          action("Paste", #selector(NSText.paste(_:)), "v"), action("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(),
          action(
            "Show Clipboard", #selector(showClipboardPanel), openShortcut.key, modifiers: modifierFlags(for: openShortcut), targeted: true),
        ]
      ),
    ]
    let menu = NSMenu()
    for (title, items) in sections {
      let parent = NSMenuItem()
      let submenu = NSMenu(title: title)
      items.forEach(submenu.addItem)
      parent.submenu = submenu
      menu.addItem(parent)
    }
    return menu
  }

  private func bindSettings() {
    settings.observe { [weak self] change in
      guard let self else { return }
      DispatchQueue.main.async { self.handleSettingsChange(change) }
    }
  }

  private func bindCloudSync() {
    var observedInitialItems = false
    store.observeItems { [weak self] _ in
      guard let self else { return }
      if !observedInitialItems {
        observedInitialItems = true
        return
      }
      guard self.settings.iCloudSyncEnabled, !self.isCloudSyncPushSuppressed else { return }
      self.scheduleCloudSyncPush()
    }

    if settings.iCloudSyncEnabled { applyCloudSyncSetting() } else { settings.setStatus(.backup, "iCloud Backup is off.") }
  }

  private func handleSettingsChange(_ change: SettingsModel.Change) {
    switch change {
    case .maxHistoryItems: store.updateHistoryLimit(settings.maxHistoryItems)
    case .historyRetention: store.normalizeHistoryLength()
    case .imageCacheMaxBytes: cacheService.purgeIfNeeded(maxBytes: settings.imageCacheMaxBytes)
    case .openShortcut:
      let status = shortcutManager.reconfigure(openShortcut: settings.openShortcut)
      settings.setStatus(.shortcut, status.message)
      refreshStatusItem()
      configureMainMenu()
    case .settingsShortcut:
      refreshStatusItem()
      configureMainMenu()
    case .launchAtLogin: applyLaunchAtLoginSetting(settings.launchAtLogin)
    case .showMenuBarIcon: applyPresentation(changedSurface: .menuBar)
    case .goldMenuBarIcon: refreshStatusItem()
    case .showDockIcon: applyPresentation(changedSurface: .dock)
    case .panelSide, .soundEffects: break
    case .cloudSync: applyCloudSyncSetting()
    case .pauseCapture: applyCapturePauseSetting()
    case .pollProfile: if settings.onboardingCompleted { monitor.setPaused(settings.pauseCapture) }
    case .includeImageTextInSearch, .ignoredItemKinds, .excludeSensitive, .ignoredApps: monitor.refreshCaptureConfiguration()
    case .hideFromScreenCapture: break
    case .defaultSortMode, .pruneDuplicates, .keepFirstImage, .clearHistoryOnQuit: break
    case .status, .collections, .other: break
    case .captureStatus: break
    }
  }

  private func applyCloudSyncSetting() {
    cloudSyncPushWorkItem?.cancel()
    cloudSyncPushWorkItem = nil
    cloudSyncOperationGeneration += 1
    dataCoordinator.setBackupEnabled(settings.iCloudSyncEnabled)
    let generation = cloudSyncOperationGeneration

    guard settings.iCloudSyncEnabled else {
      setCloudSyncPushSuppressed(false)
      settings.setStatus(.backup, "iCloud Backup is off.")
      return
    }

    settings.setStatus(.backup, "Checking iCloud Backup…")
    setCloudSyncPushSuppressed(true)
    dataCoordinator.perform({ [cloudSyncService = self.cloudSyncService!] in cloudSyncService.status() }) { [weak self] status in
      guard let self, generation == self.cloudSyncOperationGeneration, self.settings.iCloudSyncEnabled else { return }
      self.setCloudSyncPushSuppressed(false)
      self.settings.setStatus(.backup, status.message)
      if status.isAvailable && status.lastModifiedAt == nil { self.scheduleCloudSyncPush(after: 1.0) }
    }
  }

  private func scheduleCloudSyncPush(after delay: TimeInterval = 2.0) {
    cloudSyncPushWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.pushCloudSyncArchive() }
    cloudSyncPushWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func pushCloudSyncArchive() {
    guard settings.iCloudSyncEnabled else { return }
    let generation = cloudSyncOperationGeneration
    let operation = dataCoordinator.backupOperation { [cloudSyncService = self.cloudSyncService!, store = self.store!] write in
      try cloudSyncService.push(store: store, write: write)
    }
    dataCoordinator.perform(operation) { [weak self] result in
      guard let self, generation == self.cloudSyncOperationGeneration, self.settings.iCloudSyncEnabled else { return }
      switch result {
      case .success(let summary): self.settings.setStatus(.backup, "Backed up \(summary.itemCount) clips to iCloud.")
      case .failure(let error): self.settings.setStatus(.backup, "iCloud Backup failed: \(error.localizedDescription)")
      }
    }
  }

  private var isCloudSyncPushSuppressed: Bool { cloudSyncStateLock.withLock { suppressCloudSyncPush } }

  private func setCloudSyncPushSuppressed(_ suppressed: Bool) { cloudSyncStateLock.withLock { suppressCloudSyncPush = suppressed } }

  private func applyCapturePauseSetting(now: Date = Date()) {
    guard settings.onboardingCompleted else {
      settings.setStatus(.capture, "Capture is off until you finish setup.")
      return
    }
    if Self.shouldResumeExpiredCapturePause(isCapturePaused: settings.pauseCapture, pauseCaptureUntil: settings.pauseCaptureUntil, now: now)
    {
      settings.pauseCapture = false
      settings.pauseCaptureUntil = nil
      return
    }

    monitor.setPaused(settings.pauseCapture)
    scheduleCapturePauseTimer(now: now)
    if settings.showMenuBarIcon { refreshStatusMenu() }
  }

  private func scheduleCapturePauseTimer(now: Date = Date()) {
    pauseResumeTimer?.invalidate()
    pauseResumeTimer = nil

    guard settings.pauseCapture, let pauseCaptureUntil = settings.pauseCaptureUntil else { return }
    let interval = pauseCaptureUntil.timeIntervalSince(now)
    guard interval > 0 else {
      settings.pauseCapture = false
      settings.pauseCaptureUntil = nil
      return
    }

    pauseResumeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      DispatchQueue.main.async { self?.resumeExpiredCapturePause() }
    }
  }

  private func resumeExpiredCapturePause() {
    guard
      Self.shouldResumeExpiredCapturePause(
        isCapturePaused: settings.pauseCapture, pauseCaptureUntil: settings.pauseCaptureUntil, now: Date())
    else {
      applyCapturePauseSetting()
      return
    }

    settings.pauseCapture = false
    settings.pauseCaptureUntil = nil
  }

  static func presentationPlan(showMenuBarIcon: Bool, showDockIcon: Bool, changedSurface: PresentationSurface?) -> PresentationPlan {
    var plannedMenuBarIcon = showMenuBarIcon
    var plannedDockIcon = showDockIcon

    if !plannedMenuBarIcon && !plannedDockIcon {
      if changedSurface == .menuBar { plannedDockIcon = true } else { plannedMenuBarIcon = true }
    }

    return PresentationPlan(
      showMenuBarIcon: plannedMenuBarIcon, showDockIcon: plannedDockIcon, activationPolicy: plannedDockIcon ? .regular : .accessory)
  }

  private func applyPresentation(changedSurface: PresentationSurface?) {
    let plan = Self.presentationPlan(
      showMenuBarIcon: settings.showMenuBarIcon, showDockIcon: settings.showDockIcon, changedSurface: changedSurface)

    if settings.showMenuBarIcon != plan.showMenuBarIcon { settings.showMenuBarIcon = plan.showMenuBarIcon }
    if settings.showDockIcon != plan.showDockIcon { settings.showDockIcon = plan.showDockIcon }

    NSApp.setActivationPolicy(plan.activationPolicy)
    configureMainMenu()
    refreshStatusItem()
  }

  private func applyLaunchAtLoginSetting(_ shouldLaunch: Bool) {
    let result = lifecycleService.applyLaunchAtLogin(shouldLaunch)
    switch result {
    case .success:
      settings.setStatus(.launch, "")
      if settings.launchAtLogin != shouldLaunch { settings.launchAtLogin = shouldLaunch }
    case .noChange: settings.setStatus(.launch, "")
    case .failure(let message):
      settings.setStatus(.launch, "Launch-at-login failed: \(message)")
      let actualState = lifecycleService.isEnabled()
      if settings.launchAtLogin != actualState { settings.launchAtLogin = actualState }
    }
  }

  private func refreshAccessibilityPermissionMessage() {
    if AccessibilityPermissionService.isTrusted {
      settings.setStatus(.accessibility, "")
    } else {
      settings.setStatus(.accessibility, "Accessibility permission not granted. Capture still works; paste falls back to copy.")
    }
    refreshStatusItem()
  }

  private func requestInitialAccessibilityPermissionIfNeeded() {
    refreshAccessibilityPermissionMessage()
    if AccessibilityPermissionService.isTrusted { return }

    if !settings.accessibilityNoticeShown {
      settings.markAccessibilityNoticeShown()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showAccessibilityPermissionNoticeIfNeeded() }
    }
  }

  private func showAccessibilityPermissionNoticeIfNeeded() {
    guard !AccessibilityPermissionService.isTrusted else {
      refreshAccessibilityPermissionMessage()
      return
    }

    let alert = NSAlert(
      title: "Allow automatic paste?",
      message:
        "Goldfish captures history without extra permission. Grant Accessibility only for direct paste; otherwise paste actions copy the clip.",
      buttons: ["Open Accessibility Settings", "Later"])

    if alert.runModal() == .alertFirstButtonReturn {
      _ = AccessibilityPermissionService.requestPromptIfNeeded()
      if !AccessibilityPermissionService.isTrusted { AccessibilityPermissionService.openSystemSettings() }
    }
    refreshAccessibilityPermissionMessage()
  }

  private func presentInitialSetupIfNeeded() {
    guard !settings.onboardingCompleted else {
      monitor.start()
      requestInitialAccessibilityPermissionIfNeeded()
      presentHistoryLoadWarningIfNeeded()
      return
    }

    let controller = OnboardingWindowController(
      settings: settings, onOpenAccessibility: { [weak self] in self?.openAccessibilitySettingsFromOnboarding() },
      onFinish: { [weak self] in self?.completeInitialSetup() })
    onboardingController = controller
    controller.show()
  }

  private func openAccessibilitySettingsFromOnboarding() {
    settings.markAccessibilityNoticeShown()
    _ = AccessibilityPermissionService.requestPromptIfNeeded()
    if !AccessibilityPermissionService.isTrusted { AccessibilityPermissionService.openSystemSettings() }
    refreshAccessibilityPermissionMessage()
  }

  private func completeInitialSetup() {
    guard settings.onboardingCompleted else { return }
    onboardingController = nil
    refreshStatusItem()
    applyCapturePauseSetting()
    monitor.start()
    requestInitialAccessibilityPermissionIfNeeded()
    presentHistoryLoadWarningIfNeeded()
    panelController.show()
  }

  private func presentHistoryLoadWarningIfNeeded() {
    guard !didPresentHistoryLoadWarning, let warning = store.loadWarningMessage else { return }
    didPresentHistoryLoadWarning = true
    settings.setStatus(.capture, "Error: Some saved history could not be decrypted.")

    // Let applicationDidFinishLaunching return before entering a modal loop.
    // LaunchServices and UI automation otherwise see an app that never
    // completed launch while this warning is onscreen.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
      let alert = NSAlert(title: "Some History Could Not Be Decrypted", message: warning, style: .critical, buttons: ["OK"])
      alert.runModal()
    }
  }

}
