import AppKit

final class SettingsWindowController: NSObject, NSWindowDelegate {
  private enum Metrics {
    static let windowSize = NSSize(width: 820, height: 650)
    static let minimumWindowSize = NSSize(width: 740, height: 460)
    static let settingsLabelWidth: CGFloat = 128
  }
  private static let tabTitles = ["General", "Shortcuts", "Capture", "Privacy", "Performance", "Data"]
  private static let allowedContentTypesValidationMessage = "At least one content type must stay enabled."
  private static let allowedContentTypesUpdatedMessage = "Allowed content types updated."
  private let settings: SettingsModel
  private let store: ClipboardStore
  private let cacheService: ClipboardCacheService
  private let cloudSyncService: ClipboardCloudSyncServicing
  private let previewSound: (ClipboardSound) -> Void
  private let dataCoordinator: ClipboardDataCoordinator
  private var dataOperationInProgress = false
  private var window: NSWindow?
  private var cachedCloudSyncStatus: ClipboardCloudSyncStatus?
  private let tabView = NSTabView()
  private var selectedTabIndex = 0
  private var sectionButtons: [NSButton] = []
  private var controlBindings: [SettingsControlBinding] = []
  private var shortcutRecorders: [Int: ShortcutRecorderButton] = [:]
  private var keepFirstImageButton: NSButton!
  private var goldMenuBarIconButton: NSButton!
  private var shelfSideRow: NSView?
  private var soundPreviews: [NSButton] = []
  private var cloudActions: [NSButton] = []
  private var archiveActions: [NSButton] = []
  private var allowedKindButtons: [(ClipboardItemKind, NSButton)] = []
  private let launchStatusLabel = NSTextField(labelWithString: "")
  private let shortcutStatusLabel = NSTextField(labelWithString: "")
  private let captureStatusLabel = NSTextField(labelWithString: "")
  private let accessibilityStatusLabel = NSTextField(labelWithString: "")
  private let pasteStatusLabel = NSTextField(labelWithString: "")
  private let dataStatusLabel = NSTextField(labelWithString: "")
  private let cloudSyncStatusLabel = NSTextField(labelWithString: "")

  init(
    settings: SettingsModel, store: ClipboardStore, cacheService: ClipboardCacheService,
    cloudSyncService: ClipboardCloudSyncServicing = ClipboardCloudSyncService(),
    dataCoordinator: ClipboardDataCoordinator = ClipboardDataCoordinator(), previewSound: @escaping (ClipboardSound) -> Void = { _ in }
  ) {
    self.settings = settings
    self.store = store
    self.cacheService = cacheService
    self.cloudSyncService = cloudSyncService
    self.dataCoordinator = dataCoordinator
    self.previewSound = previewSound
    dataCoordinator.setBackupEnabled(settings.iCloudSyncEnabled)
    super.init()
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Goldfish Settings — " + AppConfiguration.buildDescription
    window.backgroundColor = ClipboardShelfStyle.windowBackground
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentView = makeContentView()
    window.isReleasedWhenClosed = false
    window.contentMinSize = Metrics.minimumWindowSize
    window.delegate = self
    window.center()
    self.window = window
    settings.observe { [weak self] change in
      DispatchQueue.main.async {
        guard let self else { return }
        if change == .captureStatus { self.setCaptureStatusLabel(self.settings.captureStatusMessage) }
        else { self.refreshFromSettings() }
      }
    }
    refreshFromSettings(refreshCloudSyncStatus: true)
    fitSelectedTab(animated: false)
  }

