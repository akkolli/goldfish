import AppKit

final class SettingsWindowController: NSObject, NSWindowDelegate {
  private enum Metrics {
    static let windowSize = NSSize(width: 820, height: 650)
    static let minimumWindowSize = NSSize(width: 740, height: 460)
    static let settingsLabelWidth: CGFloat = 128
  }
  private static let allowedContentTypesValidationMessage = "At least one content type must stay enabled."
  private static let allowedContentTypesUpdatedMessage = "Allowed content types updated."
  private let settings: SettingsModel
  private let store: HistoryStore
  private let cacheService: MediaCache
  private let cloudSyncService: CloudBackupServicing
  private let previewSound: (TransferSound) -> Void
  private let dataCoordinator: DataCoordinator
  private var dataOperationInProgress = false
  private var window: NSWindow?
  private var cachedCloudSyncStatus: CloudBackupStatus?
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
  private var allowedKindButtons: [(ClipKind, NSButton)] = []
  private let statusLabels = Dictionary(uniqueKeysWithValues: Feedback.allCases.map { ($0, NSTextField(labelWithString: "")) })
  private func statusLabel(_ source: Feedback) -> NSTextField { statusLabels[source]! }

  init(
    settings: SettingsModel, store: HistoryStore, cacheService: MediaCache, cloudSyncService: CloudBackupServicing = CloudBackup(),
    dataCoordinator: DataCoordinator = DataCoordinator(), previewSound: @escaping (TransferSound) -> Void = { _ in }
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
    window.title = "Goldfish Settings — " + AppConfig.buildDescription
    window.backgroundColor = ShelfStyle.windowBackground
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
        if change == .captureStatus { self.refreshStatus(.capture) } else { self.refreshFromSettings() }
      }
    }
    refreshFromSettings(refreshCloudSyncStatus: true)
    layoutSelectedTab()
  }

  func show() {
    guard let window else { return }
    refreshFromSettings(refreshCloudSyncStatus: true)
    layoutSelectedTab()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) { commitPendingEditorDrafts() }
  private func makeContentView() -> NSView {
    tabView.translatesAutoresizingMaskIntoConstraints = false
    tabView.tabViewType = .noTabsNoBorder
    let pages: [(title: String, subtitle: String, symbol: String, view: NSView)] = [
      ("General", "Make Goldfish feel at home on your Mac.", "slider.horizontal.3", generalSettingsView()),
      ("Shortcuts", "Keep your hands on the keyboard.", "command", shortcutSettingsView()),
      ("Capture", "Choose what your clipboard remembers.", "doc.on.clipboard", captureSettingsView()),
      ("Privacy", "Control how your history is stored and shared.", "lock.shield", privacySettingsView()),
      ("Performance", "Balance responsiveness and storage.", "speedometer", performanceSettingsView()),
      ("Data", "Back up, restore, and manage your history.", "externaldrive", dataSettingsView()),
    ]

    statusLabels.values.forEach(configureStatusLabel)
    let sidebar = NSVisualEffectView()
    sidebar.material = .sidebar
    sidebar.blendingMode = .behindWindow
    sidebar.state = .active
    let brand = NativeUI.label("Goldfish", font: .systemFont(ofSize: 19, weight: .semibold))
    let brandIcon = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil) ?? NSImage())
    brandIcon.contentTintColor = ShelfStyle.brandAccent
    brandIcon.widthAnchor.constraint(equalToConstant: 26).isActive = true
    let brandRow = NativeUI.stack([brandIcon, brand], spacing: 8)
    let navigation = NSStackView()
    navigation.orientation = .vertical
    navigation.alignment = .leading
    navigation.spacing = 4
    for (index, page) in pages.enumerated() {
      let title = page.title
      tabView.addTabViewItem(tab(title, subtitle: page.subtitle, page.view))
      let button = ShelfNavigationButton(title: title, target: self, action: #selector(settingsSectionChanged(_:)))
      button.tag = index
      button.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
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
    layoutSelectedTab()
  }

  private func layoutSelectedTab() {
    // Settings keeps a stable frame as sections change. Long pages scroll.
    window?.contentView?.layoutSubtreeIfNeeded()
    tabView.selectedTabViewItem?.view?.needsLayout = true
    tabView.selectedTabViewItem?.view?.layoutSubtreeIfNeeded()
  }

  private func tab(_ title: String, subtitle: String, _ view: NSView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: title)
    item.label = title
    let heading = NativeUI.label(title, font: .systemFont(ofSize: 25, weight: .bold))
    let introduction = caption(subtitle)
    introduction.font = .systemFont(ofSize: 13)
    let header = NativeUI.stack([heading, introduction], axis: .vertical, alignment: .leading, spacing: 7)
    let content = page([header, view])
    content.setCustomSpacing(24, after: header)
    item.view = SettingsPageScrollView(page: content)
    return item
  }

  private func generalSettingsView() -> NSView {
    let historyLabel = NSTextField(labelWithString: "")
    let stepper = NSStepper()
    stepper.minValue = Double(AppConfig.minHistoryLength)
    stepper.maxValue = Double(AppConfig.maxHistoryLength)
    stepper.increment = 25
    stepper.setAccessibilityLabel("History length")
    bind(
      stepper,
      read: { [settings] in
        stepper.integerValue = settings.maxHistoryItems
        historyLabel.stringValue = "\(settings.maxHistoryItems) clips"
      }, write: { [settings] in settings.maxHistoryItems = stepper.integerValue })
    let sort = NSPopUpButton()
    for (index, title) in ["Newest first", "Most used first"].enumerated() {
      sort.addItem(withTitle: title)
      sort.lastItem?.representedObject = index
    }
    sort.setAccessibilityLabel("Sort order")
    bind(
      sort, read: { [settings] in sort.selectItem(at: settings.sortByUsage ? 1 : 0) },
      write: { [settings] in settings.sortByUsage = sort.indexOfSelectedItem == 1 })
    keepFirstImageButton = toggle(
      "Reuse the original image for duplicate copies", \.keepFirstImage,
      help: "When duplicate items are ignored, keep the first stored image file. The clip still moves to the top of recent history.")
    goldMenuBarIconButton = toggle("Gold menu bar icon", \.goldMenuBarIcon)
    let side = popup("Shelf side", \.panelSide, ShelfSide.allCases, title: { $0.title })
    shelfSideRow = labeledRow("Shelf side", side)
    let launch = toggle(
      "Launch at login", \.launchAtLogin,
      after: { controller in
        if !controller.settings.launchAtLogin { controller.settings.setStatus(.launch, "") }
        controller.refreshFromSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak controller] in controller?.refreshFromSettings() }
      })
    let menu = toggle(
      "Show Goldfish in the menu bar", \.showMenuBarIcon,
      after: { controller in
        if !controller.settings.showMenuBarIcon && !controller.settings.showDockIcon { controller.settings.showDockIcon = true }
        controller.refreshFromSettings()
      })
    let dock = toggle(
      "Show Goldfish in the Dock", \.showDockIcon,
      after: { controller in
        if !controller.settings.showDockIcon && !controller.settings.showMenuBarIcon { controller.settings.showMenuBarIcon = true }
        controller.refreshFromSettings()
      })
    return page([
      section(
        "History",
        [
          labeledRow("Keep history", popup("Keep history", \.historyRetention, HistoryRetention.allCases, title: { $0.title })),
          labeledRow("Clip limit", row([historyLabel, stepper])), toggle("Ignore duplicate items", \.pruneDuplicates), keepFirstImageButton,
        ]),
      section(
        "Shelf",
        [
          labeledRow("Sort order", sort),
          labeledRow("Layout", popup("Shelf layout", \.shelfLayout, ShelfLayout.allCases, title: { $0.title })), shelfSideRow!,
          labeledRow("Shelf size", popup("Shelf size", \.shelfWidth, ShelfWidth.allCases, title: { $0.title })),
          toggle("Larger text in clips", \.largerShelfText),
        ]), soundSettingsSection(), section("Startup & visibility", [launch, menu, goldMenuBarIconButton, dock, statusLabel(.launch)]),
    ])
  }

  private func soundSettingsSection() -> NSView {
    let soundRows: [NSView] = [
      (
        "Copy sound", \SettingsModel.copySoundEnabled, TransferSound.copy,
        "Play a soft camera click when a copy is captured from any app, or copied from Goldfish."
      ),
      (
        "Paste sound", \SettingsModel.pasteSoundEnabled, TransferSound.paste,
        "Play a soft camera click when Goldfish sends a paste to another app."
      ),
    ].map { title, key, sound, help in
      let preview = ShelfNavigationButton()
      preview.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
      preview.imagePosition = .imageOnly
      let label = "Preview \(sound == .copy ? "copy" : "paste") sound"
      preview.setAccessibilityLabel(label)
      preview.toolTip = label
      preview.constrainSize(width: 28, height: 28)
      bind(preview, write: { [weak self] in self?.previewSound(sound) })
      soundPreviews.append(preview)
      let space = NSView()
      space.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let result = NativeUI.stack([toggle(title, key, help: help), space, preview], alignment: .centerY, spacing: 8)
      return result
    }
    let value = NativeUI.label(
      "", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor, alignment: .right)
    value.widthAnchor.constraint(equalToConstant: 40).isActive = true
    let slider = NSSlider()
    slider.minValue = 0
    slider.maxValue = 100
    slider.isContinuous = true
    slider.setAccessibilityLabel("Sound effects volume")
    slider.setAccessibilityHelp("Percentage of your Mac's current output volume.")
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    bind(
      slider,
      read: { [settings] in
        slider.doubleValue = settings.soundVolume * 100
        value.stringValue = "\(Int((settings.soundVolume * 100).rounded()))%"
      }, write: { [settings] in settings.soundVolume = slider.doubleValue / 100 })
    let title = NSTextField(labelWithString: "Volume")
    title.widthAnchor.constraint(equalToConstant: Metrics.settingsLabelWidth).isActive = true
    let volume = NativeUI.stack([title, slider, value], alignment: .centerY, spacing: 8)
    return section("Sound effects", soundRows + [volume, caption("Soft camera clicks for captured copies and Goldfish pastes.")])
  }

  private func captureSettingsView() -> NSView {
    let pause = toggle("Pause clipboard capture", \.pauseCapture, before: { $0.settings.pauseCaptureUntil = nil })
    let allowed = [
      ("Text", ClipKind.text), ("Code", .code), ("Links", .url), ("Images", .image), ("Colors", .color), ("Audio", .audio),
      ("Videos", .video), ("Rich text", .richText), ("PDFs", .pdf), ("Files", .file),
    ].map { kindCheckbox($0.0, $0.1) }
    return page([
      section(
        "Capture",
        [
          pause, toggle("Exclude likely secrets", \.excludeSensitive), toggle("Search in image labels", \.includeImageTextInSearch),
          statusLabel(.capture),
        ]), section("Allowed content types", [checkboxGrid(allowed)]),
      section(
        "Ignored source apps",
        [
          caption(
            "macOS does not identify which app wrote the clipboard. Goldfish applies this list to the app that is frontmost when it notices the change."
          ), IgnoredAppsEditor(settings: settings),
        ]),
    ])
  }

  private func privacySettingsView() -> NSView {
    page([
      section(
        "Local storage",
        [
          caption(
            "History stays in Application Support, encrypted with a local key. Capture pauses if the key is unavailable; storage is restricted to the current user."
          ), toggle("Clear history on quit", \.clearHistoryOnQuit),
        ]),
      section(
        "Screen privacy",
        [
          caption(
            "Requests that supported capture tools exclude the shelf. This is not a guarantee; close the shelf before sharing sensitive content."
          ), toggle("Hide panel from screen sharing and recordings", \.hideFromScreenCapture),
        ]),
      section(
        "Paste permission",
        [
          caption("Clipboard capture works without this permission. Grant Accessibility only for direct paste."),
          row([NSTextField(labelWithString: "Accessibility"), statusLabel(.accessibility)]),
          row([
            button("Open Accessibility Settings", { $0.requestAccessibilityAccess() }),
            button("Refresh Permission Status", { $0.refreshAccessibilityPermissionStatus() }),
          ]), statusLabel(.paste),
        ]),
    ])
  }

  private func performanceSettingsView() -> NSView {
    let slider = NSSlider()
    slider.minValue = Double(AppConfig.minCacheMaxBytes) / 1024 / 1024
    slider.maxValue = Double(AppConfig.maxCacheMaxBytes) / 1024 / 1024
    slider.setAccessibilityLabel("Preview storage limit in megabytes")
    let value = NSTextField(labelWithString: "")
    configureStatusLabel(value)
    bind(
      slider,
      read: { [settings] in
        slider.doubleValue = Double(settings.imageCacheMaxBytes) / 1024 / 1024
        value.stringValue = "\(Int(slider.doubleValue.rounded())) MB for previews. Original clips are stored separately."
      }, write: { [settings] in settings.imageCacheMaxBytes = Int64(slider.doubleValue.rounded()) * 1024 * 1024 })
    return page([
      section(
        "Capture responsiveness",
        [
          labeledRow(
            "Responsiveness", popup("Capture responsiveness", \.pollProfileRaw, AppConfig.PollProfile.allCases, title: { $0.title })),
          caption("Faster checks catch rapid copies sooner. Slower checks use less energy when you are copying frequently."),
        ]), section("Preview storage", [labeledRow("Limit (MB)", slider), value]),
    ])
  }

  private func dataSettingsView() -> NSView {
    let cloud = toggle(
      "Back up history to iCloud", \.iCloudSyncEnabled,
      after: { controller in
        controller.settings.setStatus(.backup, "")
        controller.refreshCloudSyncControls(refreshStatus: controller.settings.iCloudSyncEnabled && controller.cachedCloudSyncStatus == nil)
      })
    cloudActions = [
      button("Back Up Now", { $0.runArchiveOperation(.backup) }), button("Restore from iCloud", { $0.runArchiveOperation(.restore) }),
      button("Reveal Backup File", { $0.revealICloudSyncFile() }),
    ]
    archiveActions = [
      button("Export Archive...", { $0.chooseArchive(exporting: true) }),
      button("Import Archive...", { $0.chooseArchive(exporting: false) }),
    ]
    statusLabel(.data).isHidden = true
    return page([
      section(
        "iCloud Backup",
        [
          caption(
            "Keep a backup of your history in iCloud and restore it when needed. Changes don’t sync between Macs. Backups are not encrypted by Goldfish."
          ), cloud, row(cloudActions), statusLabel(.backup),
        ]),
      section(
        "Archive",
        [
          caption(
            "Export your history, Pinboards, and saved attachments. External files stay in their original locations. Archives are not encrypted."
          ), row(archiveActions),
        ]),
      section(
        "Data",
        [
          button("Open History Folder", { $0.openHistoryFolder() }),
          row([
            button("Clear Clipboard History", { $0.clearClipboardHistory() }),
            button("Clear Thumbnail Cache", { $0.clearThumbnailCache() }),
          ]), statusLabel(.data),
        ]),
    ])
  }

  private func toggle(
    _ title: String, _ key: ReferenceWritableKeyPath<SettingsModel, Bool>, help: String? = nil,
    before: @escaping (SettingsWindowController) -> Void = { _ in }, after: @escaping (SettingsWindowController) -> Void = { _ in }
  ) -> NSButton {
    let control = NSButton()
    control.setButtonType(.switch)
    control.title = title
    control.setAccessibilityLabel(title)
    control.toolTip = help
    control.setAccessibilityHelp(help)
    bind(
      control, read: { [settings] in control.state = settings[keyPath: key] ? .on : .off },
      write: { [weak self, settings] in
        if let self { before(self) }
        settings[keyPath: key] = control.state == .on
        if let self { after(self) }
      })
    return control
  }

  private func popup<Value: RawRepresentable>(
    _ label: String, _ key: ReferenceWritableKeyPath<SettingsModel, Value>, _ values: [Value], title: (Value) -> String
  ) -> NSPopUpButton where Value.RawValue == Int {
    let control = NSPopUpButton()
    control.setAccessibilityLabel(label)
    controlBindings.append(.popup(control, settings: settings, key: key, values: values, title: title))
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

  private func bind(_ control: NSControl, read: @escaping () -> Void = {}, write: @escaping () -> Void) {
    controlBindings.append(SettingsControlBinding(control: control, read: read, write: write))
  }
  private func shortcutSettingsView() -> NSView {
    let openRow = shortcutRow("Open Clipboard", binding: settings.openShortcut, baseTag: 100)
    let settingsRow = shortcutRow("Open Settings", binding: settings.settingsShortcut, baseTag: 200)
    return page([
      section(
        "Shortcuts",
        [openRow, settingsRow, caption("Click a shortcut, then press the new combination. Escape cancels."), statusLabel(.shortcut)]),
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
    let label = NativeUI.label(title, font: .systemFont(ofSize: 12))
    let key = NativeUI.label(keys, font: .monospacedSystemFont(ofSize: 12, weight: .medium), color: ShelfStyle.secondaryText)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NativeUI.stack([label, spacer, key], alignment: .centerY)
    return row
  }

  private func page(_ views: [NSView]) -> NSStackView {
    let stack = NativeUI.stack(views, axis: .vertical, alignment: .leading, spacing: 16, detachHidden: true)
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }

  private func section(_ title: String, _ views: [NSView]) -> NSView {
    let titleLabel = NativeUI.label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    let stack = NativeUI.stack([titleLabel] + views, axis: .vertical, alignment: .leading, spacing: 12, detachHidden: true)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let surface = SettingsSectionView()
    surface.addSubview(stack)
    stack.pinEdges(to: surface, inset: 18)
    for view in views where !(view is NSButton) { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return surface
  }

  private func row(_ views: [NSView]) -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NativeUI.stack(views + [spacer], axis: .horizontal, alignment: .centerY, spacing: 8, distribution: .fill)
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return stack
  }

  private func checkboxGrid(_ controls: [NSButton]) -> NSView {
    let rows = stride(from: 0, to: controls.count, by: 2).map { index in
      let pair = NativeUI.stack(Array(controls[index..<min(index + 2, controls.count)]), spacing: 12, distribution: .fillEqually)
      return pair
    }
    let grid = NativeUI.stack(rows, axis: .vertical, alignment: .leading, spacing: 8)
    for row in rows { row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
    return grid
  }

  private func labeledRow(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.widthAnchor.constraint(equalToConstant: Metrics.settingsLabelWidth).isActive = true
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if control is NSSlider {
      let result = NativeUI.stack([label, control], alignment: .centerY, spacing: 8)
      return result
    }
    return row([label, control])
  }

  private func caption(_ text: String) -> NSTextField {
    let label = NativeUI.label(text, wrap: true, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: ShelfStyle.secondaryText)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func configureStatusLabel(_ label: NSTextField) {
    label.textColor = ShelfStyle.secondaryText
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.usesSingleLineMode = false
    label.cell?.wraps = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  private func kindCheckbox(_ title: String, _ kind: ClipKind) -> NSButton {
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
      self.settings.setStatus(.shortcut, message ?? "")
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
    for source in [Feedback.launch, .shortcut, .capture, .accessibility, .paste] { refreshStatus(source) }
    dataCoordinator.setBackupEnabled(settings.iCloudSyncEnabled)
    refreshCloudSyncControls(refreshStatus: refreshCloudSyncStatus)
  }

  private func refreshStatus(_ source: Feedback, message: String? = nil, cloudStatus: CloudBackupStatus? = nil) {
    let presentation = source.presentation(
      message ?? settings.status(source), isTrusted: AccessibilityPermissionService.isTrusted, backupEnabled: settings.iCloudSyncEnabled,
      cloudStatus: cloudStatus)
    let label = statusLabel(source)
    label.stringValue = presentation.message
    label.textColor = presentation.textColor
    if source == .launch || source == .data { label.isHidden = presentation.message.isEmpty }
  }

  private func setDataStatus(_ message: String) {
    refreshStatus(.data, message: message)
    if selectedTabIndex == 5 { layoutSelectedTab() }
  }

  private func refreshCloudSyncControls(refreshStatus shouldRefresh: Bool) {
    let cloudStatus = cloudSyncStatus(refresh: shouldRefresh)
    refreshStatus(.backup, cloudStatus: cloudStatus)
    let enabled = settings.iCloudSyncEnabled && cloudStatus?.isAvailable == true && !dataOperationInProgress
    cloudActions.forEach { $0.isEnabled = enabled }
  }

  private func cloudSyncStatus(refresh: Bool) -> CloudBackupStatus? {
    guard settings.iCloudSyncEnabled else {
      cachedCloudSyncStatus = nil
      return nil
    }

    if refresh || cachedCloudSyncStatus == nil { cachedCloudSyncStatus = cloudSyncService.status() }
    return cachedCloudSyncStatus
  }

  private func commitPendingEditorDrafts() { shortcutRecorders.values.forEach { $0.cancelRecording() } }

  @objc private func allowedKindChanged(_ sender: NSButton) {
    guard let kind = ClipKind(rawValue: sender.tag) else { return }
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
      settings.setStatus(.capture, message)
      refreshStatus(.capture, message: message)
      return
    }
    settings.ignoredItemKindsRaw = ignored
    if settings.status(.capture) == Self.allowedContentTypesValidationMessage {
      settings.setStatus(.capture, Self.allowedContentTypesUpdatedMessage)
    }
  }

  private func requestAccessibilityAccess() {
    _ = AccessibilityPermissionService.requestPromptIfNeeded()
    if !AccessibilityPermissionService.isTrusted { AccessibilityPermissionService.openSystemSettings() }
    refreshAccessibilityPermissionStatus()
  }

  private func refreshAccessibilityPermissionStatus() {
    settings.setStatus(.accessibility, AccessibilityPermissionService.isTrusted ? "" : "Accessibility permission not granted.")
    refreshStatus(.accessibility)
  }

  private func openHistoryFolder() { NSWorkspace.shared.open(HistoryStore.storageDirectory()) }

  private enum ArchiveAction {
    case export(URL)
    case `import`(URL)
    case backup, restore
    var isCloud: Bool {
      switch self {
      case .backup, .restore: return true
      default: return false
      }
    }
    var includesSkipped: Bool {
      switch self {
      case .import, .restore: return true
      default: return false
      }
    }
    var presentation: (progress: String, verb: String, location: String, disabled: String) {
      switch self {
      case .export: return ("Exporting archive…", "Exported", "", "")
      case .import: return ("Importing archive…", "Imported", "", "")
      case .backup: return ("Backing up to iCloud…", "Backed up", " to iCloud", "Turn on iCloud Backup before backing up.")
      case .restore: return ("Restoring from iCloud…", "Restored", " from iCloud", "Turn on iCloud Backup before restoring.")
      }
    }
  }

  private func chooseArchive(exporting: Bool) {
    guard let window, window.attachedSheet == nil else { return }
    let panel = ArchivePicker.panel(exporting: exporting)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.runArchiveOperation(exporting ? .export(url) : .import(url))
    }
  }

  private func setArchiveStatus(_ message: String, for action: ArchiveAction) {
    if action.isCloud { settings.setStatus(.backup, message) } else { setDataStatus(message) }
  }

  private func runArchiveOperation(_ action: ArchiveAction) {
    let presentation = action.presentation
    guard !action.isCloud || settings.iCloudSyncEnabled else {
      setArchiveStatus(presentation.disabled, for: action)
      return
    }
    setArchiveStatus(presentation.progress, for: action)
    let work: (ArchiveWrite) throws -> (ArchiveSummary, CloudBackupStatus?) = { [store, cloudSyncService] write in
      let summary: ArchiveSummary
      switch action {
      case .export(let url): summary = try store.exportArchive(to: url)
      case .import(let url): summary = try store.importArchive(from: url)
      case .backup: summary = try cloudSyncService.push(store: store, write: write)
      case .restore: summary = try cloudSyncService.pull(store: store)
      }
      return (summary, action.isCloud ? cloudSyncService.status() : nil)
    }
    let operation = action.isCloud ? dataCoordinator.backupOperation(work) : { Result { try work { try $0() } } }
    performDataOperation(operation) { [weak self] result in
      guard let self, !action.isCloud || self.settings.iCloudSyncEnabled else { return }
      let message: String
      switch result {
      case .success(let (summary, status)):
        if action.isCloud { self.cachedCloudSyncStatus = status }
        message = summary.message(presentation.verb, location: presentation.location, includingSkipped: action.includesSkipped)
      case .failure(let error): message = (action.isCloud ? "iCloud Backup failed: " : "") + error.localizedDescription
      }
      self.setArchiveStatus(message, for: action)
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
      settings.setStatus(.backup, "Opened iCloud backup location.")
    } catch { settings.setStatus(.backup, "iCloud Backup failed: \(error.localizedDescription)") }
  }

  private func clearClipboardHistory() {
    confirmDestructiveAction(
      title: "Clear Clipboard History?",
      message:
        "This permanently removes all clips, including pinned clips and Pinboard contents, and saved attachments. Your current system clipboard stays unchanged.",
      buttonTitle: "Clear History"
    ) { [weak self] in
      guard let self, self.store.removeAll() else {
        self?.settings.setStatus(.capture, "Error: Could not clear history; existing clips are unchanged.")
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
    let alert = NSAlert(title: title, message: message, buttons: ["Cancel", buttonTitle])
    alert.buttons[0].keyEquivalent = "\u{1b}"
    alert.buttons[1].keyEquivalent = ""
    alert.window.defaultButtonCell = nil
    alert.window.initialFirstResponder = alert.buttons[0]
    alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { onConfirm() } }
  }

  private func shortcutValidationMessage(for binding: ShortcutBinding, isOpenShortcut: Bool) -> String? {
    if let failure = ShortcutManager.validationFailure(for: binding) { return failure.message }

    let otherBinding = isOpenShortcut ? settings.settingsShortcut : settings.openShortcut
    if binding == otherBinding { return ShortcutManager.RegistrationStatus.conflict(binding.displayText).message }

    return nil
  }
}
