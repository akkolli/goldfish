import AppKit

final class ClipboardPanelView: NSView {
  private enum Metrics {
    static let actionButtonSize = ClipboardShelfStyle.controlSize
    static let cardInset: CGFloat = 4
    static let minimumEmptyStateHeight: CGFloat = 88
    static let panelTopInset = ClipboardShelfStyle.inset
    static let panelSideInset = ClipboardShelfStyle.inset
    static let minimumBottomInset: CGFloat = 20
    static let panelCornerRadius: CGFloat = 28
    static let collectionRailHeight: CGFloat = 36
    // The vertical scrollbar lives in the shelf's outer right margin. The
    // card column stays centered between the two 20 pt visual margins.
    static let verticalScrollerLane: CGFloat = 16
    static let minimumVerticalCardWidth: CGFloat = 180
  }

  private let viewModel: ClipboardPanelViewModel
  private let onClose: () -> Void
  private let onPreview: () -> Void

  private let searchControl = ClipboardSearchControl()
  private weak var utilityToolbarGroup: NSView?
  private var utilityToolbarTrailingConstraint: NSLayoutConstraint?
  private var idealSearchWidthConstraint: NSLayoutConstraint?
  private var toolbarButtons: [ClipboardToolbarIconButton] = []
  private let cardsDocument = ClipboardCardsDocumentView()
  private let scrollView = ClipboardShelfScrollView()
  private var mainStack: NSStackView?
  private var bottomSafeInset = Metrics.minimumBottomInset
  private var scrollViewTrailingConstraint: NSLayoutConstraint?
  private var scrollViewLeadingConstraint: NSLayoutConstraint?
  private var headerLeadingConstraint: NSLayoutConstraint?
  private var shelfChromeHeightConstraint: NSLayoutConstraint?
  private weak var shelfChromeView: NSView?
  private weak var headerStack: NSStackView?
  private weak var contentStack: NSView?
  private var cardViews: [ClipboardItemCardView] = []
  private var hoveredCardIndex: Int?
  private var updatesSelectionFromPointer = false
  private var pointerTrackingArea: NSTrackingArea?
  private let clearHistoryMenuPresenter = ShelfMenuPresenter()
  var presentedMenuWindow: NSWindow? { pinboardEditorController?.window ?? clearHistoryMenuPresenter.window ?? shelfControls.menuWindow }
  func dismissMenus() {
    pinboardEditorController?.dismiss()
    clearHistoryMenuPresenter.close(restoreFocus: false)
    shelfControls.dismissMenu()
  }
  var onMenuDismiss: (() -> Void)? {
    didSet {
      shelfControls.onMenuDismiss = onMenuDismiss
      clearHistoryMenuPresenter.onDismiss = onMenuDismiss
    }
  }
  private var reusableCards: [UUID: ClipboardItemCardView] = [:]
  private var verticalGrid: ClipboardVerticalGridLayout?
  private var keyboardColumnX: CGFloat?
  private var cardSlots: [Int: ClipboardItemCardSlotView] = [:]
  private var cardItemCount = 0
  private var lastScrollViewportSize: NSSize = .zero
  private var appliedShelfLayout: ClipboardShelfLayout?
  private var selectionScrollSuppressionCount = 0
  private var defersVisualReloads = false
  private var revealDirection: CGFloat = 1
  private var pendingItemReload = false
  private var cardReloadGeneration = 0
  private var textEditorController: ClipTextEditorController?
  private var pinboardEditorController: PinboardEditorController?
  var hasActiveTextEditor: Bool { textEditorController?.isPresented == true }
  var presentedTextEditorWindow: NSWindow? { hasActiveTextEditor ? textEditorController?.window : nil }
  func suspendTextEditor() { textEditorController?.suspend() }
  @discardableResult func resumeTextEditorIfNeeded() -> Bool {
    guard let textEditorController, !textEditorController.isPresented, let window else { return false }
    textEditorController.show(relativeTo: window, anchoredTo: newClipButton)
    return true
  }
  private weak var newClipButton: NSButton?
  private let shelfSurface = ClipboardShelfSurfaceView(cornerRadius: 20)
  private let contentTypeNotch = NSView()
  private var contentTypeNotchHeightConstraint: NSLayoutConstraint?
  private let contentTypeScrollView = NSScrollView()
  private var displayOptionsObserver: NSObjectProtocol?
  private lazy var shelfControls = ClipboardShelfControls(
    model: viewModel, onCreate: { [weak self] in self?.createCollectionFromToolbar() },
    onEdit: { [weak self] in self?.editCollection(named: $0) }, onExport: { [weak self] in self?.exportCollection(named: $0) },
    onDelete: { [weak self] in self?.deleteCollection(named: $0) },
    onRevealCapture: { [weak self] in self?.focusSelectedCardForKeyboardNavigation() })

  private struct FocusedCardReloadTarget {
    let itemID: UUID
    let fallbackIndex: Int
  }

  private struct CardRenderContext {
    let items: [ClipboardItem]
    let revision: UInt
    let collectionNames: [String]
    let layout: ClipboardItemCardLayout
    let canShowInClipboard: Bool
    let reloadGeneration: Int
    let scope: String
  }

  private let initialCardRenderBudget = 12
  private let cardRenderPrefetchBuffer = 3
  private let cardRenderRetentionBuffer = 8
  private var currentCardRenderContext: CardRenderContext?

