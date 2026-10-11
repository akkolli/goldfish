import AppKit

/// Navigation controls for the edge shelf.
final class ClipboardShelfControls: NSObject {
  static let contentTypeRailWidth: CGFloat = 30
  // Center the controls across the complete attached notch, including its
  // former 8 pt connector, rather than the narrower floating-pill footprint.
  static let contentTypeNotchPadding: CGFloat = 8
  static let contentTypeNotchWidth = contentTypeRailWidth + 2 * contentTypeNotchPadding
  static let contentTypeRailAllowance = contentTypeNotchWidth
  private static let topControlSize: CGFloat = 34
  private static let topControlSpacing: CGFloat = 8

  let navigationView = NSStackView()
  let contentTypeRailView = NSStackView()
  private let model: ClipboardPanelViewModel
  private let destinationsRail = ClipboardShelfScrollView(edgeFadeWidth: 14)
  private let destinationsStack = NSStackView()
  private let horizontalTypesRail = ClipboardShelfScrollView(edgeFadeWidth: 14)
  private var contentTypeWidthConstraint: NSLayoutConstraint?
  private var usesHorizontalLayout = false
  private weak var horizontalSearchView: NSView?
  private weak var horizontalActionView: NSView?
  private var navigationWidthConstraints: [NSLayoutConstraint] = []
  private var destinationRailWidthConstraint: NSLayoutConstraint?
  private var destinationMinimumWidthConstraint: NSLayoutConstraint?
  private var destinationButtons: [NSButton] = []
  private(set) weak var createPinboardButton: NSButton?
  private var contentTypeButtons: [NSButton] = []
  private var navigationRow: NSStackView!
  private lazy var ordering = ShelfFilterButton(
    label: "", symbol: "clock", target: self, action: #selector(toggleOrdering), controlSize: Self.topControlSize)
  private let menuPresenter = ShelfMenuPresenter()
  var menuWindow: NSWindow? { menuPresenter.window }
  var onMenuDismiss: (() -> Void)? { didSet { menuPresenter.onDismiss = onMenuDismiss } }
  var onWillShowMenu: (() -> Void)?
  func dismissMenu(restoreFocus: Bool = false) { menuPresenter.close(restoreFocus: restoreFocus) }
  private let hiddenCaptureNotice = NSTextField(wrappingLabelWithString: "")
  private let showCaptured = NSButton()
  private lazy var horizontalShowCaptured = ShelfFilterButton(
    label: "", symbol: "arrow.left.to.line", target: self, action: #selector(showNewCopies), controlSize: Self.topControlSize)
  private var hiddenCaptureRow: NSStackView!
  private lazy var filters = ShelfFilterButton(
    label: "", symbol: "line.3.horizontal.decrease", target: self, action: #selector(showFilters), controlSize: Self.topControlSize)
  private lazy var reset = ShelfFilterButton(
    label: "", symbol: "arrow.counterclockwise", target: self, action: #selector(resetAll), controlSize: Self.topControlSize)
  private let onCreate: () -> Void
  private let onEdit: (String) -> Void
  private let onExport: (String) -> Void
  private let onDelete: (String) -> Void
  private let onRevealCapture: () -> Void
  private var names: [String] = []
  private var destinationAppearanceFingerprint = ""

  init(
    model: ClipboardPanelViewModel, onCreate: @escaping () -> Void, onEdit: @escaping (String) -> Void,
    onExport: @escaping (String) -> Void, onDelete: @escaping (String) -> Void, onRevealCapture: @escaping () -> Void = {}
  ) {
    self.model = model
    self.onCreate = onCreate
    self.onEdit = onEdit
    self.onExport = onExport
    self.onDelete = onDelete
    self.onRevealCapture = onRevealCapture
    super.init()
    if Self.contentTypes.contains(model.sortMode) {
      model.contentFilter = model.sortMode
      model.selectSortMode(.mostRecent)
    } else if model.sortMode == .mostUsed {
      model.sortByUsage = true
      model.selectSortMode(.mostRecent)
    }
    configure()
    refresh()
  }

  private func configure() {
    ordering.setAccessibilityLabel("Sort order")
    ordering.setAccessibilityRole(.button)
    ordering.showsChevron = false
    ordering.toolTip = "Sort: Newest first"
    ordering.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    ordering.setContentHuggingPriority(.required, for: .horizontal)
    ordering.setContentCompressionResistancePriority(.required, for: .horizontal)

    destinationsStack.orientation = .horizontal
    destinationsStack.spacing = Self.topControlSpacing
    destinationsStack.alignment = .centerY
    destinationsStack.edgeInsets = NSEdgeInsetsZero
    destinationsRail.documentView = destinationsStack
    destinationsRail.drawsBackground = false
    destinationsRail.hasHorizontalScroller = false
    destinationsRail.hasVerticalScroller = false
    destinationsRail.heightAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    destinationsRail.setAccessibilityLabel("Clipboard destinations")
    destinationsRail.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    destinationsRail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    destinationRailWidthConstraint = destinationsRail.widthAnchor.constraint(equalToConstant: Self.topControlSize)
    // Prefer the content width without raising the window's fitting minimum.
    // Extra pinboards scroll inside the available lane rather than widening it.
    destinationRailWidthConstraint?.priority = NSLayoutConstraint.Priority(rawValue: 49)
    destinationRailWidthConstraint?.isActive = true
    destinationsRail.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.topControlSize).isActive = true
    let preferredDestinationMinimum = destinationsRail.widthAnchor.constraint(
      greaterThanOrEqualToConstant: Self.topControlSize * 3 + Self.topControlSpacing * 2)
    preferredDestinationMinimum.priority = NSLayoutConstraint.Priority(rawValue: 500)
    destinationMinimumWidthConstraint = preferredDestinationMinimum

    contentTypeRailView.orientation = .vertical
    contentTypeRailView.spacing = 10
    contentTypeRailView.alignment = .centerX
    contentTypeRailView.distribution = .fill
    contentTypeRailView.edgeInsets = NSEdgeInsets(
      top: 8, left: Self.contentTypeNotchPadding, bottom: 8, right: Self.contentTypeNotchPadding)
    contentTypeRailView.setAccessibilityLabel("Content types")
    contentTypeRailView.setContentHuggingPriority(.required, for: .horizontal)
    contentTypeRailView.setContentCompressionResistancePriority(.required, for: .horizontal)
    contentTypeWidthConstraint = contentTypeRailView.widthAnchor.constraint(equalToConstant: Self.contentTypeNotchWidth)
    contentTypeWidthConstraint?.isActive = true
    rebuildContentTypeButtons()
    contentTypeRailView.setFrameSize(contentTypeRailView.fittingSize)
    horizontalTypesRail.drawsBackground = false
    horizontalTypesRail.hasHorizontalScroller = false
    horizontalTypesRail.hasVerticalScroller = false
    horizontalTypesRail.setAccessibilityLabel("Content types")
    horizontalTypesRail.heightAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    horizontalTypesRail.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.topControlSize).isActive = true
    let typeCount = CGFloat(Self.contentTypes.count + 1)
    let typeRailWidth = horizontalTypesRail.widthAnchor.constraint(equalToConstant: typeCount * 30 + (typeCount - 1) * 8 + 4)
    // A preference, not the window's minimum fitting width: on small displays
    // this lane scrolls while the search field and fixed actions remain usable.
    typeRailWidth.priority = .defaultLow
    typeRailWidth.isActive = true

    filters.setAccessibilityLabel("Filters and sorting")
    filters.toolTip = "Filters and sorting"
    filters.showsChevron = false
    filters.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    reset.setAccessibilityLabel("Reset search and filters")
    reset.setAccessibilityRole(.button)
    reset.toolTip = "Clear search and filters"
    reset.showsChevron = false
    reset.active = true
    reset.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    hiddenCaptureNotice.font = .systemFont(ofSize: 12, weight: .medium)
    hiddenCaptureNotice.textColor = .labelColor
    hiddenCaptureNotice.maximumNumberOfLines = 1
    hiddenCaptureNotice.lineBreakMode = .byTruncatingTail
    hiddenCaptureNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hiddenCaptureNotice.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button(showCaptured, title: "Show new", label: "Show newly copied clips", action: #selector(showNewCopies))
    showCaptured.toolTip = "Clear search and filters, then select the latest hidden copy."
    showCaptured.isBordered = false
    showCaptured.contentTintColor = .controlAccentColor
    horizontalShowCaptured.setAccessibilityLabel("Show newly copied clips")
    horizontalShowCaptured.setAccessibilityRole(.button)
    horizontalShowCaptured.showsChevron = false
    horizontalShowCaptured.active = true
    horizontalShowCaptured.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    horizontalShowCaptured.isHidden = true
    hiddenCaptureRow = row([hiddenCaptureNotice, showCaptured])
    hiddenCaptureRow.isHidden = true

    navigationView.detachesHiddenViews = true
    configureLayout()
  }

  private func configureLayout() {
    guard navigationRow == nil else { return }
    NSLayoutConstraint.deactivate(navigationWidthConstraints)
    navigationWidthConstraints.removeAll()
    // Reuse the same controls in either layout, including popover anchors.
    for view in [
      destinationsRail, horizontalTypesRail, ordering, filters, reset, hiddenCaptureRow!, horizontalShowCaptured, horizontalSearchView,
      horizontalActionView,
    ].compactMap({ $0 }) {
      if let stack = view.superview as? NSStackView { stack.removeArrangedSubview(view) }
      view.removeFromSuperview()
    }
    for view in navigationView.arrangedSubviews {
      navigationView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    if usesHorizontalLayout {
      let trailingSpacer = NSView()
      trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      trailingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      navigationRow = row(
        [
          horizontalSearchView, destinationsRail, spacer, horizontalTypesRail, trailingSpacer, horizontalActionView, horizontalShowCaptured,
          reset, filters, ordering,
        ].compactMap { $0 })
      trailingSpacer.widthAnchor.constraint(equalTo: spacer.widthAnchor).isActive = true
    } else {
      navigationRow = row([destinationsRail, spacer, reset, filters, ordering])
    }
    navigationRow.spacing = Self.topControlSpacing
    destinationMinimumWidthConstraint?.isActive = usesHorizontalLayout
    vertical(navigationView, views: usesHorizontalLayout ? [navigationRow] : [navigationRow, hiddenCaptureRow], spacing: 4)
  }

  func setHorizontalLayout(_ horizontal: Bool, searchView: NSView, actionView: NSView) {
    guard usesHorizontalLayout != horizontal else { return }
    horizontalSearchView = searchView
    horizontalActionView = actionView
    menuPresenter.close(restoreFocus: false)
    horizontalTypesRail.documentView = nil
    contentTypeRailView.removeFromSuperview()
    usesHorizontalLayout = horizontal
    contentTypeWidthConstraint?.isActive = !horizontal
    contentTypeRailView.orientation = horizontal ? .horizontal : .vertical
    contentTypeRailView.alignment = horizontal ? .centerY : .centerX
    contentTypeRailView.spacing = horizontal ? 8 : 10
    contentTypeRailView.edgeInsets =
      horizontal
      ? NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
      : NSEdgeInsets(top: 8, left: Self.contentTypeNotchPadding, bottom: 8, right: Self.contentTypeNotchPadding)
    contentTypeRailView.layoutSubtreeIfNeeded()
    contentTypeRailView.setFrameSize(contentTypeRailView.fittingSize)
    if horizontal { horizontalTypesRail.documentView = contentTypeRailView }
    navigationRow = nil
    configureLayout()
  }

  private func rebuildDestinationButtons() {
    for view in destinationsStack.arrangedSubviews {
      destinationsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    destinationButtons = []
    let entries =
      [("All clips", "clock.arrow.circlepath", -1), ("Pinned", "pin", -2)]
      + names.enumerated().map { ($0.element, model.collectionIcon(named: $0.element) ?? ClipboardCollectionIcon.defaultSymbol, $0.offset) }
    for (title, symbol, tag) in entries {
      let tab = ShelfNavigationButton(title: "", target: self, action: #selector(selectDestinationTab(_:)))
      tab.tag = tag
      tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      tab.imagePosition = .imageOnly
      let iconSize: CGFloat = tag >= 0 && symbol == "circle.fill" ? 8 : 14
      tab.image?.size = NSSize(width: iconSize, height: iconSize)
      if tag >= 0 {
        tab.iconTint = ClipboardCollectionVisuals.color(forCollectionNamed: title, overrideHex: model.collectionColorHex(named: title))
        tab.onDropItem = { [weak self] id in self?.model.assignItem(withID: id, to: title) }
        let menu = NSMenu()
        for (label, actionTag) in [("Edit Pinboard…", 0), ("Export Pinboard…", 1), ("Delete Pinboard…", 2)] {
          let item = NSMenuItem(title: label, action: #selector(destinationMenuAction(_:)), keyEquivalent: "")
          item.target = self
          item.tag = actionTag
          item.representedObject = title
          menu.addItem(item)
        }
        tab.menu = menu
      } else if tag == -2 {
        tab.iconTint = .systemOrange
      }
      tab.toolTip = title
      tab.setAccessibilityLabel(title)
      tab.heightAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
      tab.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
      destinationsStack.addArrangedSubview(tab)
      destinationButtons.append(tab)
    }
    let add = ShelfNavigationButton(title: "", target: self, action: #selector(createPinboard))
    add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    add.setAccessibilityLabel("New Pinboard")
    add.toolTip = "New Pinboard"
    createPinboardButton = add
    add.widthAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    add.heightAnchor.constraint(equalToConstant: Self.topControlSize).isActive = true
    destinationsStack.addArrangedSubview(add)
    destinationsStack.layoutSubtreeIfNeeded()
    updateDestinationRailFrame()
  }

  private func rebuildContentTypeButtons() {
    for view in contentTypeRailView.arrangedSubviews {
      contentTypeRailView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    contentTypeButtons = []
    let entries: [(String, String, NSColor, ClipboardSortMode?)] =
      [("All types", "square.grid.2x2", .secondaryLabelColor, nil)]
      + Self.contentTypes.map { type in
        let visual = Self.visuals(for: type)
        return (type.title, visual.0, visual.1, type)
      }
    for (title, symbol, tint, type) in entries {
      let button = ShelfNavigationButton(title: "", target: self, action: #selector(selectContentTypeTab(_:)))
      button.tag = type?.rawValue ?? -100
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageOnly
      button.image?.size = NSSize(width: 14, height: 14)
      button.iconTint = tint
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.heightAnchor.constraint(equalToConstant: 30).isActive = true
      button.widthAnchor.constraint(equalToConstant: 30).isActive = true
      contentTypeRailView.addArrangedSubview(button)
      contentTypeButtons.append(button)
    }
  }

  @objc private func destinationMenuAction(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    switch sender.tag {
    case 0: onEdit(name)
    case 1: onExport(name)
    default: onDelete(name)
    }
  }
  @objc private func createPinboard() { onCreate() }
  @objc private func selectDestinationTab(_ sender: NSButton) {
    selectDestination(sender.tag)
    // A scoped view reveals Reset, narrowing this lane. Finish that layout
    // before scrolling the chosen pinboard into view.
    navigationView.layoutSubtreeIfNeeded()
    sender.scrollToVisible(sender.bounds)
  }
  @objc private func selectContentTypeTab(_ sender: NSButton) {
    selectType(sender.tag == -100 ? nil : ClipboardSortMode(rawValue: sender.tag))
    navigationView.layoutSubtreeIfNeeded()
    sender.scrollToVisible(sender.bounds)
  }

  static let contentTypes: [ClipboardSortMode] = [.text, .links, .images, .code, .files, .colors, .audio, .videos]

  func refresh() {
    configureLayout()
    rebuildDestinationsIfNeeded()
    let activeTag = activeDestinationTag
    for tab in destinationButtons {
      tab.state = tab.tag == activeTag ? .on : .off
      tab.needsDisplay = true
    }
    updateDestinationRailFrame()
    let type = model.contentFilter ?? (Self.contentTypes.contains(model.sortMode) ? model.sortMode : nil)
    let typeCounts = model.contentTypeCountsInCurrentScope()
    for button in contentTypeButtons {
      let buttonType = button.tag == -100 ? nil : ClipboardSortMode(rawValue: button.tag)
      button.state = buttonType == type ? .on : .off
      let count = typeCounts[buttonType ?? .mostRecent] ?? 0
      button.setAccessibilityHelp("\(count) \(count == 1 ? "clip" : "clips")")
      button.needsDisplay = true
    }
    ordering.symbol = model.sortByUsage ? "arrow.up.right" : "clock"
    ordering.active = model.sortByUsage
    let orderTitle = model.sortByUsage ? "Most used first" : "Newest first"
    ordering.toolTip = "Sort: \(orderTitle)"
    ordering.setAccessibilityValue(orderTitle)
    let count = model.visibleItems.count
    filters.active = !model.searchText.clipboardTrimmed.isEmpty || model.sortByUsage
    reset.isHidden = !model.hasActiveFilters
    reset.isEnabled = model.hasActiveFilters
    reset.setAccessibilityHelp("Showing \(count) of \(model.totalItemCount) clips")
    let hiddenCount = model.hiddenCaptureCount
    hiddenCaptureRow.isHidden = hiddenCount == 0
    horizontalShowCaptured.isHidden = hiddenCount == 0
    hiddenCaptureNotice.stringValue =
      hiddenCount == 1 ? "New copy saved outside this view." : "\(hiddenCount) new copies saved outside this view."
    hiddenCaptureNotice.setAccessibilityLabel(hiddenCaptureNotice.stringValue)
    showCaptured.toolTip = "\(hiddenCaptureNotice.stringValue) Show newly copied clips."
    horizontalShowCaptured.toolTip = showCaptured.toolTip
    horizontalShowCaptured.setAccessibilityHelp(hiddenCaptureNotice.stringValue)
  }

  func announceOutcome() {
    refresh()
    guard !model.statusMessage.isEmpty, let window = navigationView.window else { return }
    let message: String
    switch model.statusMessage {
    case "Copied": message = "Copied. Press Command-V in your destination app."
    case "Copied Plain Text": message = "Copied as plain text. Press Command-V to paste."
    default: message = model.statusMessage
    }
    NSAccessibility.post(
      element: window, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  func focusDestination() {
    guard let control = destinationButtons.first(where: { $0.state == .on }) ?? destinationButtons.first else { return }
    control.window?.makeFirstResponder(control)
  }

  private func rebuildDestinationsIfNeeded() {
    let nextNames = model.collectionNames
    let appearance = nextNames.map { name in
      "\(name)|\(model.collectionColorHex(named: name) ?? "")|\(model.collectionIcon(named: name) ?? "")"
    }.joined(separator: "\u{1f}")
    guard names != nextNames || appearance != destinationAppearanceFingerprint || destinationButtons.isEmpty else { return }
    names = nextNames
    destinationAppearanceFingerprint = appearance
    rebuildDestinationButtons()
  }

  private func updateDestinationRailFrame() {
    let fitting = destinationsStack.fittingSize
    destinationsStack.setFrameSize(NSSize(width: fitting.width, height: Self.topControlSize))
    destinationRailWidthConstraint?.constant = max(Self.topControlSize, fitting.width)
  }

  private var activeDestinationTag: Int {
    if let name = model.selectedCollectionName { return names.firstIndex(of: name) ?? -1 }
    return model.sortMode == .pinned ? -2 : -1
  }

  private func selectDestination(_ tag: Int) {
    switch tag {
    case -1: model.selectSortMode(.mostRecent)
    case -2: model.selectSortMode(.pinned)
    default: if names.indices.contains(tag) { model.selectCollection(named: names[tag]) }
    }
    refresh()
  }

  private func selectType(_ type: ClipboardSortMode?) {
    if Self.contentTypes.contains(model.sortMode), model.selectedCollectionName == nil { model.selectSortMode(.mostRecent) }
    model.contentFilter = type
    refresh()
  }

  private func selectOrder(byUsage: Bool) {
    if model.sortMode == .mostUsed, model.selectedCollectionName == nil { model.selectSortMode(.mostRecent) }
    model.sortByUsage = byUsage
    refresh()
  }

  @objc private func toggleOrdering() { selectOrder(byUsage: !model.sortByUsage) }

  @objc private func resetAll() {
    model.searchText = ""
    model.resetFilters()
    refresh()
  }
  @objc private func showNewCopies() {
    model.showLatestHiddenCapture()
    refresh()
    onRevealCapture()
  }

  static func visuals(for type: ClipboardSortMode) -> (String, NSColor) {
    switch type {
    case .text: return ("text.alignleft", .systemOrange)
    case .links: return ("link", .systemBlue)
    case .images: return ("photo", .systemPink)
    case .code: return ("chevron.left.forwardslash.chevron.right", .systemPurple)
    case .files: return ("doc", .systemTeal)
    case .colors: return ("paintpalette", .systemIndigo)
    case .audio: return ("waveform", .systemOrange)
    case .videos: return ("play.rectangle", .systemRed)
    default: return ("square.grid.2x2", .secondaryLabelColor)
    }
  }

  @objc private func showFilters() {
    onWillShowMenu?()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar.clipboardSearchCalendar
    formatter.timeZone = Calendar.clipboardSearchCalendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let today = "on:\(formatter.string(from: Date()))"
    var dates = [
      ShelfMenuChoice(
        title: "Copied today", symbol: "sun.max", tint: .systemOrange, selected: model.searchText.contains(today),
        action: { [weak self] in self?.applyFilterToken(today, prefixes: ["on", "after", "before"]) })
    ]
    if let start = Calendar.clipboardSearchCalendar.date(byAdding: .day, value: -6, to: Date()) {
      let week = "after:\(formatter.string(from: start))"
      dates.append(
        ShelfMenuChoice(
          title: "Last 7 days", symbol: "calendar", tint: .systemOrange, selected: model.searchText.contains(week),
          action: { [weak self] in self?.applyFilterToken(week, prefixes: ["on", "after", "before"]) }))
    }
    dates.append(
      ShelfMenuChoice(
        title: "Source app", symbol: "app.dashed", tint: .systemBlue, enabled: !model.sourceAppNames.isEmpty, disclosure: true,
        action: { [weak self] in self?.showSources() }))
    menuPresenter.show(
      title: "Refine clips",
      sections: [
        ShelfMenuSection(title: "Filter by", choices: dates),
        ShelfMenuSection(choices: [
          ShelfMenuChoice(
            title: "Clear search and filters", symbol: "arrow.counterclockwise", enabled: model.hasActiveFilters,
            action: { [weak self] in self?.resetAll() })
        ]),
      ], from: filters)
  }

  private func showSources() {
    let choices = model.sourceAppNames.map { name -> ShelfMenuChoice in
      let token = "app:\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
      return ShelfMenuChoice(
        title: name, symbol: "app", tint: .systemBlue, selected: model.searchText.contains(token),
        action: { [weak self] in self?.applyFilterToken(token, prefixes: ["app"]) })
    }
    menuPresenter.show(
      title: "Source app",
      sections: [
        ShelfMenuSection(choices: [
          ShelfMenuChoice(title: "Back to Filters", symbol: "chevron.left", action: { [weak self] in self?.showFilters() }),
          ShelfMenuChoice(
            title: "All apps", symbol: "square.grid.2x2", action: { [weak self] in self?.applyFilterToken("", prefixes: ["app"]) }),
        ]), ShelfMenuSection(choices: choices),
      ], from: filters)
  }

  private func applyFilterToken(_ token: String, prefixes: [String]) {
    // Replacing a date/source choice preserves free text and unrelated filters.
    let old = model.searchText
    let pattern = #"(?i)(?<!\S)(?:"# + prefixes.joined(separator: "|") + #"):(?:"(?:\\.|[^"])*"|[^\s]+)"#
    let expression = try? NSRegularExpression(pattern: pattern)
    let remainder =
      expression?.stringByReplacingMatches(in: old, range: NSRange(old.startIndex..., in: old), withTemplate: "").clipboardTrimmed ?? old
    model.searchText = [remainder, old.contains(token) && !token.isEmpty ? "" : token].filter { !$0.isEmpty }.joined(separator: " ")
    refresh()
  }

  private func button(_ button: NSButton, title: String, label: String, action: Selector) {
    button.title = title
    button.bezelStyle = .rounded
    button.font = .systemFont(ofSize: 12)
    button.target = self
    button.action = action
    button.setAccessibilityLabel(label)
    button.setContentHuggingPriority(.required, for: .horizontal)
  }
  private func row(_ views: [NSView]) -> NSStackView {
    let stack = NativeUI.stack(views, axis: .horizontal, alignment: .centerY, spacing: 8, detachHidden: true)
    return stack
  }
  private func vertical(_ stack: NSStackView, views: [NSView], spacing: CGFloat) {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    stack.setContentCompressionResistancePriority(.required, for: .vertical)
    for view in views {
      stack.addArrangedSubview(view)
      let width = view.widthAnchor.constraint(equalTo: stack.widthAnchor)
      navigationWidthConstraints.append(width)
      width.isActive = true
    }
  }
}

/// A quiet, native button with a persistent selected state and a generous hit target.
final class ShelfNavigationButton: NSButton {
  var iconTint: NSColor?
  var onDropItem: ((UUID) -> Void)? { didSet { registerForDraggedTypes([ClipboardItemDragPasteboard.itemIDType]) } }
  private var dropTargeted = false
  private var hoverArea: NSTrackingArea?
  private var hovered = false
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    bezelStyle = .regularSquare
    font = .systemFont(ofSize: 12, weight: .medium)
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
  }
  required init?(coder: NSCoder) { nil }
  // Native bezel alignment insets otherwise make a 30 pt layout box paint
  // 36 pt tall. These controls draw their entire bounds, including hover.
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  override var intrinsicContentSize: NSSize {
    let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)])
    let iconWidth: CGFloat = image == nil ? 0 : (title.isEmpty ? 14 : 22)
    return NSSize(width: min(180, text.width + iconWidth + 24), height: 30)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
    ClipboardCardDragContext.itemID
      ?? sender.draggingPasteboard.string(forType: ClipboardItemDragPasteboard.itemIDType).flatMap(UUID.init(uuidString:))
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropTargeted = onDropItem != nil && draggedID(sender) != nil
    needsDisplay = true
    return dropTargeted ? .copy : []
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    dropTargeted = false
    needsDisplay = true
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { onDropItem != nil && draggedID(sender) != nil }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer {
      dropTargeted = false
      needsDisplay = true
    }
    guard let id = draggedID(sender), let onDropItem else { return false }
    onDropItem(id)
    return true
  }
  override func draw(_ dirtyRect: NSRect) {
    let selected = state == .on
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
    NSColor.labelColor.withAlphaComponent(selected ? 0.085 : (isHighlighted ? 0.09 : (hovered ? 0.045 : 0))).setFill()
    path.fill()
    if dropTargeted || selected && ClipboardShelfStyle.increasedContrast || window?.firstResponder === self {
      (dropTargeted || window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.labelColor).setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }
    let ink = selected ? NSColor.labelColor : ClipboardShelfStyle.secondaryText
    let iconSize: CGFloat = image?.size.width == 8 ? 8 : 14
    if let image {
      let rect = NSRect(
        x: title.isEmpty ? (bounds.width - iconSize) / 2 : 12, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
      let tinted = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { bounds in
        image.draw(in: bounds)
        (self.iconTint ?? ink).setFill()
        bounds.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(in: rect)
    }
    if !title.isEmpty {
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: ink, .paragraphStyle: style,
      ]
      let height = (title as NSString).size(withAttributes: attributes).height
      let x: CGFloat = image == nil ? 12 : 34
      (title as NSString).draw(
        in: NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 10), height: height), withAttributes: attributes)
    }
  }
}
