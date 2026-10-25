import AppKit

final class ShelfView: NSView {
  private enum Metrics {
    static let actionButtonSize = ShelfStyle.controlSize
    static let cardInset: CGFloat = 4
    static let minimumEmptyStateHeight: CGFloat = 88
    static let panelTopInset = ShelfStyle.inset
    static let panelSideInset = ShelfStyle.inset
    static let minimumBottomInset: CGFloat = 20
    static let panelCornerRadius: CGFloat = 28
    static let collectionRailHeight: CGFloat = 36
    // The vertical scrollbar lives in the shelf's outer right margin. The
    // card column stays centered between the two 20 pt visual margins.
    static let verticalScrollerLane: CGFloat = 16
    static let minimumVerticalCardWidth: CGFloat = 180
  }

  private let viewModel: ShelfModel
  private let onClose: () -> Void
  private let onPreview: () -> Void

  private let searchControl = ShelfSearchControl()
  private weak var utilityToolbarGroup: NSView?
  private var utilityToolbarTrailingConstraint: NSLayoutConstraint?
  private var idealSearchWidthConstraint: NSLayoutConstraint?
  private var toolbarButtons: [ShelfIconButton] = []
  private let cardsDocument = ClipboardCardsDocumentView()
  private let scrollView = ShelfScrollView()
  private var mainStack: NSStackView?
  private var bottomSafeInset = Metrics.minimumBottomInset
  private var scrollViewTrailingConstraint: NSLayoutConstraint?
  private var scrollViewLeadingConstraint: NSLayoutConstraint?
  private var headerLeadingConstraint: NSLayoutConstraint?
  private var shelfChromeHeightConstraint: NSLayoutConstraint?
  private weak var shelfChromeView: NSView?
  private weak var headerStack: NSStackView?
  private weak var contentStack: NSView?
  private var cardViews: some Sequence<CardView> { cardSlots.values.lazy.map(\.card) }
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
  private var arrangement: CardArrangement? { currentCardRenderContext?.arrangement }
  private var keyboardColumnX: CGFloat?
  private var cardSlots: [Int: CardSlot] = [:]
  private var cardItemCount: Int { currentCardRenderContext?.items.count ?? 0 }
  private var lastScrollViewportSize: NSSize = .zero
  private var appliedShelfLayout: ShelfLayout?
  private var selectionScrollSuppressionCount = 0
  private var defersVisualReloads = false
  private var revealDirection: CGFloat = 1
  private var pendingItemReload = false
  private var textEditorController: ClipTextEditorController?
  private var pinboardEditorController: PinboardEditorController?
  var hasActiveTextEditor: Bool { textEditorController?.isPresented == true }
  var presentedTextEditorWindow: NSWindow? { hasActiveTextEditor ? textEditorController?.window : nil }
  func suspendTextEditor() { textEditorController?.suspend() }
  @discardableResult func resumeTextEditorIfNeeded() -> Bool {
    guard presentedMenuWindow == nil, let textEditorController, !textEditorController.isPresented, let window, window.attachedSheet == nil
    else { return false }
    textEditorController.show(relativeTo: window, anchoredTo: newClipButton)
    return true
  }
  private weak var newClipButton: NSButton?
  private let shelfSurface = ShelfSurface(cornerRadius: 20)
  private let contentTypeNotch = NSView()
  private var contentTypeNotchHeightConstraint: NSLayoutConstraint?
  private let contentTypeScrollView = NSScrollView()
  private var displayOptionsObserver: NSObjectProtocol?
  private lazy var shelfControls = ShelfControls(
    model: viewModel, onCreate: { [weak self] in self?.createCollectionFromToolbar() },
    onEdit: { [weak self] in self?.editCollection(named: $0) }, onExport: { [weak self] in self?.exportCollection(named: $0) },
    onDelete: { [weak self] in self?.deleteCollection(named: $0) },
    onRevealCapture: { [weak self] in self?.focusSelectedCardForKeyboardNavigation() })

  private struct CardRenderContext {
    let items: [Clip]
    let revision: UInt
    let collectionNames: [String]
    let layout: CardLayout
    let canShowInClipboard: Bool
    let scope: String
    let arrangement: CardArrangement
  }