  init(viewModel: ClipboardPanelViewModel, onClose: @escaping () -> Void, onPreview: @escaping () -> Void = {}) {
    self.viewModel = viewModel
    self.onClose = onClose
    self.onPreview = onPreview
    super.init(frame: .zero)
    configureView()
    bindViewModel()
    reloadItems()
    updateSelection()
    shelfControls.refresh()
    displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.viewDidChangeEffectiveAppearance()
      self?.reloadItems()
    }
  }

  deinit { if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) } }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func configureView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    shelfControls.onWillShowMenu = { [weak self] in
      self?.suspendTextEditor()
      self?.pinboardEditorController?.dismiss()
      self?.clearHistoryMenuPresenter.close(restoreFocus: false)
    }
    shelfSurface.translatesAutoresizingMaskIntoConstraints = false
    shelfSurface.setAccessibilityIdentifier("shelf-reading-surface")
    addSubview(shelfSurface)
    NSLayoutConstraint.activate([
      shelfSurface.leadingAnchor.constraint(equalTo: leadingAnchor), shelfSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
      shelfSurface.topAnchor.constraint(equalTo: topAnchor), shelfSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    contentTypeNotch.translatesAutoresizingMaskIntoConstraints = false
    contentTypeNotch.setAccessibilityIdentifier("shelf-type-notch")
    addSubview(contentTypeNotch)
    contentTypeScrollView.drawsBackground = false
    contentTypeScrollView.borderType = .noBorder
    contentTypeScrollView.hasHorizontalScroller = false
    contentTypeScrollView.hasVerticalScroller = false
    contentTypeScrollView.wantsLayer = true
    contentTypeScrollView.layer?.cornerRadius = 12
    contentTypeScrollView.layer?.masksToBounds = true
    contentTypeScrollView.documentView = shelfControls.contentTypeRailView
    contentTypeScrollView.translatesAutoresizingMaskIntoConstraints = false
    contentTypeNotch.addSubview(contentTypeScrollView)
    // Normally the notch hugs all nine icons. On a short display it can
    // scroll independently instead of stretching the shelf or clipping icons.
    let notchHeight = contentTypeNotch.heightAnchor.constraint(equalToConstant: shelfControls.contentTypeRailView.fittingSize.height)
    contentTypeNotchHeightConstraint = notchHeight
    notchHeight.priority = .defaultHigh
    let contourClearance = Metrics.panelCornerRadius + ClipboardShelfSurfaceView.notchShoulderRadius
    NSLayoutConstraint.activate([
      contentTypeNotch.leadingAnchor.constraint(equalTo: leadingAnchor), contentTypeNotch.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentTypeNotch.widthAnchor.constraint(equalToConstant: ClipboardShelfControls.contentTypeNotchWidth),
      contentTypeNotch.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -2 * contourClearance), notchHeight,
      contentTypeScrollView.leadingAnchor.constraint(equalTo: contentTypeNotch.leadingAnchor),
      contentTypeScrollView.trailingAnchor.constraint(equalTo: contentTypeNotch.trailingAnchor),
      contentTypeScrollView.topAnchor.constraint(equalTo: contentTypeNotch.topAnchor),
      contentTypeScrollView.bottomAnchor.constraint(equalTo: contentTypeNotch.bottomAnchor),
    ])

    searchControl.onTextChanged = { [weak self] in self?.viewModel.searchText = $0 }
    searchControl.onSubmit = { [weak self] in self?.viewModel.pasteSelected() }
    searchControl.onCancel = { [weak self] in self?.onClose() }
    searchControl.onNavigateResults = { [weak self] in self?.focusSelectedCardForKeyboardNavigation() }

    let clearHistoryButton = iconButton(
      "trash", toolTip: "Clear History", accessibilityHelp: "Choose a time range to remove unpinned clips.",
      action: #selector(showClearHistoryChoices(_:)))

    let newClipButton = iconButton(
      "square.and.pencil", toolTip: "New Text Clip", accessibilityHelp: "Create a reusable text clip. Command-N.",
      action: #selector(createTextClip))
    self.newClipButton = newClipButton
    let actionStrip = row([newClipButton, clearHistoryButton])
    actionStrip.spacing = 6
    actionStrip.widthAnchor.constraint(equalToConstant: Metrics.actionButtonSize * 2 + actionStrip.spacing).isActive = true
    actionStrip.setContentCompressionResistancePriority(.required, for: .horizontal)
    let actionGroup = actionStrip
    utilityToolbarGroup = actionGroup

    actionGroup.setContentHuggingPriority(.required, for: .horizontal)
    actionGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

    let shelfChrome = row([searchControl, actionGroup])
    shelfChrome.spacing = 12
    shelfChrome.detachesHiddenViews = true
    shelfChrome.translatesAutoresizingMaskIntoConstraints = false
    shelfChrome.setContentHuggingPriority(.defaultLow, for: .horizontal)
    shelfChrome.setContentCompressionResistancePriority(.required, for: .vertical)
    searchControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let idealSearchWidth = searchControl.widthAnchor.constraint(equalToConstant: 300)
    idealSearchWidthConstraint = idealSearchWidth
    idealSearchWidth.priority = .defaultLow
    idealSearchWidth.isActive = true
    let preferredMaximumSearchWidth = searchControl.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
    preferredMaximumSearchWidth.priority = .defaultHigh
    preferredMaximumSearchWidth.isActive = true
    searchControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    utilityToolbarTrailingConstraint = actionGroup.trailingAnchor.constraint(equalTo: shelfChrome.trailingAnchor)
    utilityToolbarTrailingConstraint?.isActive = true
    shelfChromeHeightConstraint = shelfChrome.heightAnchor.constraint(equalToConstant: Metrics.collectionRailHeight)
    shelfChromeHeightConstraint?.isActive = true
    shelfChromeView = shelfChrome

    configureCardInsets()
    cardsDocument.translatesAutoresizingMaskIntoConstraints = true
    scrollView.documentView = cardsDocument
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.verticalScroller = ShelfScroller()
    scrollView.horizontalScroller = ShelfScroller()
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.setContentHuggingPriority(.required, for: .vertical)
    scrollView.setContentCompressionResistancePriority(.required, for: .vertical)
    scrollView.onVisibleBoundsChanged = { [weak self] in
      guard let self else { return }
      self.alignVerticalScrollerThumb()
      if self.scrollView.contentView.bounds.size != self.lastScrollViewportSize {
        // AppKit can install a legacy scrollbar after the parent's layout pass.
        // Re-measure against the final clip width, or right card corners get cut.
        self.needsLayout = true
      }
      self.renderCardsNearVisibleViewport()
      if let window = self.window, window.isVisible {
        self.updateHoverForPointer(atWindowLocation: window.mouseLocationOutsideOfEventStream)
      }
    }
    scrollView.onScrollActivity = { [weak self] in
      self?.clearCardHoverStates()
      self?.shelfControls.dismissMenu(restoreFocus: true)
    }
    scrollView.onTiled = { [weak self] in self?.alignVerticalScrollerThumb() }

    let headerStack = NativeUI.stack(
      [shelfChrome, shelfControls.navigationView], axis: .vertical, alignment: .leading, spacing: 8, distribution: .fill, detachHidden: true
    )
    headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
    self.headerStack = headerStack
    let headerContainer = NSView()
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerContainer.addSubview(headerStack)

    let contentStack = NSView()
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentStack.setContentHuggingPriority(.defaultLow, for: .vertical)
    contentStack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    contentStack.addSubview(scrollView)
    self.contentStack = contentStack

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollViewTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor)
    scrollViewLeadingConstraint = scrollView.leadingAnchor.constraint(
      equalTo: contentStack.leadingAnchor, constant: ClipboardShelfControls.contentTypeRailAllowance)
    headerLeadingConstraint = headerStack.leadingAnchor.constraint(
      equalTo: headerContainer.leadingAnchor, constant: ClipboardShelfControls.contentTypeRailAllowance + Metrics.cardInset)
    let mainStack = NativeUI.stack(
      [headerContainer, contentStack], axis: .vertical, alignment: .leading, spacing: 12, distribution: .fill, detachHidden: true,
      insets: contentInsets())
    mainStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(mainStack)
    addSubview(contentTypeNotch, positioned: .above, relativeTo: mainStack)
    self.mainStack = mainStack

    NSLayoutConstraint.activate([
      mainStack.leadingAnchor.constraint(equalTo: leadingAnchor), mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      mainStack.topAnchor.constraint(equalTo: topAnchor), mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      headerContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -(Metrics.panelSideInset * 2)),
      headerLeadingConstraint!,
      headerStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -Metrics.cardInset),
      headerStack.topAnchor.constraint(equalTo: headerContainer.topAnchor),
      headerStack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
      shelfChrome.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
      shelfControls.navigationView.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
      contentStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor, constant: -(Metrics.panelSideInset * 2)),
      scrollViewLeadingConstraint!, scrollViewTrailingConstraint!, scrollView.topAnchor.constraint(equalTo: contentStack.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),
    ])

    applyPanelLayout(reloadItems: false)
    shelfControls.refresh()
  }

  private func bindViewModel() {
    viewModel.onChange = { [weak self] change in
      guard let self else { return }
      switch change {
      case .status: self.shelfControls.announceOutcome()
      case .capture:
        self.shelfControls.refresh()
        if self.viewModel.visibleItems.isEmpty { self.reloadItems() }
      case .items: self.handleVisibleItemsChanged()
      case .search: self.syncSearchFieldFromViewModel()
      case .selection:
        guard self.renderedItemsMatchModel else { return }
        self.updateSelection(scrollSelection: !self.updatesSelectionFromPointer)
      case .sort: self.shelfControls.refresh()
      case .collections: self.handleCollectionsChanged()
      }
    }
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let stack = NativeUI.stack(views, axis: .horizontal, alignment: .centerY, spacing: 8)
    return stack
  }

  func clearHistoryChoices() -> [ShelfMenuSection] {
    let ranges: [(String, String, TimeInterval?)] = [
      ("1 day", "clock", 86_400), ("1 week", "calendar", 7 * 86_400), ("All time", "trash", nil),
    ]
    return [
      ShelfMenuSection(
        choices: ranges.map { title, symbol, seconds in
          ShelfMenuChoice(
            title: title, symbol: symbol,
            action: { [weak self] in
              guard let self else { return }
              self.viewModel.clearHistory(since: seconds.map { Date().addingTimeInterval(-$0) } ?? .distantPast)
            })
        })
    ]
  }

  private func collectionColor(forCollectionNamed name: String) -> NSColor {
    ClipboardCollectionVisuals.color(forCollectionNamed: name, overrideHex: viewModel.collectionColorHex(named: name))
  }

  private func configureCardInsets() {
    cardsDocument.contentInsets = NSEdgeInsets(
      top: Metrics.cardInset, left: Metrics.cardInset, bottom: Metrics.cardInset, right: verticalCardTrailingInset)
  }

  private var verticalCardTrailingInset: CGFloat { Metrics.cardInset + verticalScrollerInsetAdjustment }

  private var verticalScrollerInsetAdjustment: CGFloat {
    guard !viewModel.usesCardShelf else { return 0 }
    // A legacy scroller can disappear when a filter leaves only a few clips.
    // Reserve whatever part of the gutter AppKit isn't currently occupying,
    // keeping card/header edges fixed with either scrollbar preference.
    let nativeGutter = max(0, scrollView.bounds.width - scrollView.contentView.frame.width)
    return max(-Metrics.cardInset, Metrics.verticalScrollerLane - nativeGutter)
  }

  private func currentCardLayout(viewportWidth: CGFloat? = nil) -> ClipboardItemCardLayout {
    if viewModel.usesCardShelf {
      // Overlay scrollers occupy the viewport; legacy scrollers already reduce
      // it. Reserve the same bottom lane in both modes, including filtered views
      // that temporarily show the new-copy notice above the cards.
      let nativeGutter = max(0, scrollView.bounds.height - scrollView.contentView.frame.height)
      let scrollerClearance = max(0, 16 - nativeGutter)
      return .gallery(width: viewModel.shelfWidth, largerText: viewModel.largerShelfText).fittingGalleryHeight(
        scrollView.contentView.bounds.height - 8 - scrollerClearance)
    }
    let layout = ClipboardItemCardLayout.compact.withLargerText(viewModel.largerShelfText)
    let visibleWidth = viewportWidth ?? scrollView.contentView.bounds.width
    guard visibleWidth > 1 else { return layout }

    let availableCardWidth = floor(visibleWidth - Metrics.cardInset - verticalCardTrailingInset)
    guard availableCardWidth > 0 else { return layout }

    return layout.withWidth(max(Metrics.minimumVerticalCardWidth, availableCardWidth))
  }

  private func verticalCardMinXInContent(width cardWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
    let readingWidth = viewportWidth - verticalScrollerInsetAdjustment
    return max(Metrics.cardInset, floor((readingWidth - cardWidth) / 2))
  }

  private func alignVerticalScrollerThumb() {
    guard !viewModel.usesCardShelf, let scroller = scrollView.verticalScroller as? ShelfScroller else { return }
    // AppKit gives overlay scrollers a wide, asymmetrically inset frame. Keep
    // the hit area inside the card-to-wall gutter before centering its thumb.
    let gutterWidth: CGFloat = 12
    if abs(scroller.frame.width - gutterWidth) > 0.25 { scroller.setFrameSize(NSSize(width: gutterWidth, height: scroller.frame.height)) }
    let viewportWidth = scrollView.contentView.bounds.width
    guard viewportWidth > 1 else { return }
    let cardWidth = currentCardLayout(viewportWidth: viewportWidth).width
    let cardRight = verticalCardMinXInContent(width: cardWidth, viewportWidth: viewportWidth) + cardWidth
    let cardRightInPanel = scrollView.contentView.convert(NSPoint(x: cardRight, y: 0), to: self).x
    let centeredThumbInPanel = (cardRightInPanel + bounds.maxX) / 2
    let currentThumbInPanel = scroller.convert(NSPoint(x: scroller.rect(for: .knob).midX, y: 0), to: self).x
    let correction = centeredThumbInPanel - currentThumbInPanel
    if abs(correction) > 0.25 {
      // Move the native scroller and its hit area together. Offsetting only
      // the paint makes the visible thumb disagree with drag hit testing.
      scroller.setFrameOrigin(NSPoint(x: scroller.frame.minX + correction, y: scroller.frame.minY))
    }
  }

  private func applyPanelLayout(reloadItems shouldReload: Bool = true) {
    appliedShelfLayout = viewModel.shelfLayout
    contentTypeScrollView.documentView = nil
    // The horizontal shelf shares a single row of controls. Reparent the real
    // search field and actions so focus, editor anchors, and hover stay intact.
    if let shelfChrome = shelfChromeView as? NSStackView, let actions = utilityToolbarGroup {
      utilityToolbarTrailingConstraint?.isActive = false
      shelfControls.setHorizontalLayout(viewModel.usesCardShelf, searchView: searchControl, actionView: actions)
      if !viewModel.usesCardShelf {
        if searchControl.superview !== shelfChrome { shelfChrome.addArrangedSubview(searchControl) }
        if actions.superview !== shelfChrome { shelfChrome.addArrangedSubview(actions) }
        utilityToolbarTrailingConstraint?.isActive = true
      }
      shelfChrome.isHidden = viewModel.usesCardShelf
    }
    idealSearchWidthConstraint?.constant = viewModel.usesCardShelf ? 240 : 300
    idealSearchWidthConstraint?.priority = viewModel.usesCardShelf ? NSLayoutConstraint.Priority(rawValue: 249) : .defaultLow
    if !viewModel.usesCardShelf { contentTypeScrollView.documentView = shelfControls.contentTypeRailView }
    contentTypeNotch.isHidden = viewModel.usesCardShelf
    contentTypeNotchHeightConstraint?.isActive = !viewModel.usesCardShelf
    let typeRailInset = viewModel.usesCardShelf ? 0 : ClipboardShelfControls.contentTypeRailAllowance
    scrollViewLeadingConstraint?.constant = typeRailInset
    headerLeadingConstraint?.constant = typeRailInset + Metrics.cardInset
    shelfSurface.cornerRadius = viewModel.usesCardShelf ? 28 : 20
    bottomSafeInset = viewModel.usesCardShelf ? 14 : 20
    mainStack?.edgeInsets = contentInsets()
    updateShelfChromeLayout()
    scrollView.hasHorizontalScroller = viewModel.usesCardShelf
    scrollView.hasVerticalScroller = !viewModel.usesCardShelf
    scrollView.autohidesScrollers = true
    scrollViewTrailingConstraint?.constant = viewModel.usesCardShelf ? 0 : Metrics.verticalScrollerLane
    scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    lastScrollViewportSize = .zero
    configureCardInsets()

    if shouldReload {
      reloadItems()
      updateSelection()
    }
    needsLayout = true
  }

  private func updateShelfChromeLayout() {
    shelfChromeHeightConstraint?.constant = Metrics.collectionRailHeight
    shelfChromeView?.needsLayout = true
    headerStack?.needsLayout = true
    contentStack?.needsLayout = true
  }

  private func contentInsets() -> NSEdgeInsets {
    NSEdgeInsets(top: Metrics.panelTopInset, left: Metrics.panelSideInset, bottom: bottomSafeInset, right: Metrics.panelSideInset)
  }

  private func iconButton(_ systemName: String, toolTip: String, accessibilityHelp: String, action: Selector) -> NSButton {
    let button = ClipboardToolbarIconButton(title: "", target: self, action: action)
    button.configureIcon(systemName, label: toolTip, size: Metrics.actionButtonSize, bezel: .smallSquare, template: true)
    button.setAccessibilityHelp(accessibilityHelp)
    button.translatesAutoresizingMaskIntoConstraints = false
    toolbarButtons.append(button)
    return button
  }

  private func reloadItems() {
    clearCardHoverStates()
    // Keep the content under the pointer stable while browsing older copies.
    // At the leading edge, let new copies appear naturally in first position.
    var viewportAnchor: (id: UUID, offset: CGFloat)?
    let visible = scrollView.contentView.bounds
    let origin = viewModel.usesCardShelf ? visible.minX : visible.minY
    if let context = currentCardRenderContext, context.scope == currentScope, origin > 1 {
      let survivingIDs = Set(viewModel.visibleItems.map(\.id))
      // Use the previous rendered frames: the model may already have moved
      // its selection or inserted a new item before this reload reaches us.
      if let slot = cardSlots.keys.sorted().compactMap({ cardSlots[$0] }).first(where: {
        survivingIDs.contains($0.representedItemID) && (viewModel.usesCardShelf ? $0.frame.maxX : $0.frame.maxY) > origin
      }) {
        viewportAnchor = (slot.representedItemID, origin - (viewModel.usesCardShelf ? slot.frame.minX : slot.frame.minY))
      }
    }
    cardReloadGeneration += 1
    let reloadGeneration = cardReloadGeneration
    let focusedCardReloadTarget = focusedCardReloadTarget()
    reusableCards = Dictionary(cardViews.map { ($0.representedItemID, $0) }, uniquingKeysWith: { first, _ in first })
    currentCardRenderContext = nil
    verticalGrid = nil
    keyboardColumnX = nil
    cardViews.removeAll()
    cardSlots.removeAll()
    cardItemCount = 0
    lastScrollViewportSize = .zero
    for view in cardsDocument.subviews { view.removeFromSuperview() }

    let items = viewModel.visibleItems
    // A background capture must never blink the entire shelf.
    if items.isEmpty {
      scrollView.documentView = emptyStateView()
    } else {
      if scrollView.documentView !== cardsDocument { scrollView.documentView = cardsDocument }
      let collectionNames = viewModel.collectionNames
      let layout = currentCardLayout()
      let canShowInClipboard = viewModel.canShowVisibleItemsInClipboard

      currentCardRenderContext = CardRenderContext(
        items: items, revision: viewModel.visibleItemsRevision, collectionNames: collectionNames, layout: layout,
        canShowInClipboard: canShowInClipboard, reloadGeneration: reloadGeneration, scope: currentScope)
      cardItemCount = items.count
      if !viewModel.usesCardShelf {
        verticalGrid = ClipboardVerticalGridLayout(items: items, base: layout, spacing: ClipboardShelfStyle.cardSpacing)
      }
      sizeItemsDocument(itemCount: items.count)

      let synchronousRange = initialCardRenderRange(itemCount: items.count)
      renderCards(in: synchronousRange, reloadGeneration: reloadGeneration)
    }

    updateSelection(scrollSelection: viewportAnchor == nil)
    restoreFocusedCardIfNeeded(focusedCardReloadTarget)
    if let viewportAnchor, let context = currentCardRenderContext,
      let index = context.items.firstIndex(where: { $0.id == viewportAnchor.id })
    {
      let frame = cardSlotFrame(at: index, layout: context.layout)
      let point =
        viewModel.usesCardShelf
        ? NSPoint(x: frame.minX + viewportAnchor.offset, y: 0) : NSPoint(x: 0, y: frame.minY + viewportAnchor.offset)
      scrollView.contentView.scroll(to: point)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      renderCardsNearVisibleViewport()
    }
  }

  private var renderedItemsMatchModel: Bool { currentCardRenderContext?.revision == viewModel.visibleItemsRevision }

  private var currentScope: String {
    [
      viewModel.searchText, String(viewModel.sortMode.rawValue), String(viewModel.contentFilter?.rawValue ?? -1),
      viewModel.selectedCollectionName ?? "", String(viewModel.sortByUsage), String(viewModel.shelfLayout.rawValue),
    ].joined(separator: "\u{1f}")
  }

  private func initialCardRenderRange(itemCount: Int) -> Range<Int> {
    guard itemCount > 0 else { return 0..<0 }
    let visible = visibleCardIndexRange()
    return visible.lowerBound..<min(itemCount, max(visible.upperBound, visible.lowerBound + initialCardRenderBudget))
  }

  private func renderCardsNearVisibleViewport() {
    guard scrollView.documentView === cardsDocument, currentCardRenderContext != nil, cardItemCount > 0 else { return }
    let visibleRange = visibleCardIndexRange()
    renderCards(in: visibleRange, reloadGeneration: cardReloadGeneration)
    pruneRenderedCards(outside: retainedCardIndexRange(around: visibleRange))
  }

  private func visibleCardIndexRange() -> Range<Int> {
    let itemCount = cardItemCount
    guard itemCount > 0 else { return 0..<0 }

    let visibleBounds = scrollView.contentView.bounds
    let layout = currentCardLayout()
    let edgeInsets = cardsDocument.contentInsets
    let startPosition = viewModel.usesCardShelf ? visibleBounds.minX : visibleBounds.minY
    let endPosition = viewModel.usesCardShelf ? visibleBounds.maxX : visibleBounds.maxY
    let leadingInset = viewModel.usesCardShelf ? edgeInsets.left : edgeInsets.top

    let relativeStart = max(0, startPosition - leadingInset)
    let relativeEnd = max(relativeStart, endPosition - leadingInset)
    let firstVisible = firstCardIndex(endingAtOrAfter: relativeStart, itemCount: itemCount, layout: layout)
    let lastVisible = lastCardIndex(startingAtOrBefore: relativeEnd, itemCount: itemCount, layout: layout)
    let lowerBound = max(0, firstVisible - cardRenderPrefetchBuffer)
    let upperBound = min(itemCount, lastVisible + cardRenderPrefetchBuffer + 1)
    return lowerBound..<max(lowerBound, upperBound)
  }

  private func firstCardIndex(endingAtOrAfter position: CGFloat, itemCount: Int, layout: ClipboardItemCardLayout) -> Int {
    var lowerBound = 0
    var upperBound = itemCount
    while lowerBound < upperBound {
      let index = (lowerBound + upperBound) / 2
      let end = cardSlotOffset(at: index, layout: layout) + cardSlotPrimaryLength(at: index, layout: layout)
      if end < position { lowerBound = index + 1 } else { upperBound = index }
    }
    return min(max(0, lowerBound), max(0, itemCount - 1))
  }

  private func lastCardIndex(startingAtOrBefore position: CGFloat, itemCount: Int, layout: ClipboardItemCardLayout) -> Int {
    var lowerBound = 0
    var upperBound = itemCount
    while lowerBound < upperBound {
      let index = (lowerBound + upperBound) / 2
      if cardSlotOffset(at: index, layout: layout) <= position { lowerBound = index + 1 } else { upperBound = index }
    }
    return min(max(0, lowerBound - 1), max(0, itemCount - 1))
  }

  private func renderCards(in range: Range<Int>, reloadGeneration: Int) {
    guard let context = currentCardRenderContext, context.reloadGeneration == reloadGeneration, !range.isEmpty else { return }

    let clampedRange = max(0, range.lowerBound)..<min(context.items.count, range.upperBound)
    guard !clampedRange.isEmpty else { return }

    for index in clampedRange {
      guard cardSlots[index]?.card == nil else { continue }

      let item = context.items[index]
      let card = makeCard(item: item, index: index, context: context)
      let slot = cardSlot(at: index, itemID: item.id, layout: context.layout)
      slot.attachCard(card)
      configureCardCallbacks(card, slot: slot)
      applyCurrentCardState(card, index: index)
      if !card.hasThumbnail {
        viewModel.loadThumbnail(for: item) { [weak slot, weak card] thumbnail in
          guard let slot, let card, slot.card === card, let thumbnail else { return }
          card.updateThumbnail(thumbnail)
        }
      }
    }

    cardViews = renderedCardsInItemOrder()
  }

  private func makeCard(item: ClipboardItem, index: Int, context: CardRenderContext) -> ClipboardItemCardView {
    let layout = contentLayout(at: index, base: context.layout)
    let configuration = ClipboardCardConfiguration(
      item: item, layout: layout, collectionNames: context.collectionNames, canShowInClipboard: context.canShowInClipboard)
    if let reused = reusableCards.removeValue(forKey: item.id), reused.canReuse(with: configuration) {
      reused.updateIndex(index)
      return reused
    }
    return ClipboardItemCardView(configuration: configuration, thumbnail: nil, index: index)
  }

  private func renderCardIfNeeded(at index: Int) {
    guard index >= 0, index < cardItemCount else { return }
    renderCards(in: index..<(index + 1), reloadGeneration: cardReloadGeneration)
  }

  private func cardView(at index: Int) -> ClipboardItemCardView? { cardSlots[index]?.card }

  private func cardSlot(at index: Int, itemID: UUID, layout: ClipboardItemCardLayout) -> ClipboardItemCardSlotView {
    if let slot = cardSlots[index] { return slot }

    let slot = ClipboardItemCardSlotView(itemID: itemID)
    slot.frame = cardSlotFrame(at: index, layout: layout)
    cardSlots[index] = slot
    cardsDocument.addSubview(slot)
    return slot
  }

  private func renderedCardsInItemOrder() -> [ClipboardItemCardView] { cardSlots.keys.sorted().compactMap { cardSlots[$0]?.card } }

  private func retainedCardIndexRange(around renderedRange: Range<Int>) -> Range<Int> {
    let itemCount = cardItemCount
    guard itemCount > 0 else { return 0..<0 }
    let lowerBound = max(0, renderedRange.lowerBound - cardRenderRetentionBuffer)
    let upperBound = min(itemCount, renderedRange.upperBound + cardRenderRetentionBuffer)
    return lowerBound..<max(lowerBound, upperBound)
  }

  private func pruneRenderedCards(outside retainedRange: Range<Int>) {
    guard !cardSlots.isEmpty else { return }
    let activeIndex = viewModel.selectedIndex
    let focusedIndex = focusedRenderedCardIndex()
    let removableIndexes = cardSlots.keys.filter { index in !retainedRange.contains(index) && index != activeIndex && index != focusedIndex
    }
    guard !removableIndexes.isEmpty else { return }

    for index in removableIndexes { cardSlots.removeValue(forKey: index)?.removeFromSuperview() }
    cardViews = renderedCardsInItemOrder()
  }

  private func focusedRenderedCardIndex() -> Int? {
    guard let responder = window?.firstResponder as? NSView else { return nil }
    for (index, slot) in cardSlots {
      guard let card = slot.card else { continue }
      if responder === card || responder.isDescendant(of: card) { return index }
    }
    return nil
  }

  private func positionRenderedCardSlots() {
    let layout = currentCardLayout()
    for (index, slot) in cardSlots { slot.frame = cardSlotFrame(at: index, layout: layout) }
  }

  private func cardSlotFrame(at index: Int, layout: ClipboardItemCardLayout) -> NSRect {
    let edgeInsets = cardsDocument.contentInsets
    let size = contentLayout(at: index, base: layout).size
    if viewModel.usesCardShelf {
      return NSRect(x: cardSlotOffset(at: index, layout: layout) + 4, y: 4, width: size.width, height: size.height)
    }
    let x =
      verticalCardMinXInContent(width: layout.width, viewportWidth: cardsDocument.bounds.width)
      + (verticalGrid?.entries[index].frame.minX ?? 0)
    let y = cardSlotOffset(at: index, layout: layout) + edgeInsets.top
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  private func cardSlotPrimaryLength(at index: Int, layout: ClipboardItemCardLayout) -> CGFloat {
    viewModel.usesCardShelf ? layout.width : contentLayout(at: index, base: layout).size.height
  }

  private func contentLayout(at index: Int, base: ClipboardItemCardLayout) -> ClipboardItemCardLayout {
    guard !base.usesGalleryStyle, let context = currentCardRenderContext, context.items.indices.contains(index) else { return base }
    return verticalGrid?.entries[index].layout ?? base.fittingVerticalContent(of: context.items[index])
  }

  private func cardSlotOffset(at targetIndex: Int, layout: ClipboardItemCardLayout) -> CGFloat {
    if viewModel.usesCardShelf { return CGFloat(targetIndex) * (layout.width + ClipboardShelfStyle.cardSpacing) }
    guard let verticalGrid, verticalGrid.entries.indices.contains(targetIndex) else { return 0 }
    return verticalGrid.entries[targetIndex].frame.minY
  }

  private func configureCardCallbacks(_ card: ClipboardItemCardView, slot: ClipboardItemCardSlotView) {
    card.setCarouselDistance(hoveredCardIndex.map { carouselDistance(from: $0, to: card.representedIndex) })
    card.onHover = { [weak self] index, _ in
      guard let self, self.presentedMenuWindow == nil else { return false }
      self.hoveredCardIndex = index
      self.keyboardColumnX = nil
      self.clearCardHoverStates(except: index)
      for other in self.cardViews { other.setCarouselDistance(self.carouselDistance(from: index, to: other.representedIndex)) }
      return true
    }
    card.onHoverExit = { [weak self] index in
      guard let self, self.hoveredCardIndex == index else { return }
      self.hoveredCardIndex = nil
      for other in self.cardViews { other.setCarouselDistance(nil) }
    }
    card.onLiftStateChanged = { [weak slot] lifted in slot?.setLifted(lifted) }
    card.onSelect = { [weak self] selected, mode in
      if mode != .activate { self?.keyboardColumnX = nil }
      if mode == .activate, self?.selectionScrollSuppressionCount ?? 0 > 0, self?.viewModel.selectedIndex == selected {
        self?.selectionScrollSuppressionCount = 0
        return
      }
      if mode == .activate { self?.claimKeyboardCardSelection() }
      if mode != .activate { self?.selectionScrollSuppressionCount = 0 }
      self?.searchControl.releaseIdleFocus()
      self?.viewModel.selectItem(at: selected, mode: mode)
    }
    card.onStartSearch = { [weak self] text in self?.startSearchFromShelf(text) }
    card.onNavigate = { [weak self] in self?.navigate($0) }
    card.onPasteboardWriters = { [weak self] selected in self?.viewModel.pasteboardWriters(forItemAt: selected) ?? [] }
    card.onCommand = { [weak self, weak card] command in
      guard let self, let card else { return }
      self.performCardCommand(command, at: card.representedIndex)
    }
  }

  private func performCardCommand(_ command: ClipboardCardCommand, at index: Int) {
    if let mode = command.selectionMode { viewModel.selectItem(at: index, mode: mode) }
    performCommand(command, at: index)
  }

  /// All input surfaces use this handler; only editor/window operations belong to the view.
  func performCommand(_ command: ClipboardCardCommand, at cardIndex: Int? = nil) {
    if viewModel.performCommand(command) { return }
    let index = cardIndex ?? viewModel.selectedIndex
    switch command {
    case .showInClipboard: showSelectedInClipboard(at: index)
    case .rename: renameClip(at: index)
    case .editText: editText(at: index)
    case .preview: onPreview()
    case .focusSearch: focusSearch()
    case .newText: createTextClip()
    case .close: onClose()
    case .createCollection:
      if cardIndex == nil {
        createCollectionFromToolbar()
        return
      }
      let targetIDs = viewModel.selectedItemIDs.isEmpty ? viewModel.selectedItem.map { [$0.id] } ?? [] : viewModel.selectedItemIDs
      requestCollectionCreation { [weak self] request in
        self?.viewModel.createCollection(named: request.name, colorHex: request.colorHex, icon: request.icon, selectAfterCreate: false)
        for id in targetIDs { self?.viewModel.assignItem(withID: id, to: request.name) }
      }
    default: break
    }
  }

  private func carouselDistance(from first: Int, to second: Int) -> Int {
    guard let verticalGrid, verticalGrid.entries.indices.contains(first), verticalGrid.entries.indices.contains(second) else {
      return abs(first - second)
    }
    let a = verticalGrid.entries[first]
    let b = verticalGrid.entries[second]
    let rowDistance = abs(a.row - b.row)
    let sharesColumn = a.frame.minX < b.frame.maxX && b.frame.minX < a.frame.maxX
    return rowDistance + (sharesColumn ? 0 : 1)
  }

  private func focusedCardReloadTarget() -> FocusedCardReloadTarget? {
    guard let responder = window?.firstResponder as? NSView else { return nil }
    for card in cardViews where responder === card || responder.isDescendant(of: card) {
      return FocusedCardReloadTarget(itemID: card.representedItemID, fallbackIndex: card.representedIndex)
    }
    return nil
  }

  private func restoreFocusedCardIfNeeded(_ target: FocusedCardReloadTarget?) {
    guard let target else { return }

    if cardView(at: target.fallbackIndex) == nil { renderCardIfNeeded(at: target.fallbackIndex) }
    let fallbackCard = cardView(at: target.fallbackIndex)
    let focusedCard = cardViews.first { $0.representedItemID == target.itemID } ?? fallbackCard
    guard let focusedCard else { return }
    window?.makeFirstResponder(focusedCard)
  }

  private func handleVisibleItemsChanged() {
    if appliedShelfLayout != viewModel.shelfLayout { applyPanelLayout(reloadItems: false) }
    shelfControls.refresh()
    if defersVisualReloads {
      pendingItemReload = true
      return
    }
    reloadItems()
  }

  private func handleCollectionsChanged() {
    shelfControls.refresh()
    if defersVisualReloads {
      pendingItemReload = true
      return
    }
    reloadItems()
  }

  private func flushDeferredVisualReloads() {
    if pendingItemReload {
      pendingItemReload = false
      reloadItems()
    }
    shelfControls.refresh()
  }

  private func applyCurrentCardState(_ card: ClipboardItemCardView, index: Int) {
    let isVisuallyExpanded = index == viewModel.selectedIndex
    card.setSelectionState(
      active: isVisuallyExpanded, selected: viewModel.isItemSelected(at: index), selectionCount: viewModel.selectedItemCount)
  }

  private func updateSelection(scrollSelection: Bool = true) {
    shelfControls.refresh()
    renderCardIfNeeded(at: viewModel.selectedIndex)

    var activeCard: ClipboardItemCardView?
    for card in cardViews {
      let index = card.representedIndex
      applyCurrentCardState(card, index: index)
      if index == viewModel.selectedIndex { activeCard = card }
    }

    let shouldSuppressSelectionScroll = selectionScrollSuppressionCount > 0
    if shouldSuppressSelectionScroll { selectionScrollSuppressionCount -= 1 }

    if let activeCard, scrollSelection, !shouldSuppressSelectionScroll { scrollCardIntoView(activeCard) }
  }

  private func scrollCardIntoView(_ card: ClipboardItemCardView) {
    guard scrollView.documentView === cardsDocument else { return }
    guard card.window != nil else { return }
    scrollView.layoutSubtreeIfNeeded()
    cardsDocument.layoutSubtreeIfNeeded()

    let frame = cardSlotFrame(at: card.representedIndex, layout: currentCardLayout())
    let paddedFrame = frame.insetBy(
      dx: viewModel.usesCardShelf ? -4 : 0, dy: viewModel.usesCardShelf ? 0 : -ClipboardShelfStyle.cardSpacing)
    cardsDocument.scrollToVisible(paddedFrame)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func focusSelectedCollectionChip() { shelfControls.focusDestination() }

  private func editText(at index: Int) {
    viewModel.selectItem(at: index)
    guard let currentText = viewModel.editableTextForSelected(), let id = viewModel.selectedItem?.id else { return }
    presentTextEditor(title: "Edit Text", initialText: currentText) { [weak self] text in
      self?.viewModel.updateText(itemID: id, to: text) == true
    }
  }

  func editSelectedClip() { editText(at: viewModel.selectedIndex) }

  @objc func createTextClip() {
    if let textEditorController, textEditorController.window.title == "New Text Clip" {
      if textEditorController.isPresented {
        textEditorController.dismiss()
      } else {
        dismissMenus()
        resumeTextEditorIfNeeded()
      }
      return
    }
    presentTextEditor(title: "New Text Clip", initialText: "") { [weak self] text in self?.viewModel.createTextClip(text) == true }
  }

  private func presentTextEditor(title: String, initialText: String, save: @escaping (String) -> Bool) {
    dismissMenus()
    guard textEditorController == nil, let window else { return }
    let textView = Self.makePlainTextEditor(initialText: initialText)
    let editor = ClipTextEditorController(
      title: title, editor: textView,
      onSave: { [weak self] text in save(text) ? nil : (self?.viewModel.statusMessage ?? "Could not save. Your draft is still here.") },
      onFinish: { [weak self] in
        self?.textEditorController = nil
        self?.syncSearchFieldFromViewModel()
        if self?.window?.isVisible == true { self?.window?.makeKeyAndOrderFront(nil) }
        self?.focusSelectedCard()
      })
    textEditorController = editor
    editor.show(relativeTo: window, anchoredTo: newClipButton)
  }

  private func presentSheet(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
    guard let window, window.attachedSheet == nil else { return }
    alert.beginSheetModal(for: window, completionHandler: completion)
  }

  private func renameClip(at index: Int) {
    viewModel.selectItem(at: index)
    guard let item = viewModel.selectedItem else { return }
    let currentTitle = item.customTitle ?? ""

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    input.placeholderString = "Clip title"
    input.stringValue = currentTitle

    let alert = NSAlert()
    alert.messageText = "Rename Clip"
    alert.informativeText = "Give this clip a searchable title. Leave it blank to clear the title."
    alert.accessoryView = input
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = input

    presentSheet(alert) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.viewModel.updateTitle(itemID: item.id, to: input.stringValue)
    }
  }

  func renameSelectedClip() { renameClip(at: viewModel.selectedIndex) }

  private func emptyStateView() -> NSView {
    let width = max(1, scrollView.contentView.bounds.width)
    let height = max(Metrics.minimumEmptyStateHeight, scrollView.contentView.bounds.height)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let copy = emptyStateCopy()
    let searching = !viewModel.searchText.isEmpty || viewModel.contentFilter != nil
    let symbol = searching ? "magnifyingglass" : (viewModel.isCapturePaused ? "pause.circle" : "tray")
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = ClipboardShelfStyle.secondaryText
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
    icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let title = NativeUI.label(
      copy.title, wrap: true, font: .systemFont(ofSize: 19, weight: .semibold), color: .labelColor, alignment: .center, maxLines: 2)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let detail = NativeUI.label(
      copy.detail, wrap: true, font: .systemFont(ofSize: 13), color: ClipboardShelfStyle.secondaryText, alignment: .center, maxLines: 3)
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let actionTitle: String
    if searching {
      actionTitle = "Clear search & filters"
    } else if viewModel.hasActiveFilters {
      actionTitle = "Show all clips"
    } else if viewModel.isCapturePaused {
      actionTitle = "Resume capture"
    } else {
      actionTitle = "Create a text clip"
    }
    let recovery = NSButton(title: actionTitle, target: self, action: #selector(performEmptyStateRecovery))
    recovery.bezelStyle = .rounded
    let stack = NativeUI.stack([icon, title, detail, recovery], axis: .vertical, alignment: .centerX, spacing: 10)
    stack.setCustomSpacing(16, after: detail)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let idealWidth = stack.widthAnchor.constraint(equalToConstant: 320)
    idealWidth.priority = .defaultHigh
    idealWidth.isActive = true
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380), title.widthAnchor.constraint(equalTo: stack.widthAnchor),
      detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    return container
  }

  @objc private func performEmptyStateRecovery() {
    if !viewModel.searchText.isEmpty || viewModel.contentFilter != nil {
      resetSearchAndFilters()
    } else if viewModel.hasActiveFilters {
      resetSearchAndFilters()
    } else if viewModel.isCapturePaused {
      viewModel.toggleCapturePause()
    } else {
      createTextClip()
    }
  }

  private func sizeItemsDocument(itemCount: Int) {
    let viewportSize = scrollView.contentView.bounds.size
    let layout = currentCardLayout(viewportWidth: viewportSize.width)
    if viewModel.usesCardShelf {
      let width = CGFloat(itemCount) * (layout.width + ClipboardShelfStyle.cardSpacing) - ClipboardShelfStyle.cardSpacing + 8
      cardsDocument.frame = NSRect(x: 0, y: 0, width: max(viewportSize.width, width), height: max(viewportSize.height, layout.height + 8))
      lastScrollViewportSize = viewportSize
      positionRenderedCardSlots()
      return
    }
    let contentHeight = (verticalGrid?.height ?? 0) + (Metrics.cardInset * 2)
    let width = max(viewportSize.width, layout.width + Metrics.cardInset + verticalCardTrailingInset)
    let height = max(viewportSize.height, contentHeight)
    lastScrollViewportSize = viewportSize
    let targetFrame = NSRect(x: 0, y: 0, width: width, height: height)
    cardsDocument.frame = targetFrame
    positionRenderedCardSlots()
    cardsDocument.needsLayout = true
    cardsDocument.layoutSubtreeIfNeeded()
  }

  private func emptyStateCopy() -> (title: String, detail: String) {
    if !viewModel.searchText.clipboardTrimmed.isEmpty { return ("No matching clips", "Try a broader search or switch filters.") }

    if viewModel.contentFilter != nil, viewModel.selectedCollectionName != nil || viewModel.sortMode == .pinned {
      return ("No clips of this type", "Choose another type or clear the filters to see more clips.")
    }

    if let collectionName = viewModel.selectedCollectionName {
      return ("No clips in \(collectionName)", "Select clips in All clips, then use More to add them to this Pinboard.")
    }

    if viewModel.totalItemCount == 0 {
      return (
        "Copy something to start your history",
        viewModel.captureStatusMessage.isEmpty
          ? "Goldfish records clipboard changes locally. Accessibility is only needed for automatic paste." : viewModel.captureStatusMessage
      )
    }

    switch viewModel.contentFilter ?? viewModel.sortMode {
    case .images: return ("No images yet", "Image clips are saved when the clipboard contains image data.")
    case .colors: return ("No colors yet", "Copied color swatches appear here.")
    case .links: return ("No links yet", "Links are detected from copied URLs.")
    case .text: return ("No text clips yet", "Copied text and rich text appear here.")
    case .code: return ("No code snippets yet", "Copied code snippets appear here.")
    case .videos: return ("No videos yet", "Copied movie and video clips appear here.")
    case .files: return ("No files yet", "Copied files and PDFs appear here.")
    case .audio: return ("No audio yet", "Copied sound clips appear here.")
    case .pinned: return ("No pinned clips", "Select a clip, then choose Pin in the More menu to keep it here.")
    case .mostRecent, .mostUsed: return ("No clips in this view", "Switch filters or copy something new.")
    }
  }

  var isSearchFieldEditing: Bool { searchControl.isEditing }
  var searchTextForKeyboardShortcut: String { searchControl.text }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  override func mouseDown(with event: NSEvent) {
    searchControl.releaseIdleFocus()
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func layout() {
    super.layout()
    shelfSurface.setNotch(
      frame: viewModel.usesCardShelf ? .zero : convert(contentTypeNotch.bounds, from: contentTypeNotch),
      bodyLeadingInset: viewModel.usesCardShelf ? 0 : ClipboardShelfControls.contentTypeRailAllowance)
    alignVerticalScrollerThumb()
    if cardsDocument.contentInsets.right != verticalCardTrailingInset {
      var insets = cardsDocument.contentInsets
      insets.right = verticalCardTrailingInset
      cardsDocument.contentInsets = insets
    }

    guard !scrollView.frame.equalTo(.zero) else { return }
    let viewportSize = scrollView.contentView.bounds.size
    if let currentCardRenderContext, currentCardRenderContext.layout != currentCardLayout(viewportWidth: viewportSize.width) {
      lastScrollViewportSize = viewportSize
      reloadItems()
      return
    }
    if viewportSize == lastScrollViewportSize { return }
    lastScrollViewportSize = viewportSize

    if cardItemCount == 0 {
      guard let documentView = scrollView.documentView else { return }
      let emptyStateWidth = max(1, scrollView.contentView.bounds.width)
      documentView.frame.size = NSSize(
        width: emptyStateWidth, height: max(Metrics.minimumEmptyStateHeight, scrollView.contentView.bounds.height))
      return
    }

    sizeItemsDocument(itemCount: cardItemCount)
    renderCardsNearVisibleViewport()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    pointerTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { updateHoverForPointer(atWindowLocation: event.locationInWindow) }

  override func mouseMoved(with event: NSEvent) { updateHoverForPointer(atWindowLocation: event.locationInWindow) }

  override func mouseExited(with event: NSEvent) { clearPointerHoverStates() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    shelfSurface.refreshAppearance()
  }

  func focusSearchField() { searchControl.focus() }
  func focusSearch() { searchControl.focus() }

  @discardableResult func clearSearchForKeyboardCancel() -> Bool { searchControl.clear() }

  private func startSearchFromShelf(_ text: String) { searchControl.startSearch(with: text) }

  func setBottomSafeInset(_ inset: CGFloat) {
    bottomSafeInset = max(viewModel.usesCardShelf ? 12 : Metrics.minimumBottomInset, inset)
    mainStack?.edgeInsets = contentInsets()
    needsLayout = true
  }

  var visibleCardPageStep: Int {
    if !viewModel.usesCardShelf, let verticalGrid, !verticalGrid.entries.isEmpty {
      let visible = scrollView.contentView.bounds
      return max(1, verticalGrid.entries.filter { $0.frame.maxY > visible.minY && $0.frame.minY < visible.maxY }.count - 1)
    }
    let layout = currentCardLayout()
    let span = (viewModel.usesCardShelf ? layout.width : layout.height) + ClipboardShelfStyle.cardSpacing
    let visibleExtent = viewModel.usesCardShelf ? scrollView.contentView.bounds.width : scrollView.contentView.bounds.height
    guard span > 0 else { return 1 }
    return max(1, Int(floor(visibleExtent / span)))
  }

  func focusSelectedCardForKeyboardNavigation() {
    keyboardColumnX = nil
    claimKeyboardCardSelection()
    focusSelectedCard()
  }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if let text = shelfSearchText(from: event) { startSearchFromShelf(text) } else { super.keyDown(with: event) }
  }

  func prepareForShow() {
    clearPointerHoverStates(animated: false)
    cardViews.forEach { $0.refreshRelativeDate() }
    viewModel.clearActionStatus()
    shelfControls.refresh()
    viewModel.searchText = ""
    searchControl.text = ""
    searchControl.releaseIdleFocus()
  }

  @objc private func resetSearchAndFilters() {
    viewModel.searchText = ""
    viewModel.resetFilters()
    focusSearchField()
  }

  func beginOpeningTransition(fromLeft: Bool = false) {
    defersVisualReloads = true
    pendingItemReload = false
    revealDirection = viewModel.usesCardShelf ? 0 : (fromLeft ? -1 : 1)
    cardSlots.values.forEach { $0.layer?.removeAnimation(forKey: "shelfReveal") }
    animateVisibleCards(appearing: true)
  }

  func beginClosingTransition() { animateVisibleCards(appearing: false) }

  private func animateVisibleCards(appearing: Bool) {
    let visible = scrollView.contentView.bounds
    let slots = cardSlots.values.filter { $0.frame.intersects(visible) }.sorted {
      $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
    }
    for (index, slot) in slots.enumerated() {
      guard let layer = slot.layer else { continue }
      let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
      layer.removeAnimation(forKey: "shelfReveal")
      guard !ClipboardShelfMotion.reducesMotion else { continue }
      let opacity = CABasicAnimation(keyPath: "opacity")
      opacity.fromValue = appearing ? 0 : currentOpacity
      opacity.toValue = appearing ? 1 : 0
      let translation = CABasicAnimation(keyPath: "transform.translation.x")
      translation.fromValue = appearing ? 12 * revealDirection : 0
      translation.toValue = appearing ? 0 : 8 * revealDirection
      let animation = CAAnimationGroup()
      animation.animations = [opacity, translation]
      animation.duration = appearing ? 0.24 : 0.16
      animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + (appearing ? min(Double(index) * 0.012, 0.048) : 0)
      animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      animation.fillMode = appearing ? .backwards : .forwards
      animation.isRemovedOnCompletion = appearing
      layer.add(animation, forKey: "shelfReveal")
    }
  }

  func finishOpeningTransition() {
    guard defersVisualReloads else { return }
    defersVisualReloads = false
    flushDeferredVisualReloads()
  }

  private func moveSelectionFromFocusedCard(_ delta: Int) {
    keyboardColumnX = nil
    claimKeyboardCardSelection()
    viewModel.moveSelection(delta)
    focusSelectedCard()
  }

  private func extendSelectionFromFocusedCard(_ delta: Int) {
    keyboardColumnX = nil
    let count = viewModel.visibleItems.count
    guard count > 0 else { return }
    claimKeyboardCardSelection()
    let target = max(0, min(count - 1, viewModel.selectedIndex + delta))
    viewModel.selectItem(at: target, mode: .range)
    focusSelectedCard()
  }

  private func navigateVerticalRow(_ direction: Int, extend: Bool) {
    guard let verticalGrid, !viewModel.usesCardShelf, verticalGrid.entries.indices.contains(viewModel.selectedIndex) else {
      if extend { extendSelectionFromFocusedCard(direction) } else { moveSelectionFromFocusedCard(direction) }
      return
    }
    let index = viewModel.selectedIndex
    if keyboardColumnX == nil { keyboardColumnX = verticalGrid.entries[index].frame.midX }
    let target = verticalGrid.verticalNeighbor(of: index, direction: direction, preferredX: keyboardColumnX)
    claimKeyboardCardSelection()
    viewModel.selectItem(at: target, mode: extend ? .range : .replace)
    focusSelectedCard()
  }

  func navigate(_ action: ClipboardCardNavigation, fromPanel: Bool = false) {
    if fromPanel {
      keyboardColumnX = nil
      claimKeyboardCardSelection()
    }
    switch action {
    case .move(let delta, let extend), .page(let delta, let extend):
      let step: Int
      if case .page = action { step = delta * visibleCardPageStep } else { step = delta }
      if extend { extendSelectionFromFocusedCard(step) } else { moveSelectionFromFocusedCard(step) }
    case .vertical(let direction, let extend): navigateVerticalRow(direction, extend: extend)
    case .endpoint(let last, let extend):
      if !extend { keyboardColumnX = nil }
      claimKeyboardCardSelection()
      if extend {
        viewModel.selectItem(at: last ? viewModel.visibleItems.count - 1 : 0, mode: .range)
      } else if last {
        viewModel.selectLastItem()
      } else {
        viewModel.selectFirstItem()
      }
      focusSelectedCard()
    case .all:
      viewModel.selectAllVisibleItems()
      focusSelectedCard()
    }
  }

  private func claimKeyboardCardSelection() {
    selectionScrollSuppressionCount = 0
    clearCardHoverStates()
  }

  func updateHoverForPointer(atWindowLocation location: NSPoint) {
    // The shelf's window events and pointer fallback also cover toolbar
    // controls when AppKit omits native enter/exit events on a floating panel.
    toolbarButtons.forEach { $0.updateHover(atWindowLocation: location) }
    guard presentedMenuWindow == nil, ClipboardCardDragContext.itemID == nil else { return }
    let pointInViewport = scrollView.contentView.convert(location, from: nil)
    let target: ClipboardItemCardView?
    if scrollView.contentView.bounds.contains(pointInViewport) {
      let pointInDocument = cardsDocument.convert(location, from: nil)
      target = cardSlots.values.first { $0.frame.contains(pointInDocument) }?.card
    } else {
      target = nil
    }

    if let target {
      target.setHoverState(true, notifySelection: true, mouseLocation: location)
      if viewModel.selectedItemCount <= 1, viewModel.selectedIndex != target.representedIndex {
        let cardHadKeyboardFocus = focusedRenderedCardIndex() != nil
        updatesSelectionFromPointer = true
        viewModel.selectItem(at: target.representedIndex, mode: .hover)
        updatesSelectionFromPointer = false
        if cardHadKeyboardFocus { target.focusFromPointer() }
      }
    } else if hoveredCardIndex != nil {
      clearCardHoverStates()
    }
  }

  func clearPointerHoverStates(animated: Bool = true) {
    toolbarButtons.forEach { $0.setHoverState(false, animated: animated) }
    clearCardHoverStates()
  }

  private func clearCardHoverStates(except retainedIndex: Int? = nil) {
    if retainedIndex == nil { hoveredCardIndex = nil }
    for card in cardViews where card.representedIndex != retainedIndex {
      card.setHoverState(false, notifySelection: false)
      if retainedIndex == nil { card.setCarouselDistance(nil) }
    }
  }

  private func focusSelectedCard() {
    guard viewModel.selectedIndex >= 0, viewModel.selectedIndex < cardItemCount else {
      window?.makeFirstResponder(self)
      return
    }
    renderCardIfNeeded(at: viewModel.selectedIndex)
    guard let card = cardView(at: viewModel.selectedIndex) else {
      window?.makeFirstResponder(self)
      return
    }
    window?.makeFirstResponder(card)
  }

  @objc private func showClearHistoryChoices(_ sender: NSButton) {
    suspendTextEditor()
    pinboardEditorController?.dismiss()
    shelfControls.dismissMenu(restoreFocus: false)
    clearHistoryMenuPresenter.show(title: "Clear history", sections: clearHistoryChoices(), from: sender, matchesShelfSurface: true)
  }

  func showSelectedInClipboard() { showSelectedInClipboard(at: viewModel.selectedIndex) }

  private func showSelectedInClipboard(at index: Int) {
    viewModel.selectItem(at: index)
    viewModel.showSelectedInClipboard()
    syncSearchFieldFromViewModel()
  }

  private func syncSearchFieldFromViewModel() { searchControl.text = viewModel.searchText }

  func createCollection() { createCollectionFromToolbar() }

  @objc private func createCollectionFromToolbar() {
    requestCollectionCreation { [weak self] request in
      self?.viewModel.createCollection(named: request.name, colorHex: request.colorHex, icon: request.icon, selectAfterCreate: true)
      self?.focusSelectedCollectionChip()
    }
  }

  private func editCollection(named collectionName: String) {
    requestCollectionEdit(named: collectionName) { [weak self] request in
      self?.viewModel.updateCollection(named: collectionName, to: request.name, colorHex: request.colorHex, icon: request.icon)
      self?.focusSelectedCollectionChip()
    }
  }

  private func exportCollection(named collectionName: String) {
    let panel = NSSavePanel()
    panel.title = "Export \(collectionName) Pinboard"
    ClipboardArchivePanel.configure(panel)
    panel.nameFieldStringValue = ClipboardArchivePanel.suggestedName(defaultCollectionArchiveFileName(collectionName))

    guard let window, window.attachedSheet == nil else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.viewModel.exportCollection(named: collectionName, to: url) { [weak self] result in
        if case .failure(let error) = result { self?.viewModel.reportCollectionExportFailure(error) }
      }
    }
  }

  private func deleteCollection(named collectionName: String) {
    let count = viewModel.collectionCount(named: collectionName)
    confirmDeleteCollection(named: collectionName, count: count) { [weak self] in
      self?.viewModel.deleteCollection(named: collectionName)
      self?.focusSelectedCollectionChip()
    }
  }

  private func defaultCollectionArchiveFileName(_ collectionName: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    let safeName = collectionName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    let name = safeName.isEmpty ? "Pinboard" : safeName
    return "Goldfish-\(name)-\(formatter.string(from: Date())).\(ClipboardArchiveService.fileExtension)"
  }

  static func makePlainTextEditor(initialText: String = "") -> NSTextView {
    let textView = ClipEditorTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
    configurePlainTextEditor(textView, initialText: initialText)
    return textView
  }

  static func configurePlainTextEditor(_ textView: NSTextView, initialText: String = "") {
    textView.string = initialText
    textView.font = .systemFont(ofSize: 14)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.usesAdaptiveColorMappingForDarkAppearance = true
    textView.isAutomaticSpellingCorrectionEnabled = true
    textView.isAutomaticTextReplacementEnabled = true
    if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
  }

  private func requestCollectionCreation(completion: @escaping (CollectionCreationRequest) -> Void) {
    requestCollectionDetails(
      initialName: "", initialColor: .systemRed, initialIcon: ClipboardCollectionIcon.defaultSymbol, completion: completion)
  }

  private func requestCollectionEdit(named collectionName: String, completion: @escaping (CollectionCreationRequest) -> Void) {
    requestCollectionDetails(
      initialName: collectionName, initialColor: collectionColor(forCollectionNamed: collectionName),
      initialIcon: viewModel.collectionIcon(named: collectionName) ?? ClipboardCollectionIcon.defaultSymbol, completion: completion)
  }

  private func requestCollectionDetails(
    initialName: String, initialColor: NSColor, initialIcon: String, completion: @escaping (CollectionCreationRequest) -> Void
  ) {
    guard let window, window.attachedSheet == nil else { return }
    if let existing = pinboardEditorController {
      existing.dismiss()
      return
    }
    dismissMenus()
    suspendTextEditor()
    let editor = PinboardEditorController(
      editing: !initialName.isEmpty, initialName: initialName, initialColor: initialColor, initialIcon: initialIcon,
      existingNames: { [weak self] in self?.viewModel.collectionNames ?? [] }, onSave: completion,
      onFinish: { [weak self] in
        self?.pinboardEditorController = nil
        if self?.window?.isVisible == true { self?.window?.makeKeyAndOrderFront(nil) }
      })
    pinboardEditorController = editor
    editor.show(relativeTo: window, anchoredTo: shelfControls.createPinboardButton)
  }

  private func confirmDeleteCollection(named collectionName: String, count: Int, completion: @escaping () -> Void) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete \(collectionName)?"
    let noun = count == 1 ? "clip" : "clips"
    alert.informativeText =
      count > 0
      ? "This permanently removes \(count) \(noun) in this Pinboard from clipboard history. It cannot be undone."
      : "This removes the empty Pinboard."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Delete Pinboard")
    alert.buttons[1].hasDestructiveAction = true
    presentSheet(alert) { response in if response == .alertSecondButtonReturn { completion() } }
  }
}
