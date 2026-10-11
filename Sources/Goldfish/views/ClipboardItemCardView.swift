import AppKit

final class ClipboardItemCardView: NSView, NSDraggingSource {
  private enum Metrics { static let dragThreshold: CGFloat = 4 }
  private enum Palette {
    static var border: CGColor { ClipboardShelfStyle.clipBorder.cgColor }
    static var selectedBorder: CGColor { NSColor.controlAccentColor.cgColor }
    static var cardSurface: CGColor { ClipboardShelfStyle.clipSurface.cgColor }
  }
  var onCommand: (ClipboardCardCommand) -> Void = { _ in }
  var onSelect: (Int, ClipboardSelectionMode) -> Void = { _, _ in }
  var onHover: (Int, NSPoint?) -> Bool = { _, _ in true }
  var onHoverExit: (Int) -> Void = { _ in }
  var onNavigate: (ClipboardCardNavigation) -> Void = { _ in }
  var onPasteboardWriters: (Int) -> [NSPasteboardWriting] = { _ in [] }
  var onStartSearch: (String) -> Void = { _ in }
  var onLiftStateChanged: (Bool) -> Void = { _ in }

  private var index: Int
  private let itemID: UUID
  private let contentFormatter = ClipboardItemCardContentFormatter()
  private let configuration: ClipboardCardConfiguration
  private let layout: ClipboardItemCardLayout
  private let itemKind: ClipboardItemKind
  private let presentationKind: ClipboardItemKind
  private let itemIsPinned: Bool
  private let canShowInClipboard: Bool
  private let itemSourceAppName: String?
  private let itemSourceAppBundleID: String?
  private let itemCollectionName: String?
  private let collectionNames: [String]
  private let contentView = ClipboardCardSurfaceView()
  private weak var previewContent: ClipboardCardPreviewView?
  var renderedTextScale: CGFloat { layout.textScale }
  private let selectionOutline = CALayer()
  let hasThumbnail: Bool
  private var isActiveSelection = false
  private var isSelected = false
  private var selectedGroupCount = 1
  private var isHovered = false
  private var carouselDistance: Int?
  private var isKeyboardFocused = false
  private var isFocusingFromPointer = false
  private var mouseDownLocation: NSPoint?

  var representedItemID: UUID { itemID }

  var representedIndex: Int { index }

  func canReuse(with configuration: ClipboardCardConfiguration) -> Bool { self.configuration == configuration }

  func updateIndex(_ index: Int) {
    self.index = index
    previewContent?.index = index
    isHovered = false
    mouseDownLocation = nil
    refreshRelativeDate()
  }

  func refreshRelativeDate() { previewContent?.needsDisplay = true }

  init(configuration: ClipboardCardConfiguration, thumbnail: NSImage?, index: Int) {
    let item = configuration.item
    hasThumbnail = thumbnail != nil
    let normalizedItemCollection = ClipboardCollectionDefaults.normalizedName(item.collectionName)
    self.index = index
    self.itemID = item.id
    self.configuration = configuration
    self.layout = configuration.layout
    self.itemKind = item.kind
    self.presentationKind = item.presentationKind
    self.itemIsPinned = item.isPinned
    self.canShowInClipboard = configuration.canShowInClipboard
    self.itemSourceAppName = Self.presentSourceText(item.sourceApp)
    self.itemSourceAppBundleID = Self.presentSourceText(item.sourceAppBundleId)
    self.itemCollectionName = normalizedItemCollection
    self.collectionNames = configuration.collectionNames.compactMap { ClipboardCollectionDefaults.normalizedName($0) }
    super.init(frame: .zero)
    configure(item: item, thumbnail: thumbnail)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setSelected(_ selected: Bool) {
    setSelectionState(active: selected, selected: selected, selectionCount: selected ? 1 : selectedGroupCount)
  }

  func setSelectionState(active: Bool, selected: Bool, selectionCount: Int) {
    isActiveSelection = active
    isSelected = selected
    selectedGroupCount = max(1, selectionCount)
    let emphasized = active || isKeyboardFocused || isHovered
    animateLayerChanges {
      self.updateSurfaceAppearance()
      self.applyCardShadow(emphasized: emphasized)
    }
    updateCarouselTransform()
    onLiftStateChanged(emphasized)
    setAccessibilityValue(selected ? "Selected" : "Not selected")
  }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    selectionOutline.frame = bounds
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSurfaceAppearance()
  }