  private let initialCardRenderBudget = 12
  private let cardRenderPrefetchBuffer = 3
  private let cardRenderRetentionBuffer = 8
  private var currentCardRenderContext: CardRenderContext?

  init(viewModel: ShelfModel, onClose: @escaping () -> Void, onPreview: @escaping () -> Void = {}) {
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
    shelfSurface.pinEdges(to: self)
    contentTypeNotch.translatesAutoresizingMaskIntoConstraints = false
    contentTypeNotch.setAccessibilityIdentifier("shelf-type-notch")
    addSubview(contentTypeNotch)
    contentTypeScrollView.wantsLayer = true
    contentTypeScrollView.layer?.cornerRadius = 12
    contentTypeScrollView.layer?.masksToBounds = true
    contentTypeScrollView.configure(document: shelfControls.contentTypeRailView, border: .noBorder)
    contentTypeScrollView.translatesAutoresizingMaskIntoConstraints = false
    contentTypeNotch.addSubview(contentTypeScrollView)
    // Normally the notch hugs all nine icons. On a short display it can
    // scroll independently instead of stretching the shelf or clipping icons.
    let notchHeight = contentTypeNotch.heightAnchor.constraint(equalToConstant: shelfControls.contentTypeRailView.fittingSize.height)
    contentTypeNotchHeightConstraint = notchHeight
    notchHeight.priority = .defaultHigh
    let contourClearance = Metrics.panelCornerRadius + ShelfSurface.notchShoulderRadius
    NSLayoutConstraint.activate([
      contentTypeNotch.leadingAnchor.constraint(equalTo: leadingAnchor), contentTypeNotch.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentTypeNotch.widthAnchor.constraint(equalToConstant: ShelfControls.contentTypeNotchWidth),
      contentTypeNotch.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -2 * contourClearance), notchHeight,
      contentTypeScrollView.leadingAnchor.constraint(equalTo: contentTypeNotch.leadingAnchor),
      contentTypeScrollView.trailingAnchor.constraint(equalTo: contentTypeNotch.trailingAnchor),
      contentTypeScrollView.topAnchor.constraint(equalTo: contentTypeNotch.topAnchor),
      contentTypeScrollView.bottomAnchor.constraint(equalTo: contentTypeNotch.bottomAnchor),
    ])

    searchControl.onTextChanged = { [weak self] in self?.viewModel.searchText = $0 }
    searchControl.onSubmit = { [weak self] in self?.viewModel.copySelected() }
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
    scrollView.verticalScroller = ShelfScroller()
    scrollView.horizontalScroller = ShelfScroller()
    scrollView.configure(document: cardsDocument, vertical: true, autohides: true, style: .overlay, border: .noBorder)
    scrollView.setContentHuggingPriority(.required, for: .vertical)
    scrollView.setContentCompressionResistancePriority(.required, for: .vertical)
    scrollView.onVisibleBoundsChanged = { [weak self] in
      guard let self else { return }
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
      equalTo: contentStack.leadingAnchor, constant: ShelfControls.contentTypeRailAllowance)
    headerLeadingConstraint = headerStack.leadingAnchor.constraint(
      equalTo: headerContainer.leadingAnchor, constant: ShelfControls.contentTypeRailAllowance + Metrics.cardInset)
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
      case .items, .collections: self.handleVisibleItemsChanged()
      case .search: self.syncSearchFieldFromViewModel()
      case .selection:
        guard self.renderedItemsMatchModel else { return }
        self.updateSelection(scrollSelection: !self.updatesSelectionFromPointer)
      case .sort: self.shelfControls.refresh()
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
    PinboardStyle.color(forCollectionNamed: name, overrideHex: viewModel.collectionColorHex(named: name))
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