  func show() {
    guard let window else { return }
    refreshFromSettings(refreshCloudSyncStatus: true)
    fitSelectedTab(animated: false)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) { commitPendingEditorDrafts() }
  private func makeContentView() -> NSView {
    tabView.translatesAutoresizingMaskIntoConstraints = false
    tabView.tabViewType = .noTabsNoBorder
    tabView.addTabViewItem(tab("General", generalSettingsView()))
    tabView.addTabViewItem(tab("Shortcuts", shortcutSettingsView()))
    tabView.addTabViewItem(tab("Capture", captureSettingsView()))
    tabView.addTabViewItem(tab("Privacy", privacySettingsView()))
    tabView.addTabViewItem(tab("Performance", performanceSettingsView()))
    tabView.addTabViewItem(tab("Data", dataSettingsView()))

    [launchStatusLabel, shortcutStatusLabel, captureStatusLabel, accessibilityStatusLabel,
      pasteStatusLabel, dataStatusLabel, cloudSyncStatusLabel].forEach(configureStatusLabel)
    let sidebar = NSVisualEffectView()
    sidebar.material = .sidebar
    sidebar.blendingMode = .behindWindow
    sidebar.state = .active
    let brand = NSTextField(labelWithString: "Goldfish")
    brand.font = .systemFont(ofSize: 19, weight: .semibold)
    let brandIcon = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil) ?? NSImage())
    brandIcon.contentTintColor = ClipboardShelfStyle.brandAccent
    brandIcon.widthAnchor.constraint(equalToConstant: 26).isActive = true
    let brandRow = NSStackView(views: [brandIcon, brand])
    brandRow.spacing = 8
    let symbols = ["slider.horizontal.3", "command", "doc.on.clipboard", "lock.shield", "speedometer", "externaldrive"]
    let navigation = NSStackView()
    navigation.orientation = .vertical
    navigation.alignment = .leading
    navigation.spacing = 4
    for (index, title) in Self.tabTitles.enumerated() {
      let button = ShelfNavigationButton(title: title, target: self, action: #selector(settingsSectionChanged(_:)))
      button.tag = index
      button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
      button.imagePosition = .imageLeading
      button.image?.size = NSSize(width: 16, height: 16)
      button.alignment = .left
      button.font = .systemFont(ofSize: 13, weight: .medium)
      button.setAccessibilityLabel(title)
      button.state = index == 0 ? .on : .off
      button.heightAnchor.constraint(equalToConstant: 36).isActive = true
      navigation.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
      sectionButtons.append(button)
    }
    let container = NSView()
    for view in [sidebar, tabView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(view)
    }
    for view in [brandRow, navigation] {
      view.translatesAutoresizingMaskIntoConstraints = false
      sidebar.addSubview(view)
    }
    NSLayoutConstraint.activate([
      sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor), sidebar.topAnchor.constraint(equalTo: container.topAnchor),
      sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 180),
      brandRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
      brandRow.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 26),
      navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
      navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
      navigation.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 28),
      tabView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
      tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
      tabView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 28),
      tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
    ])
    return container
  }

  @objc private func settingsSectionChanged(_ sender: NSButton) {
    let index = sender.tag
    guard index >= 0, index < tabView.numberOfTabViewItems else { return }
    commitPendingEditorDrafts()
    selectedTabIndex = index
    for button in sectionButtons {
      button.state = button.tag == index ? .on : .off
      button.needsDisplay = true
    }
    tabView.selectTabViewItem(at: index)
    fitSelectedTab(animated: false)
  }

  private func fitSelectedTab(animated: Bool) {
    // Settings keeps a stable frame as sections change. Long pages scroll.
    window?.contentView?.layoutSubtreeIfNeeded()
    tabView.selectedTabViewItem?.view?.needsLayout = true
    tabView.selectedTabViewItem?.view?.layoutSubtreeIfNeeded()
  }

  private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: title)
    item.label = title
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 25, weight: .bold)
    let subtitles = [
      "General": "Make Goldfish feel at home on your Mac.", "Shortcuts": "Keep your hands on the keyboard.",
      "Capture": "Choose what your clipboard remembers.", "Privacy": "Control how your history is stored and shared.",
      "Performance": "Balance responsiveness and storage.", "Data": "Back up, restore, and manage your history.",
    ]
    let introduction = caption(subtitles[title] ?? "")
    introduction.font = .systemFont(ofSize: 13)
    let header = NSStackView(views: [heading, introduction])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 7
    let content = page([header, view])
    content.setCustomSpacing(24, after: header)
    item.view = SettingsPageScrollView(page: content)
    return item
  }

  private func generalSettingsView() -> NSView {
    let historyLabel = NSTextField(labelWithString: "")
    let stepper = NSStepper()
    stepper.minValue = Double(AppConfiguration.minHistoryLength)
    stepper.maxValue = Double(AppConfiguration.maxHistoryLength)
    stepper.increment = 25
    stepper.setAccessibilityLabel("History length")
    bind(stepper, change: .maxHistoryItems, read: { [settings] in
      stepper.integerValue = settings.maxHistoryItems
      historyLabel.stringValue = "\(settings.maxHistoryItems) clips"
    }, write: { [settings] in settings.maxHistoryItems = stepper.integerValue })
    let sort = NSPopUpButton()
    for (index, title) in ["Newest first", "Most used first"].enumerated() {
      sort.addItem(withTitle: title)
      sort.lastItem?.representedObject = index
    }
    sort.setAccessibilityLabel("Sort order")
    bind(sort, change: .other, read: { [settings] in sort.selectItem(at: settings.sortByUsage ? 1 : 0) },
      write: { [settings] in settings.sortByUsage = sort.indexOfSelectedItem == 1 })
    keepFirstImageButton = toggle("Reuse the original image for duplicate copies", \.keepFirstImage, .keepFirstImage,
      help: "When duplicate items are ignored, keep the first stored image file. The clip still moves to the top of recent history.")
    goldMenuBarIconButton = toggle("Gold menu bar icon", \.goldMenuBarIcon, .goldMenuBarIcon)
    let side = popup("Shelf side", \.panelSide, .panelSide, ClipboardPanelSide.allCases, title: { $0.title })
    shelfSideRow = labeledRow("Shelf side", side)
    let launch = toggle("Launch at login", \.launchAtLogin, .launchAtLogin) { controller in
      if !controller.settings.launchAtLogin { controller.settings.setLaunchAtLoginStatus(message: "") }
      controller.refreshFromSettings()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak controller] in controller?.refreshFromSettings() }
    }
    let menu = toggle("Show Goldfish in the menu bar", \.showMenuBarIcon, .showMenuBarIcon) { controller in
      if !controller.settings.showMenuBarIcon && !controller.settings.showDockIcon { controller.settings.showDockIcon = true }
      controller.refreshFromSettings()
    }
    let dock = toggle("Show Goldfish in the Dock", \.showDockIcon, .showDockIcon) { controller in
      if !controller.settings.showDockIcon && !controller.settings.showMenuBarIcon { controller.settings.showMenuBarIcon = true }
      controller.refreshFromSettings()
    }
    return page([
      section("History", [
        labeledRow("Keep history", popup("Keep history", \.historyRetention, .historyRetention, HistoryRetention.allCases, title: { $0.title })),
        labeledRow("Clip limit", row([historyLabel, stepper])),
        toggle("Ignore duplicate items", \.pruneDuplicates, .pruneDuplicates), keepFirstImageButton]),
      section("Shelf", [
        labeledRow("Sort order", sort),
        labeledRow("Layout", popup("Shelf layout", \.shelfLayout, .other, ClipboardShelfLayout.allCases, title: { $0.title })),
        shelfSideRow!,
        labeledRow("Shelf size", popup("Shelf size", \.shelfWidth, .other, ClipboardShelfWidth.allCases, title: { $0.title })),
        toggle("Larger text in clips", \.largerShelfText, .other)]),
      soundSettingsSection(),
      section("Startup & visibility", [launch, menu, goldMenuBarIconButton, dock, launchStatusLabel]),
    ])
  }

  private func soundSettingsSection() -> NSView {
    let soundRows: [NSView] = [
      ("Copy sound", \SettingsModel.copySoundEnabled, ClipboardSound.copy,
       "Play a soft camera click when a copy is captured from any app, or copied from Goldfish."),
      ("Paste sound", \SettingsModel.pasteSoundEnabled, ClipboardSound.paste,
       "Play a soft camera click when Goldfish sends a paste to another app."),
    ].map { title, key, sound, help in
      let preview = ShelfNavigationButton()
      preview.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
      preview.imagePosition = .imageOnly
      let label = "Preview \(sound == .copy ? "copy" : "paste") sound"
      preview.setAccessibilityLabel(label)
      preview.toolTip = label
      preview.widthAnchor.constraint(equalToConstant: 28).isActive = true
      preview.heightAnchor.constraint(equalToConstant: 28).isActive = true
      bind(preview, write: { [weak self] in self?.previewSound(sound) })
      soundPreviews.append(preview)
      let space = NSView()
      space.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let result = NSStackView(views: [toggle(title, key, .soundEffects, help: help), space, preview])
      result.alignment = .centerY
      result.spacing = 8
      return result
    }
    let value = NSTextField(labelWithString: "")
    value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    value.textColor = .secondaryLabelColor
    value.alignment = .right
    value.widthAnchor.constraint(equalToConstant: 40).isActive = true
    let slider = NSSlider()
    slider.minValue = 0
    slider.maxValue = 100
    slider.isContinuous = true
    slider.setAccessibilityLabel("Sound effects volume")
    slider.setAccessibilityHelp("Percentage of your Mac's current output volume.")
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    bind(slider, change: .soundEffects, read: { [settings] in
      slider.doubleValue = settings.soundVolume * 100
      value.stringValue = "\(Int((settings.soundVolume * 100).rounded()))%"
    }, write: { [settings] in settings.soundVolume = slider.doubleValue / 100 })
    let title = NSTextField(labelWithString: "Volume")
    title.widthAnchor.constraint(equalToConstant: Metrics.settingsLabelWidth).isActive = true
    let volume = NSStackView(views: [title, slider, value])
    volume.alignment = .centerY
    volume.spacing = 8
    return section("Sound effects", soundRows + [volume, caption("Soft camera clicks for captured copies and Goldfish pastes.")])
  }

  private func captureSettingsView() -> NSView {
    let pause = toggle("Pause clipboard capture", \.pauseCapture, .pauseCapture, before: { $0.settings.pauseCaptureUntil = nil })
    let allowed = [("Text", ClipboardItemKind.text), ("Code", .code), ("Links", .url), ("Images", .image),
      ("Colors", .color), ("Audio", .audio), ("Videos", .video), ("Rich text", .richText), ("PDFs", .pdf), ("Files", .file)]
      .map { kindCheckbox($0.0, $0.1) }
    return page([
      section("Capture", [pause,
        toggle("Exclude likely secrets", \.excludeSensitive, .excludeSensitive),
        toggle("Search in image labels", \.includeImageTextInSearch, .includeImageTextInSearch), captureStatusLabel]),
      section("Allowed content types", [checkboxGrid(allowed)]),
      section("Ignored source apps", [caption(
        "macOS does not identify which app wrote the clipboard. Goldfish applies this list to the app that is frontmost when it notices the change."),
        IgnoredAppsEditor(settings: settings)]),
    ])
  }

  private func privacySettingsView() -> NSView {
    page([
      section("Local storage", [caption(
        "History stays in Application Support, encrypted with a local key. Capture pauses if the key is unavailable; storage is restricted to the current user."),
        toggle("Clear history on quit", \.clearHistoryOnQuit, .clearHistoryOnQuit)]),
      section("Screen privacy", [caption(
        "Requests that supported capture tools exclude the shelf. This is not a guarantee; close the shelf before sharing sensitive content."),
        toggle("Hide panel from screen sharing and recordings", \.hideFromScreenCapture, .hideFromScreenCapture)]),
      section("Paste permission", [caption("Clipboard capture works without this permission. Grant Accessibility only for direct paste."),
        row([NSTextField(labelWithString: "Accessibility"), accessibilityStatusLabel]),
        row([button("Open Accessibility Settings", { $0.requestAccessibilityAccess() }),
             button("Refresh Permission Status", { $0.refreshAccessibilityPermissionStatus() })]), pasteStatusLabel]),
    ])
  }

  private func performanceSettingsView() -> NSView {
    let slider = NSSlider()
    slider.minValue = Double(AppConfiguration.minCacheMaxBytes) / 1024 / 1024
    slider.maxValue = Double(AppConfiguration.maxCacheMaxBytes) / 1024 / 1024
    slider.setAccessibilityLabel("Preview storage limit in megabytes")
    let value = NSTextField(labelWithString: "")
    configureStatusLabel(value)
    bind(slider, change: .imageCacheMaxBytes, read: { [settings] in
      slider.doubleValue = Double(settings.imageCacheMaxBytes) / 1024 / 1024
      value.stringValue = "\(Int(slider.doubleValue.rounded())) MB for previews. Original clips are stored separately."
    }, write: { [settings] in settings.imageCacheMaxBytes = Int64(slider.doubleValue.rounded()) * 1024 * 1024 })
    return page([
      section("Capture responsiveness", [
        labeledRow("Responsiveness", popup("Capture responsiveness", \.pollProfileRaw, .pollProfile,
          AppConfiguration.PollProfile.allCases, title: { $0.title })),
        caption("Faster checks catch rapid copies sooner. Slower checks use less energy when you are copying frequently.")]),
      section("Preview storage", [labeledRow("Limit (MB)", slider), value]),
    ])
  }

  private func dataSettingsView() -> NSView {
    let cloud = toggle("Back up history to iCloud", \.iCloudSyncEnabled, .cloudSync) { controller in
      controller.settings.setCloudSyncStatus(message: "")
      controller.refreshCloudSyncControls(refreshStatus: controller.settings.iCloudSyncEnabled && controller.cachedCloudSyncStatus == nil)
    }
    cloudActions = [button("Back Up Now", { $0.pushICloudSyncArchive() }),
      button("Restore from iCloud", { $0.pullICloudSyncArchive() }), button("Reveal Backup File", { $0.revealICloudSyncFile() })]
    archiveActions = [button("Export Archive...", { $0.exportClipboardArchive() }), button("Import Archive...", { $0.importClipboardArchive() })]
    dataStatusLabel.isHidden = true
    return page([
      section("iCloud Backup", [caption(
        "Keep a backup of your history in iCloud and restore it when needed. Changes don’t sync between Macs. Backups are not encrypted by Goldfish."),
        cloud, row(cloudActions), cloudSyncStatusLabel]),
      section("Archive", [caption(
        "Export your history, Pinboards, and saved attachments. External files stay in their original locations. Archives are not encrypted."),
        row(archiveActions)]),
      section("Data", [button("Open History Folder", { $0.openHistoryFolder() }),
        row([button("Clear Clipboard History", { $0.clearClipboardHistory() }),
             button("Clear Thumbnail Cache", { $0.clearThumbnailCache() })]), dataStatusLabel]),
    ])
  }

  private func toggle(
    _ title: String, _ key: ReferenceWritableKeyPath<SettingsModel, Bool>, _ change: SettingsModel.Change,
    help: String? = nil, before: @escaping (SettingsWindowController) -> Void = { _ in }, after: @escaping (SettingsWindowController) -> Void = { _ in }
  ) -> NSButton {
    let control = NSButton()
    control.setButtonType(.switch)
    control.title = title
    control.setAccessibilityLabel(title)
    control.toolTip = help
    control.setAccessibilityHelp(help)
    bind(control, change: change, read: { [settings] in control.state = settings[keyPath: key] ? .on : .off }, write: { [weak self, settings] in
      if let self { before(self) }
      settings[keyPath: key] = control.state == .on
      if let self { after(self) }
    })
    return control
  }

  private func popup<Value: RawRepresentable>(
    _ label: String, _ key: ReferenceWritableKeyPath<SettingsModel, Value>, _ change: SettingsModel.Change,
    _ values: [Value], title: (Value) -> String
  ) -> NSPopUpButton where Value.RawValue == Int {
    let control = NSPopUpButton()
    control.setAccessibilityLabel(label)
    controlBindings.append(.popup(control, settings: settings, key: key, change: change, values: values, title: title))
    return control
  }

  private func button(_ title: String, _ action: @escaping (SettingsWindowController) -> Void) -> NSButton {
    let control = NSButton()
    control.title = title
    control.bezelStyle = .rounded
    control.setAccessibilityLabel(title)
    bind(control, write: { [weak self] in if let self { action(self) } })
    return control
  }

  private func bind(_ control: NSControl, change: SettingsModel.Change = .other, read: @escaping () -> Void = {}, write: @escaping () -> Void) {
    controlBindings.append(SettingsControlBinding(control: control, change: change, read: read, write: write))
  }
  private func shortcutSettingsView() -> NSView {
    let openRow = shortcutRow("Open Clipboard", binding: settings.openShortcut, baseTag: 100)
    let settingsRow = shortcutRow("Open Settings", binding: settings.settingsShortcut, baseTag: 200)
    return page([
      section(
        "Shortcuts",
        [openRow, settingsRow, caption("Click a shortcut, then press the new combination. Escape cancels."), shortcutStatusLabel]),
      section(
        "While the shelf is open",
        [
          shortcutReference("Browse clips", keys: "↑  ↓  /  ←  →"), shortcutReference("Preview a clip", keys: "Space"),
          shortcutReference("Paste or copy selection", keys: "Return"), shortcutReference("Paste as plain text", keys: "⇧Return"),
          shortcutReference("Quick paste", keys: "⌘1–9"), shortcutReference("New clip / Edit clip", keys: "⌘N / ⌘E"),
          shortcutReference("Pin / Rename", keys: "⌘P / ⌘R"), shortcutReference("Delete / Undo", keys: "⌫ / ⌘Z"),
        ]),
      section(
        "Find exactly what you copied",
        [
          caption(
            "Start typing to search, or press ⌘F. Narrow your results with filters such as app:Safari, type:image, or pinboard:\"Work\".")
        ]),
    ])
  }

  private func shortcutReference(_ title: String, keys: String) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12)
    let key = NSTextField(labelWithString: keys)
    key.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    key.textColor = ClipboardShelfStyle.secondaryText
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [label, spacer, key])
    row.alignment = .centerY
    return row
  }

  private func page(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.detachesHiddenViews = true
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }

  private func section(_ title: String, _ views: [NSView]) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    let stack = NSStackView(views: [titleLabel] + views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    let surface = SettingsSectionView()
    surface.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -18),
    ])
    for view in views where !(view is NSButton) { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return surface
  }

  private func row(_ views: [NSView]) -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: views + [spacer])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = 8
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return stack
  }

  private func checkboxGrid(_ controls: [NSButton]) -> NSView {
    let rows = stride(from: 0, to: controls.count, by: 2).map { index in
      let pair = NSStackView(views: Array(controls[index..<min(index + 2, controls.count)]))
      pair.distribution = .fillEqually
      pair.spacing = 12
      return pair
    }
    let grid = NSStackView(views: rows)
    grid.orientation = .vertical
    grid.alignment = .leading
    grid.spacing = 8
    for row in rows { row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
    return grid
  }

  private func labeledRow(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.widthAnchor.constraint(equalToConstant: Metrics.settingsLabelWidth).isActive = true
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if control is NSSlider {
      let result = NSStackView(views: [label, control])
      result.alignment = .centerY
      result.spacing = 8
      return result
    }
    return row([label, control])
  }

  private func caption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = ClipboardShelfStyle.secondaryText
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func configureStatusLabel(_ label: NSTextField) {
    label.textColor = ClipboardShelfStyle.secondaryText
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.usesSingleLineMode = false
    label.cell?.wraps = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  private func kindCheckbox(_ title: String, _ kind: ClipboardItemKind) -> NSButton {
    let control = NSButton()
    control.setButtonType(.switch)
    control.title = title
    control.setAccessibilityLabel(title)
    control.target = self
    control.action = #selector(allowedKindChanged(_:))
    control.tag = kind.rawValue
    allowedKindButtons.append((kind, control))
    return control
  }

  private func shortcutRow(_ title: String, binding: ShortcutBinding, baseTag: Int) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.widthAnchor.constraint(equalToConstant: Metrics.settingsLabelWidth).isActive = true

    let recorder = ShortcutRecorderButton(binding: binding, label: "\(title) shortcut")
    recorder.onRecord = { [weak self] candidate in
      guard let self else { return "Settings closed" }
      let message = self.shortcutValidationMessage(for: candidate, isOpenShortcut: baseTag == 100)
      self.settings.setShortcutStatus(message: message ?? "")
      guard message == nil else { return message }
      if baseTag == 100 { self.settings.openShortcut = candidate } else { self.settings.settingsShortcut = candidate }
      return nil
    }
    shortcutRecorders[baseTag] = recorder
    return row([label, recorder])
  }

  private func refreshFromSettings(refreshCloudSyncStatus: Bool = false) {
    controlBindings.forEach { $0.refresh() }
    shortcutRecorders[100]?.binding = settings.openShortcut
    shortcutRecorders[200]?.binding = settings.settingsShortcut
    keepFirstImageButton.isEnabled = settings.pruneDuplicates
    goldMenuBarIconButton.isEnabled = settings.showMenuBarIcon
    shelfSideRow?.isHidden = settings.shelfLayout == .cards
    soundPreviews.forEach { $0.isEnabled = settings.soundVolume > 0 }
    for (kind, button) in allowedKindButtons { button.state = settings.ignoredItemKindsRaw.contains(kind.rawValue) ? .off : .on }
    update(launchStatusLabel, Self.launchAtLoginStatusPresentation(storedStatus: settings.launchAtLoginErrorMessage), hideEmpty: true)
    update(shortcutStatusLabel, Self.shortcutStatusPresentation(storedStatus: settings.shortcutStatusMessage))
    setCaptureStatusLabel(settings.captureStatusMessage)
    refreshAccessibilityPermissionStatusLabel()
    update(pasteStatusLabel, Self.pasteStatusPresentation(storedStatus: settings.pasteStatusMessage))
    dataCoordinator.setBackupEnabled(settings.iCloudSyncEnabled)
    refreshCloudSyncControls(refreshStatus: refreshCloudSyncStatus)
  }

  private func update(_ label: NSTextField, _ presentation: (message: String, textColor: NSColor), hideEmpty: Bool = false) {
    label.stringValue = presentation.message
    label.textColor = presentation.textColor
    if hideEmpty { label.isHidden = presentation.message.isEmpty }
  }

  private func setCaptureStatusLabel(_ message: String) {
    update(captureStatusLabel, Self.captureStatusPresentation(storedStatus: message))
  }

  private func refreshAccessibilityPermissionStatusLabel() {
    let presentation = Self.accessibilityPermissionStatusPresentation(
      storedStatus: settings.accessibilityPermissionStatusMessage, isTrusted: AccessibilityPermissionService.isTrusted)
    accessibilityStatusLabel.stringValue = presentation.message
    accessibilityStatusLabel.textColor = presentation.textColor
  }

  private func setDataStatus(_ message: String) {
    let presentation = Self.dataStatusPresentation(storedStatus: message)
    dataStatusLabel.stringValue = presentation.message
    dataStatusLabel.isHidden = presentation.message.isEmpty
    dataStatusLabel.textColor = presentation.textColor
    if selectedTabIndex == 5 { fitSelectedTab(animated: false) }
  }

  private func refreshCloudSyncControls(refreshStatus: Bool) {
    let cloudStatus = cloudSyncStatus(refresh: refreshStatus)
    let presentation = Self.cloudSyncStatusPresentation(
      storedStatus: settings.cloudSyncStatusMessage, isSyncEnabled: settings.iCloudSyncEnabled, cloudStatus: cloudStatus)
    cloudSyncStatusLabel.stringValue = presentation.message
    cloudSyncStatusLabel.textColor = presentation.textColor
    let cloudActionsEnabled = settings.iCloudSyncEnabled && cloudStatus?.isAvailable == true && !dataOperationInProgress
    cloudActions.forEach { $0.isEnabled = cloudActionsEnabled }
  }

  private typealias StatusPresentation = (message: String, textColor: NSColor)
  private struct StatusRule {
    let prefixes: [String]
    let fragments: [String]
    let color: NSColor
  }

  private static func present(_ status: String, empty: StatusPresentation, rules: [StatusRule]) -> StatusPresentation {
    let message = status.clipboardTrimmed
    guard !message.isEmpty else { return empty }
    let folded = message.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    let color = rules.first { rule in
      rule.prefixes.contains(where: folded.hasPrefix) || rule.fragments.contains(where: folded.contains)
    }?.color ?? .secondaryLabelColor
    return (message, color)
  }

  static func launchAtLoginStatusPresentation(storedStatus: String) -> (message: String, textColor: NSColor) {
    present(storedStatus, empty: ("", .secondaryLabelColor), rules: [.init(prefixes: [""], fragments: [], color: .systemRed)])
  }

  static func captureStatusPresentation(storedStatus: String) -> (message: String, textColor: NSColor) {
    present(storedStatus, empty: ("Capture status will appear after the app sees clipboard activity.", .secondaryLabelColor), rules: [
      .init(prefixes: ["captured", "allowed content types updated"],
        fragments: ["capture running", "capture is running", "capture resumed"], color: .systemGreen),
      .init(prefixes: ["error"], fragments: ["failed", "could not"], color: .systemRed),
      .init(prefixes: ["skipped"], fragments: ["ignored", "paused", "at least one"], color: .systemOrange),
    ])
  }

  static func shortcutStatusPresentation(storedStatus: String) -> (message: String, textColor: NSColor) {
    present(storedStatus, empty: ("Registered", .systemGreen), rules: [.init(prefixes: [""], fragments: [], color: .systemRed)])
  }

  static func accessibilityPermissionStatusPresentation(storedStatus: String, isTrusted: Bool) -> (message: String, textColor: NSColor) {
    present(storedStatus,
      empty: isTrusted ? ("Granted", .systemGreen) : ("Not granted (clipboard capture still works; paste falls back to copy)", .systemOrange),
      rules: [.init(prefixes: [""], fragments: [], color: .systemOrange)])
  }

  static func pasteStatusPresentation(storedStatus: String) -> (message: String, textColor: NSColor) {
    present(storedStatus, empty: ("No paste action yet.", .secondaryLabelColor), rules: [
      .init(prefixes: [], fragments: ["could not", "failed"], color: .systemRed),
      .init(prefixes: [], fragments: ["grant accessibility", "not granted"], color: .systemOrange),
      .init(prefixes: ["pasted", "copied"], fragments: [], color: .systemGreen),
    ])
  }

  static func dataStatusPresentation(storedStatus: String) -> (message: String, textColor: NSColor) {
    present(storedStatus, empty: ("", .secondaryLabelColor), rules: [
      .init(prefixes: [], fragments: ["could not", "couldn", "denied", "error", "failed", "invalid", "missing", "not permitted", "unavailable"], color: .systemRed),
      .init(prefixes: [], fragments: ["skipped"], color: .systemOrange),
      .init(prefixes: ["exported", "imported", "cleared"], fragments: [], color: .systemGreen),
    ])
  }

  static func cloudSyncStatusPresentation(storedStatus: String, isSyncEnabled: Bool, cloudStatus: ClipboardCloudSyncStatus?) -> (message: String, textColor: NSColor) {
    let fallback: StatusPresentation = !isSyncEnabled ? ("iCloud Backup is off.", .secondaryLabelColor)
      : cloudStatus.map { ($0.message, $0.isAvailable ? .secondaryLabelColor : .systemOrange) } ?? ("iCloud Backup is unavailable.", .systemOrange)
    return present(storedStatus, empty: fallback, rules: [
      .init(prefixes: [], fragments: ["failed"], color: .systemRed),
      .init(prefixes: [], fragments: ["unavailable", "turn on", "skipped"], color: .systemOrange),
      .init(prefixes: ["backed up", "restored", "opened"], fragments: [], color: .systemGreen),
    ])
  }

  private func cloudSyncStatus(refresh: Bool) -> ClipboardCloudSyncStatus? {
    guard settings.iCloudSyncEnabled else {
      cachedCloudSyncStatus = nil
      return nil
    }

    if refresh || cachedCloudSyncStatus == nil { cachedCloudSyncStatus = cloudSyncService.status() }
    return cachedCloudSyncStatus
  }

  private func commitPendingEditorDrafts() { shortcutRecorders.values.forEach { $0.cancelRecording() } }

  @objc private func allowedKindChanged(_ sender: NSButton) {
    guard let kind = ClipboardItemKind(rawValue: sender.tag) else { return }
    var ignored = settings.ignoredItemKindsRaw
    if sender.state == .on {
      ignored.removeAll { $0 == kind.rawValue }
    } else if !ignored.contains(kind.rawValue) {
      ignored.append(kind.rawValue)
    }
    let visibleKindRawValues = Set(allowedKindButtons.map { $0.0.rawValue })
    let ignoredVisibleKindRawValues = Set(ignored.filter { visibleKindRawValues.contains($0) })
    if visibleKindRawValues.isSubset(of: ignoredVisibleKindRawValues) {
      let message = Self.allowedContentTypesValidationMessage
      sender.state = .on
      settings.setCaptureStatus(message: message)
      setCaptureStatusLabel(message)
      return
    }
    settings.ignoredItemKindsRaw = ignored
    if settings.captureStatusMessage == Self.allowedContentTypesValidationMessage {
      settings.setCaptureStatus(message: Self.allowedContentTypesUpdatedMessage)
    }
  }

  private func requestAccessibilityAccess() {
    _ = AccessibilityPermissionService.requestPromptIfNeeded()
    if !AccessibilityPermissionService.isTrusted { AccessibilityPermissionService.openSystemSettings() }
    settings.setAccessibilityPermissionStatus(
      message: AccessibilityPermissionService.isTrusted ? "" : "Accessibility permission not granted.")
    refreshAccessibilityPermissionStatus()
  }

  private func refreshAccessibilityPermissionStatus() {
    settings.setAccessibilityPermissionStatus(
      message: AccessibilityPermissionService.isTrusted ? "" : "Accessibility permission not granted.")
    refreshAccessibilityPermissionStatusLabel()
  }

  private func openHistoryFolder() { NSWorkspace.shared.open(ClipboardStore.storageDirectory()) }

  private func exportClipboardArchive() {
    let panel = NSSavePanel()
    panel.title = "Export Goldfish Archive"
    ClipboardArchivePanel.configure(panel)
    panel.nameFieldStringValue = ClipboardArchivePanel.suggestedName(defaultArchiveFileName())

    guard let window, window.attachedSheet == nil else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.setDataStatus("Exporting archive…")
      self.performDataOperation({ [store = self.store] in Result { try store.exportArchive(to: url) } }) { [weak self] result in
        switch result {
        case .success(let summary): self?.setDataStatus("Exported \(summary.itemCount) clips and \(summary.sidecarCount) attachments.")
        case .failure(let error): self?.setDataStatus(error.localizedDescription)
        }
      }
    }
  }

  private func importClipboardArchive() {
    let panel = NSOpenPanel()
    panel.title = "Import Goldfish Archive"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    ClipboardArchivePanel.configure(panel)

    guard let window, window.attachedSheet == nil else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.setDataStatus("Importing archive…")
      self.performDataOperation({ [store = self.store] in Result { try store.importArchive(from: url) } }) { [weak self] result in
        switch result {
        case .success(let summary):
          var message = "Imported \(summary.itemCount) clips and \(summary.sidecarCount) attachments."
          if summary.skippedItemCount > 0 || summary.skippedSidecarCount > 0 {
            message += " Skipped \(summary.skippedItemCount) clips and \(summary.skippedSidecarCount) attachments."
          }
          self?.setDataStatus(message)
        case .failure(let error): self?.setDataStatus(error.localizedDescription)
        }
      }
    }
  }

  private func pushICloudSyncArchive() {
    guard settings.iCloudSyncEnabled else {
      settings.setCloudSyncStatus(message: "Turn on iCloud Backup before backing up.")
      return
    }

    settings.setCloudSyncStatus(message: "Backing up to iCloud…")
    performDataOperation(
      dataCoordinator.backupOperation { [cloudSyncService, store] write in
        let summary = try cloudSyncService.push(store: store, write: write)
        return (summary, cloudSyncService.status())
      }
    ) { [weak self] result in
      guard self?.settings.iCloudSyncEnabled == true else { return }
      switch result {
      case .success(let (summary, status)):
        self?.cachedCloudSyncStatus = status
        self?.settings.setCloudSyncStatus(
          message: "Backed up \(summary.itemCount) clips and \(summary.sidecarCount) attachments to iCloud.")
      case .failure(let error): self?.settings.setCloudSyncStatus(message: "iCloud Backup failed: \(error.localizedDescription)")
      }
    }
  }

  private func pullICloudSyncArchive() {
    guard settings.iCloudSyncEnabled else {
      settings.setCloudSyncStatus(message: "Turn on iCloud Backup before restoring.")
      return
    }

    settings.setCloudSyncStatus(message: "Restoring from iCloud…")
    performDataOperation(
      dataCoordinator.backupOperation { [cloudSyncService, store] _ in
        let summary = try cloudSyncService.pull(store: store)
        return (summary, cloudSyncService.status())
      }
    ) { [weak self] result in
      guard self?.settings.iCloudSyncEnabled == true else { return }
      switch result {
      case .success(let (summary, status)):
        self?.cachedCloudSyncStatus = status
        var message = "Restored \(summary.itemCount) clips and \(summary.sidecarCount) attachments from iCloud."
        if summary.skippedItemCount > 0 || summary.skippedSidecarCount > 0 {
          message += " Skipped \(summary.skippedItemCount) clips and \(summary.skippedSidecarCount) attachments."
        }
        self?.settings.setCloudSyncStatus(message: message)
      case .failure(let error): self?.settings.setCloudSyncStatus(message: "iCloud Backup failed: \(error.localizedDescription)")
      }
    }
  }

  private func performDataOperation<ResultValue>(_ operation: @escaping () -> ResultValue, completion: @escaping (ResultValue) -> Void) {
    dataOperationInProgress = true
    archiveActions.forEach { $0.isEnabled = false }
    refreshCloudSyncControls(refreshStatus: false)
    dataCoordinator.perform(operation) { [weak self] result in
      guard let self else { return }
      self.dataOperationInProgress = false
      self.archiveActions.forEach { $0.isEnabled = true }
      completion(result)
      self.refreshCloudSyncControls(refreshStatus: false)
    }
  }

  private func revealICloudSyncFile() {
    do {
      let url = try cloudSyncService.syncArchiveURL()
      if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
      }
      cachedCloudSyncStatus = cloudSyncService.status()
      settings.setCloudSyncStatus(message: "Opened iCloud backup location.")
    } catch { settings.setCloudSyncStatus(message: "iCloud Backup failed: \(error.localizedDescription)") }
  }

  private func clearClipboardHistory() {
    confirmDestructiveAction(
      title: "Clear Clipboard History?",
      message:
        "This permanently removes all clips, including pinned clips and Pinboard contents, and saved attachments. Your current system clipboard stays unchanged.",
      buttonTitle: "Clear History"
    ) { [weak self] in
      guard let self, self.store.removeAll() else {
        self?.settings.setCaptureStatus(message: "Error: Could not clear history; existing clips are unchanged.")
        return
      }
      self.cacheService.clearTemporaryPreviews()
      self.setDataStatus("Cleared clipboard history.")
    }
  }

  private func clearThumbnailCache() {
    confirmDestructiveAction(
      title: "Clear Thumbnail Cache?",
      message: "This removes cached previews. Goldfish will recreate them when needed. Your saved clips remain available.",
      buttonTitle: "Clear Cache"
    ) { [weak self] in
      self?.cacheService.clearCache()
      self?.setDataStatus("Cleared thumbnail cache.")
    }
  }

  private func confirmDestructiveAction(title: String, message: String, buttonTitle: String, onConfirm: @escaping () -> Void) {
    guard let window, window.attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: buttonTitle)
    alert.buttons[0].keyEquivalent = "\u{1b}"
    alert.buttons[1].keyEquivalent = ""
    alert.window.defaultButtonCell = nil
    alert.window.initialFirstResponder = alert.buttons[0]
    alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { onConfirm() } }
  }

  private func defaultArchiveFileName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return "Goldfish-\(formatter.string(from: Date())).\(ClipboardArchiveService.fileExtension)"
  }

  private func shortcutValidationMessage(for binding: ShortcutBinding, isOpenShortcut: Bool) -> String? {
    if let failure = ShortcutManager.validationFailure(for: binding) { return failure.message }

    let otherBinding = isOpenShortcut ? settings.settingsShortcut : settings.openShortcut
    if binding == otherBinding { return ShortcutManager.RegistrationStatus.conflict(binding.displayText).message }

    return nil
  }
}