  private func updateSurfaceAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      selectionOutline.frame = bounds
      contentView.layer?.backgroundColor = Palette.cardSurface
      selectionOutline.borderColor = isSelected || isKeyboardFocused ? Palette.selectedBorder : Palette.border
      selectionOutline.borderWidth = isKeyboardFocused ? 2 : (isSelected ? 1.5 : (ClipboardShelfStyle.increasedContrast ? 1 : 0.5))
    }
  }

  private func animateLayerChanges(_ changes: () -> Void) {
    CATransaction.begin()
    if window == nil {
      CATransaction.setDisableActions(true)
    } else {
      CATransaction.setAnimationDuration(ClipboardShelfMotion.duration(0.16))
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    }
    changes()
    CATransaction.commit()
  }

  private func applyCardShadow(emphasized: Bool) {
    layer?.shadowOpacity = isHovered ? 0.20 : (emphasized ? 0.10 : 0.045)
    layer?.shadowRadius = isHovered ? 14 : (emphasized ? 8 : 4)
    layer?.shadowOffset = NSSize(width: 0, height: isHovered ? -5 : -2)
  }

  func setCarouselDistance(_ distance: Int?) {
    guard carouselDistance != distance else { return }
    carouselDistance = distance
    updateCarouselTransform()
  }

  private func updateCarouselTransform() {
    guard let layer else { return }
    let reduced = ClipboardShelfMotion.reducesMotion
    let distance = carouselDistance.map(abs)
    let scale: CGFloat = reduced ? 1 : (isHovered ? 1.012 : (distance == 1 ? 0.995 : (distance == 2 ? 0.998 : 1)))
    let lift: CGFloat = !reduced && isHovered ? -1 : 0
    // Animate the paint layer around its center, keeping layout and hit targets fixed.
    var transform = CATransform3DMakeTranslation(
      (0.5 - layer.anchorPoint.x) * bounds.width * (1 - scale), (0.5 - layer.anchorPoint.y) * bounds.height * (1 - scale) + lift, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    guard !CATransform3DEqualToTransform(layer.transform, transform) else { return }
    let current = layer.presentation()?.transform ?? layer.transform
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = transform
    CATransaction.commit()
    layer.removeAnimation(forKey: "carousel")
    guard window != nil, !reduced else { return }
    let animation = CASpringAnimation(keyPath: "transform")
    animation.fromValue = NSValue(caTransform3D: current)
    animation.toValue = NSValue(caTransform3D: transform)
    animation.mass = 1
    animation.stiffness = 430
    animation.damping = 34
    animation.duration = 0.34
    layer.add(animation, forKey: "carousel")
  }

  override var acceptsFirstResponder: Bool { true }

  func focusFromPointer() {
    isFocusingFromPointer = true
    window?.makeFirstResponder(self)
    isFocusingFromPointer = false
  }

  override func becomeFirstResponder() -> Bool {
    isKeyboardFocused = true
    if !isFocusingFromPointer { onSelect(index, .activate) }
    setSelectionState(active: isActiveSelection, selected: isSelected, selectionCount: selectedGroupCount)
    return true
  }

  override func resignFirstResponder() -> Bool {
    isKeyboardFocused = false
    setSelectionState(active: isActiveSelection, selected: isSelected, selectionCount: selectedGroupCount)
    return true
  }

  override func keyDown(with event: NSEvent) {
    let relevantModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if relevantModifiers == [.command, .shift] {
      switch event.keyCode {
      case 9, 36, 76: onCommand(.pastePlainText)
      default: super.keyDown(with: event)
      }
      return
    }
    if relevantModifiers == .command {
      switch event.keyCode {
      case 0: onNavigate(.all)
      case 5: onCommand(.showInClipboard)
      case 6: onCommand(.undoDelete)
      case 8: onCommand(.copy)
      case 14 where canEditText: onCommand(.editText)
      case 15: onCommand(.rename)
      case 16: onCommand(.preview)
      case 31 where canOpen: onCommand(.open)
      default: super.keyDown(with: event)
      }
      return
    }
    if relevantModifiers == .shift {
      switch event.keyCode {
      case 36, 76: onCommand(.pastePlainText)
      case 115: onNavigate(.endpoint(last: false, extend: true))
      case 116: onNavigate(.page(-1, extend: true))
      case 119: onNavigate(.endpoint(last: true, extend: true))
      case 121: onNavigate(.page(1, extend: true))
      case 123 where layout.usesGalleryStyle: onNavigate(.move(-1, extend: true))
      case 124 where layout.usesGalleryStyle: onNavigate(.move(1, extend: true))
      case 126: onNavigate(.vertical(-1, extend: true))
      case 125: onNavigate(.vertical(1, extend: true))
      default: super.keyDown(with: event)
      }
      return
    }

    switch event.keyCode {
    case 36, 76: onCommand(.paste)
    case 49: if canPreview { onCommand(.preview) } else { onCommand(.paste) }
    case 51, 117: onCommand(.delete)
    case 115: onNavigate(.endpoint(last: false, extend: false))
    case 116: onNavigate(.page(-1, extend: false))
    case 119: onNavigate(.endpoint(last: true, extend: false))
    case 121: onNavigate(.page(1, extend: false))
    case 123 where layout.usesGalleryStyle: onNavigate(.move(-1, extend: false))
    case 124 where layout.usesGalleryStyle: onNavigate(.move(1, extend: false))
    case 126: onNavigate(.vertical(-1, extend: false))
    case 125: onNavigate(.vertical(1, extend: false))
    default: if let text = shelfSearchText(from: event) { onStartSearch(text) } else { super.keyDown(with: event) }
    }
  }

  override func accessibilityPerformPress() -> Bool {
    onSelect(index, .replace)
    window?.makeFirstResponder(self)
    return true
  }

  func setHoverState(_ hovered: Bool, notifySelection: Bool, mouseLocation: NSPoint? = nil) {
    let wasHovered = isHovered
    if hovered && notifySelection && !wasHovered { guard onHover(index, mouseLocation) else { return } }
    isHovered = hovered
    if wasHovered != hovered {
      setSelectionState(active: isActiveSelection, selected: isSelected, selectionCount: selectedGroupCount)
      if !hovered { onHoverExit(index) }
    }
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      mouseDownLocation = nil
      onCommand(.paste)
    } else {
      mouseDownLocation = convert(event.locationInWindow, from: nil)
      focusFromPointer()
      onSelect(index, selectionMode(from: event.modifierFlags))
      setHoverState(true, notifySelection: true, mouseLocation: event.locationInWindow)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownLocation else { return }
    let current = convert(event.locationInWindow, from: nil)
    guard hypot(current.x - start.x, current.y - start.y) >= Metrics.dragThreshold else { return }

    mouseDownLocation = nil
    let writers = onPasteboardWriters(index)
    let dragWriters = writers.isEmpty ? [internalDragPasteboardItem()] : writers
    onSelect(index, .activate)
    ClipboardCardDragContext.itemID = itemID

    let preview = dragPreviewImage()
    let dragItems = dragWriters.enumerated().map { offset, writer in
      let draggingItem = NSDraggingItem(pasteboardWriter: writer)
      let offsetAmount = CGFloat(offset) * 4
      let frame = NSRect(x: bounds.minX + offsetAmount, y: bounds.minY - offsetAmount, width: bounds.width, height: bounds.height)
      draggingItem.setDraggingFrame(frame, contents: preview)
      return draggingItem
    }

    let session = beginDraggingSession(with: dragItems, event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
    if dragItems.count > 1 { session.draggingFormation = .pile }
  }

  private func internalDragPasteboardItem() -> NSPasteboardItem {
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(itemID.uuidString, forType: ClipboardItemDragPasteboard.itemIDType)
    return pasteboardItem
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    if ClipboardCardDragContext.itemID == itemID { ClipboardCardDragContext.itemID = nil }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    onSelect(index, isSelected ? .activate : .replace)
    return contextMenu()
  }

  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    addMenuItem(selectedGroupCount > 1 ? "Paste Selection" : "Paste", command: .paste, to: menu)
    addMenuItem(selectedGroupCount > 1 ? "Copy Selection" : "Copy", command: .copy, to: menu)
    if canPlainText {
      addMenuItem("Paste Plain Text", command: .pastePlainText, to: menu)
      addMenuItem("Copy Plain Text", command: .copyPlainText, to: menu)
    }
    if selectedGroupCount > 1 {
      addMenuItem("Paste Selection as Text", command: .pasteSelectionText, to: menu)
      addMenuItem("Copy Selection as Text", command: .copySelectionText, to: menu)
    }
    if canShowInClipboard { addMenuItem("Show in Clipboard", command: .showInClipboard, to: menu) }
    menu.addItem(.separator())
    if canPreview { addMenuItem("Quick Look", command: .preview, to: menu) }
    if canOpen { addMenuItem("Open", command: .open, to: menu) }
    if canReveal { addMenuItem("Reveal in Finder", command: .reveal, to: menu) }
    addMenuItem("Rename…", command: .rename, to: menu)
    if canEditText { addMenuItem("Edit Text…", command: .editText, to: menu) }
    if canRotateImage { addMenuItem("Rotate Image", command: .rotateImage, to: menu) }
    if canExtractImageText { addMenuItem("Extract Text", command: .extractImageText, to: menu) }
    menu.addItem(.separator())
    addMenuItem(itemIsPinned ? "Unpin" : "Pin", command: .togglePin, to: menu)
    addCollectionMenu(to: menu)
    addCaptureRulesMenu(to: menu)
    menu.addItem(NSMenuItem.separator())
    addMenuItem(selectedGroupCount > 1 ? "Delete Selection" : "Delete", command: .delete, to: menu)
    return menu
  }

  private func addCollectionMenu(to menu: NSMenu) {
    if availableCollectionNames().isEmpty {
      addMenuItem("New Pinboard…", command: .createCollection, to: menu)
      return
    }
    let parent = NSMenuItem(title: "Add to Pinboard", action: nil, keyEquivalent: "")
    let submenu = collectionAssignmentMenu()
    menu.addItem(parent)
    menu.setSubmenu(submenu, for: parent)
  }

  private func collectionAssignmentMenu() -> NSMenu {
    let submenu = NSMenu(title: "Add to Pinboard")
    submenu.autoenablesItems = false

    for name in availableCollectionNames() {
      let item = addMenuItem(name, command: .assignToCollection(name), to: submenu)
      if itemCollectionName == name { item.state = .on }
    }

    submenu.addItem(NSMenuItem.separator())
    addMenuItem("New Pinboard…", command: .createCollection, to: submenu)

    if itemCollectionName?.clipboardTrimmed.isEmpty == false {
      submenu.addItem(NSMenuItem.separator())
      addMenuItem("Remove from Pinboard", command: .assignToCollection(nil), to: submenu)
    }

    return submenu
  }

  private func addCaptureRulesMenu(to menu: NSMenu) {
    let parent = NSMenuItem(title: "Capture Rules", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Capture Rules")
    submenu.autoenablesItems = false

    let ignoreSource = addMenuItem(ignoreSourceTitle(), command: .ignoreSourceApp, to: submenu)
    ignoreSource.isEnabled = itemSourceAppName != nil || itemSourceAppBundleID != nil

    addMenuItem("Ignore \(contentFormatter.kindLabel(for: itemKind)) Items", command: .ignoreKind, to: submenu)

    menu.addItem(parent)
    menu.setSubmenu(submenu, for: parent)
  }

  private func ignoreSourceTitle() -> String {
    if let itemSourceAppName { return "Ignore \(itemSourceAppName)" }
    if let itemSourceAppBundleID { return "Ignore \(itemSourceAppBundleID)" }
    return "Ignore Source App"
  }

  private static func presentSourceText(_ value: String?) -> String? {
    guard let text = value?.clipboardTrimmed, !text.isEmpty else { return nil }
    return text
  }

  private func availableCollectionNames() -> [String] {
    var names: [String] = []
    var seen = Set<String>()
    for candidate in collectionNames {
      guard let name = ClipboardCollectionDefaults.normalizedName(candidate) else { continue }
      let key = name.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      names.append(name)
    }
    return names
  }

  @discardableResult private func addMenuItem(_ title: String, command: ClipboardCardCommand, to menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = command
    item.isEnabled = true
    switch command {
    case .paste:
      item.keyEquivalent = "\r"
      item.keyEquivalentModifierMask = []
    case .copy: item.keyEquivalent = "c"
    case .pastePlainText:
      item.keyEquivalent = "\r"
      item.keyEquivalentModifierMask = .shift
    case .preview: item.keyEquivalent = "y"
    case .open: item.keyEquivalent = "o"
    case .rename: item.keyEquivalent = "r"
    case .editText: item.keyEquivalent = "e"
    case .togglePin: item.keyEquivalent = "p"
    case .delete:
      item.keyEquivalent = "\u{8}"
      item.keyEquivalentModifierMask = []
    default: break
    }
    menu.addItem(item)
    return item
  }

  private var canOpen: Bool {
    switch presentationKind {
    case .url, .file, .image, .pdf, .audio, .video: return true
    case .text, .richText, .unknown, .color, .code: return false
    }
  }

  private var canPreview: Bool {
    switch itemKind {
    case .text, .url, .image, .richText, .file, .pdf, .audio, .unknown, .color, .code, .video: return true
    }
  }

  private var canEditText: Bool { itemKind == .text || itemKind == .code }

  private var canRotateImage: Bool { itemKind == .image }

  private var canExtractImageText: Bool { itemKind == .image }

  private var canPlainText: Bool {
    switch itemKind {
    case .url, .image, .richText, .file, .pdf, .audio, .color, .video: return true
    case .text, .unknown, .code: return false
    }
  }

  private var canReveal: Bool {
    switch itemKind {
    case .file, .image, .pdf, .audio, .video: return true
    case .text, .richText, .url, .unknown, .color, .code: return false
    }
  }

  private var verticalHeaderCornerRadius: CGFloat { layout.cornerRadius }

  @objc private func performMenuCommand(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? ClipboardCardCommand else { return }
    onCommand(command)
  }

  private func configure(item: ClipboardItem, thumbnail: NSImage?) {

    wantsLayer = true
    frame.size = NSSize(width: layout.width, height: layout.height)
    layer?.cornerRadius = verticalHeaderCornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.08
    layer?.shadowRadius = 12
    layer?.shadowOffset = NSSize(width: 0, height: 3)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityHelp(contentFormatter.accessibilityHelpText())
    // A clip is one navigable item. Its clipped preview is not a separate set
    // of invisible VoiceOver stops; Quick Look exposes the complete content.
    setAccessibilityChildren([])
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "Select and preview") { [weak self] in
        guard let self else { return false }
        self.onSelect(self.index, .replace)
        self.onCommand(.preview)
        return true
      },
      NSAccessibilityCustomAction(name: "Copy") { [weak self] in
        guard let self else { return false }
        self.onCommand(.copy)
        return true
      },
      NSAccessibilityCustomAction(name: item.isPinned ? "Unpin" : "Pin") { [weak self] in
        guard let self else { return false }
        self.onCommand(.togglePin)
        return true
      },
      NSAccessibilityCustomAction(name: "Quick Look") { [weak self] in
        guard let self else { return false }
        self.onCommand(.preview)
        return true
      },
    ])
    focusRingType = .none

    contentView.wantsLayer = true
    contentView.layer?.cornerRadius = verticalHeaderCornerRadius
    contentView.layer?.cornerCurve = .continuous
    contentView.layer?.masksToBounds = true
    contentView.frame = bounds
    contentView.autoresizingMask = [.width, .height]
    addSubview(contentView)
    selectionOutline.cornerRadius = verticalHeaderCornerRadius
    selectionOutline.cornerCurve = .continuous
    selectionOutline.zPosition = 10
    layer?.addSublayer(selectionOutline)

    let preview = ClipboardCardPreviewView(item: item, thumbnail: thumbnail, layout: layout, index: index)
    let counts = preview.textStatistics.map { ", " + $0.accessibilityDescription } ?? ""
    setAccessibilityLabel(contentFormatter.accessibilityTitle(for: item) + counts)
    preview.frame = contentView.bounds
    contentView.addSubview(preview)
    previewContent = preview
    frame.size = layout.size
    setSelected(false)
  }

  private func dragPreviewImage() -> NSImage {
    guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
    representation.size = bounds.size
    cacheDisplay(in: bounds, to: representation)

    let image = NSImage(size: bounds.size)
    image.addRepresentation(representation)
    return image
  }

}