  private func currentCardLayout(viewportWidth: CGFloat? = nil) -> CardLayout {
    if viewModel.usesCardShelf {
      // Overlay scrollers occupy the viewport; legacy scrollers already reduce
      // it. Reserve the same bottom lane in both modes, including filtered views
      // that temporarily show the new-copy notice above the cards.
      let nativeGutter = max(0, scrollView.bounds.height - scrollView.contentView.frame.height)
      let scrollerClearance = max(0, 16 - nativeGutter)
      return .gallery(width: viewModel.shelfWidth, largerText: viewModel.largerShelfText).fittingGalleryHeight(
        scrollView.contentView.bounds.height - 8 - scrollerClearance)
    }
    let layout = CardLayout.compact.withLargerText(viewModel.largerShelfText)
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
    let typeRailInset = viewModel.usesCardShelf ? 0 : ShelfControls.contentTypeRailAllowance
    scrollViewLeadingConstraint?.constant = typeRailInset
    headerLeadingConstraint?.constant = typeRailInset + Metrics.cardInset
    shelfSurface.cornerRadius = viewModel.usesCardShelf ? 28 : 20
    bottomSafeInset = viewModel.usesCardShelf ? 14 : 20
    mainStack?.edgeInsets = contentInsets()
    updateShelfChromeLayout()
    scrollView.hasHorizontalScroller = viewModel.usesCardShelf
    scrollView.hasVerticalScroller = !viewModel.usesCardShelf
    scrollView.autohidesScrollers = true
    // Keep the scroll view inside its parent so the native thumb remains hittable.
    scrollViewTrailingConstraint?.constant = 0
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
    let button = ShelfIconButton(title: "", target: self, action: action)
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
    let focusedTarget = focusedCard.map { (id: $0.representedItemID, index: $0.representedIndex) }
    let previousSlots = cardSlots
    cardSlots = [:]
    currentCardRenderContext = nil
    keyboardColumnX = nil
    lastScrollViewportSize = .zero

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
        canShowInClipboard: canShowInClipboard, scope: currentScope,
        arrangement: CardArrangement(items: items, base: layout, spacing: ShelfStyle.cardSpacing, horizontal: viewModel.usesCardShelf))
      let initial = initialCardRenderRange(itemCount: items.count)
      let retained = retainedCardIndexRange(around: initial)
      let indexes = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
      for slot in previousSlots.values {
        guard let index = indexes[slot.representedItemID],
          retained.contains(index) || index == viewModel.selectedIndex || slot.representedItemID == focusedTarget?.id,
          let context = currentCardRenderContext, slot.card.canReuse(with: cardConfiguration(at: index, context: context))
        else { continue }
        slot.card.updateIndex(index)
        cardSlots[index] = slot
      }
      sizeItemsDocument()
      renderCards(in: initial)
    }

    // Surviving cards keep both their slot and responder hierarchy. Only
    // discarded cards leave the document; there is no second reuse pool.
    for slot in previousSlots.values where !cardSlots.values.contains(where: { $0 === slot }) { slot.removeFromSuperview() }
    updateSelection(scrollSelection: viewportAnchor == nil)
    restoreFocusedCardIfNeeded(focusedTarget)
    if let viewportAnchor, let context = currentCardRenderContext,
      let index = context.items.firstIndex(where: { $0.id == viewportAnchor.id })
    {
      let frame = cardSlotFrame(at: index)
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
    renderCards(in: visibleRange)
    pruneRenderedCards(outside: retainedCardIndexRange(around: visibleRange))
  }

  private func visibleCardIndexRange() -> Range<Int> {
    arrangement?.visibleRange(in: scrollView.contentView.bounds, inset: Metrics.cardInset, prefetch: cardRenderPrefetchBuffer) ?? 0..<0
  }

  private func renderCards(in range: Range<Int>) {
    guard let context = currentCardRenderContext, !range.isEmpty else { return }

    let clampedRange = max(0, range.lowerBound)..<min(context.items.count, range.upperBound)
    guard !clampedRange.isEmpty else { return }

    for index in clampedRange {
      guard cardSlots[index] == nil else { continue }

      let item = context.items[index]
      let card = CardView(configuration: cardConfiguration(at: index, context: context), thumbnail: nil, index: index)
      let slot = CardSlot(card: card, frame: cardSlotFrame(at: index))
      cardSlots[index] = slot
      cardsDocument.addSubview(slot)
      configureCardCallbacks(card, slot: slot)
      applyCurrentCardState(card, index: index)
      if !card.hasThumbnail {
        viewModel.loadThumbnail(for: item) { [weak slot, weak card] thumbnail in
          guard let slot, let card, slot.card === card, let thumbnail else { return }
          card.updateThumbnail(thumbnail)
        }
      }
    }

  }

  private func cardConfiguration(at index: Int, context: CardRenderContext) -> CardConfiguration {
    CardConfiguration(
      item: context.items[index], layout: context.arrangement.entries[index].layout, collectionNames: context.collectionNames,
      canShowInClipboard: context.canShowInClipboard)
  }

  private func renderCardIfNeeded(at index: Int) {
    guard index >= 0, index < cardItemCount else { return }
    renderCards(in: index..<(index + 1))
  }

  private func cardView(at index: Int) -> CardView? { cardSlots[index]?.card }

  private func retainedCardIndexRange(around renderedRange: Range<Int>) -> Range<Int> {
    let itemCount = cardItemCount
    guard itemCount > 0 else { return 0..<0 }
    let lowerBound = max(0, renderedRange.lowerBound - cardRenderRetentionBuffer)
    let upperBound = min(itemCount, renderedRange.upperBound + cardRenderRetentionBuffer)
    return lowerBound..<max(lowerBound, upperBound)
  }

  private func pruneRenderedCards(outside retainedRange: Range<Int>) {
    let activeIndex = viewModel.selectedIndex
    let focusedIndex = focusedCard?.representedIndex
    let removableIndexes = cardSlots.keys.filter { index in !retainedRange.contains(index) && index != activeIndex && index != focusedIndex
    }
    for index in removableIndexes { cardSlots.removeValue(forKey: index)?.removeFromSuperview() }
  }

  private var focusedCard: CardView? {
    guard let responder = window?.firstResponder as? NSView else { return nil }
    return cardViews.first { responder === $0 || responder.isDescendant(of: $0) }
  }

  private func positionRenderedCardSlots() { for (index, slot) in cardSlots { slot.frame = cardSlotFrame(at: index) } }

  private func cardSlotFrame(at index: Int) -> NSRect {
    guard let arrangement, arrangement.entries.indices.contains(index) else { return .zero }
    let x =
      arrangement.horizontal
      ? Metrics.cardInset : verticalCardMinXInContent(width: arrangement.size.width, viewportWidth: cardsDocument.bounds.width)
    return arrangement.entries[index].frame.offsetBy(dx: x, dy: Metrics.cardInset)
  }

  private func configureCardCallbacks(_ card: CardView, slot: CardSlot) {
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

  private func performCardCommand(_ command: ClipCommand, at index: Int) {
    if let mode = command.selectionMode { viewModel.selectItem(at: index, mode: mode) }
    performCommand(command, at: index)
  }

  /// All input surfaces use this handler; only editor/window operations belong to the view.
  func performCommand(_ command: ClipCommand, at cardIndex: Int? = nil) {
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
    arrangement?.distance(from: first, to: second) ?? abs(first - second)
  }

  private func restoreFocusedCardIfNeeded(_ target: (id: UUID, index: Int)?) {
    guard let target else { return }
    renderCardIfNeeded(at: target.index)
    let focusedCard = cardViews.first { $0.representedItemID == target.id } ?? cardView(at: target.index)
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

  private func flushDeferredVisualReloads() {
    if pendingItemReload {
      pendingItemReload = false
      reloadItems()
    }
    shelfControls.refresh()
  }

  private func applyCurrentCardState(_ card: CardView, index: Int) {
    let isVisuallyExpanded = index == viewModel.selectedIndex
    card.setSelectionState(
      active: isVisuallyExpanded, selected: viewModel.isItemSelected(at: index), selectionCount: viewModel.selectedItemCount)
  }

  private func updateSelection(scrollSelection: Bool = true) {
    shelfControls.refresh()
    renderCardIfNeeded(at: viewModel.selectedIndex)

    var activeCard: CardView?
    for card in cardViews {
      let index = card.representedIndex
      applyCurrentCardState(card, index: index)
      if index == viewModel.selectedIndex { activeCard = card }
    }

    let shouldSuppressSelectionScroll = selectionScrollSuppressionCount > 0
    if shouldSuppressSelectionScroll { selectionScrollSuppressionCount -= 1 }

    if let activeCard, scrollSelection, !shouldSuppressSelectionScroll { scrollCardIntoView(activeCard) }
  }

  private func scrollCardIntoView(_ card: CardView) {
    guard scrollView.documentView === cardsDocument else { return }
    guard card.window != nil else { return }
    scrollView.layoutSubtreeIfNeeded()
    cardsDocument.layoutSubtreeIfNeeded()

    let frame = cardSlotFrame(at: card.representedIndex)
    let paddedFrame = frame.insetBy(dx: viewModel.usesCardShelf ? -4 : 0, dy: viewModel.usesCardShelf ? 0 : -ShelfStyle.cardSpacing)
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

    let alert = NSAlert(
      title: "Rename Clip", message: "Give this clip a searchable title. Leave it blank to clear the title.", buttons: ["Save", "Cancel"])
    alert.accessoryView = input
    alert.window.initialFirstResponder = input

    presentSheet(alert) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.viewModel.updateTitle(itemID: item.id, to: input.stringValue)
    }
  }

  private func emptyStateView() -> NSView {
    let width = max(1, scrollView.contentView.bounds.width)
    let height = max(Metrics.minimumEmptyStateHeight, scrollView.contentView.bounds.height)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let copy = emptyStateCopy()
    let searching = !viewModel.searchText.isEmpty || viewModel.contentFilter != nil
    let symbol = searching ? "magnifyingglass" : (viewModel.isCapturePaused ? "pause.circle" : "tray")
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = ShelfStyle.secondaryText
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
    icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let title = NativeUI.label(
      copy.title, wrap: true, font: .systemFont(ofSize: 19, weight: .semibold), color: .labelColor, alignment: .center, maxLines: 2)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let detail = NativeUI.label(
      copy.detail, wrap: true, font: .systemFont(ofSize: 13), color: ShelfStyle.secondaryText, alignment: .center, maxLines: 3)
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

  private func sizeItemsDocument() {
    guard let arrangement else { return }
    let viewport = scrollView.contentView.bounds.size
    let trailing = arrangement.horizontal ? Metrics.cardInset : verticalCardTrailingInset
    cardsDocument.frame = NSRect(
      x: 0, y: 0, width: max(viewport.width, arrangement.size.width + Metrics.cardInset + trailing),
      height: max(viewport.height, arrangement.size.height + Metrics.cardInset * 2))
    lastScrollViewportSize = viewport
    positionRenderedCardSlots()
    if !arrangement.horizontal {
      cardsDocument.needsLayout = true
      cardsDocument.layoutSubtreeIfNeeded()
    }
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
      bodyLeadingInset: viewModel.usesCardShelf ? 0 : ShelfControls.contentTypeRailAllowance)
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

    sizeItemsDocument()
    renderCardsNearVisibleViewport()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    replaceTrackingArea(&pointerTrackingArea, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect])
  }

  override func mouseEntered(with event: NSEvent) { updateHoverForPointer(atWindowLocation: event.locationInWindow) }

  override func mouseMoved(with event: NSEvent) { updateHoverForPointer(atWindowLocation: event.locationInWindow) }

  override func mouseExited(with event: NSEvent) { clearPointerHoverStates() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    shelfSurface.refreshAppearance()
  }

  func focusSearch() { searchControl.focus() }

  @discardableResult func clearSearchForKeyboardCancel() -> Bool { searchControl.clear() }

  private func startSearchFromShelf(_ text: String) { searchControl.startSearch(with: text) }

  func setBottomSafeInset(_ inset: CGFloat) {
    bottomSafeInset = max(viewModel.usesCardShelf ? 12 : Metrics.minimumBottomInset, inset)
    mainStack?.edgeInsets = contentInsets()
    needsLayout = true
  }

  var visibleCardPageStep: Int {
    if let arrangement, !arrangement.horizontal, !arrangement.entries.isEmpty {
      let visible = scrollView.contentView.bounds
      return max(1, arrangement.entries.filter { $0.frame.maxY > visible.minY && $0.frame.minY < visible.maxY }.count - 1)
    }
    let layout = currentCardLayout()
    let span = (viewModel.usesCardShelf ? layout.width : layout.height) + ShelfStyle.cardSpacing
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
    focusSearch()
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
      guard !ShelfMotion.reducesMotion else { continue }
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

  private func moveSelectionFromFocusedCard(_ delta: Int, extend: Bool = false) {
    keyboardColumnX = nil
    let count = viewModel.visibleItems.count
    guard !extend || count > 0 else { return }
    claimKeyboardCardSelection()
    if extend {
      viewModel.selectItem(at: max(0, min(count - 1, viewModel.selectedIndex + delta)), mode: .range)
    } else {
      viewModel.moveSelection(delta)
    }
    focusSelectedCard()
  }

  private func navigateVerticalRow(_ direction: Int, extend: Bool) {
    guard let arrangement, !arrangement.horizontal, arrangement.entries.indices.contains(viewModel.selectedIndex) else {
      moveSelectionFromFocusedCard(direction, extend: extend)
      return
    }
    let index = viewModel.selectedIndex
    if keyboardColumnX == nil { keyboardColumnX = arrangement.entries[index].frame.midX }
    let target = arrangement.verticalNeighbor(of: index, direction: direction, preferredX: keyboardColumnX)
    claimKeyboardCardSelection()
    viewModel.selectItem(at: target, mode: extend ? .range : .replace)
    focusSelectedCard()
  }

  func navigate(_ action: ShelfNavigation, fromPanel: Bool = false) {
    if fromPanel {
      keyboardColumnX = nil
      claimKeyboardCardSelection()
    }
    switch action {
    case .move(let delta, let extend), .page(let delta, let extend):
      let step: Int
      if case .page = action { step = delta * visibleCardPageStep } else { step = delta }
      moveSelectionFromFocusedCard(step, extend: extend)
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
    guard presentedMenuWindow == nil, ClipDragContext.itemID == nil else { return }
    let pointInViewport = scrollView.contentView.convert(location, from: nil)
    let target: CardView?
    if scrollView.contentView.bounds.contains(pointInViewport) {
      let pointInDocument = cardsDocument.convert(location, from: nil)
      target = cardSlots.values.first { $0.frame.contains(pointInDocument) }?.card
    } else {
      target = nil
    }

    if let target {
      target.setHoverState(true, notifySelection: true, mouseLocation: location)
      if viewModel.selectedItemCount <= 1, viewModel.selectedIndex != target.representedIndex {
        let cardHadKeyboardFocus = focusedCard != nil
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
    let index = viewModel.selectedIndex
    renderCardIfNeeded(at: index)
    window?.makeFirstResponder(cardView(at: index) ?? self)
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
    let panel = ArchivePicker.panel(exporting: true, collection: collectionName)

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

  private func requestCollectionCreation(completion: @escaping (PinboardRequest) -> Void) {
    requestCollectionDetails(initialName: "", initialColor: .systemRed, initialIcon: PinboardIcon.defaultSymbol, completion: completion)
  }

  private func requestCollectionEdit(named collectionName: String, completion: @escaping (PinboardRequest) -> Void) {
    requestCollectionDetails(
      initialName: collectionName, initialColor: collectionColor(forCollectionNamed: collectionName),
      initialIcon: viewModel.collectionIcon(named: collectionName) ?? PinboardIcon.defaultSymbol, completion: completion)
  }

  private func requestCollectionDetails(
    initialName: String, initialColor: NSColor, initialIcon: String, completion: @escaping (PinboardRequest) -> Void
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
    let noun = count == 1 ? "clip" : "clips"
    let alert = NSAlert(
      title: "Delete \(collectionName)?",
      message: count > 0
        ? "This permanently removes \(count) \(noun) in this Pinboard from clipboard history. It cannot be undone."
        : "This removes the empty Pinboard.", buttons: ["Cancel", "Delete Pinboard"])
    alert.buttons[1].hasDestructiveAction = true
    presentSheet(alert) { response in if response == .alertSecondButtonReturn { completion() } }
  }
}
