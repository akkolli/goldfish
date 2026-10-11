import AppKit

private final class ShelfMenuDocumentView: NSStackView { override var isFlipped: Bool { true } }

/// Small, explicit menu choices: no nested system menus or form-style arrows.
struct ShelfMenuChoice {
  let title: String
  var symbol = ""
  var tint: NSColor = .secondaryLabelColor
  var detail = ""
  var selected = false
  var enabled = true
  var disclosure = false
  var action: () -> Void
}

struct ShelfMenuSection {
  var title: String? = nil
  var choices: [ShelfMenuChoice]
}

final class ShelfFilterButton: NativeHoverButton {
  var symbol = "" {
    didSet {
      needsDisplay = true
      invalidateIntrinsicContentSize()
    }
  }
  var symbolTint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
  var detail = "" {
    didSet {
      needsDisplay = true
      invalidateIntrinsicContentSize()
    }
  }
  var showsChevron = true { didSet { invalidateIntrinsicContentSize() } }
  var active = false { didSet { needsDisplay = true } }
  var expanded = false {
    didSet {
      needsDisplay = true
      setAccessibilityExpanded(expanded)
    }
  }
  private let controlDimension: CGFloat

  init(label: String, symbol: String, target: AnyObject?, action: Selector?, controlSize: CGFloat = 30) {
    self.controlDimension = controlSize
    super.init(frame: .zero)
    self.title = label
    self.symbol = symbol
    self.target = target
    self.action = action
    isBordered = false
    focusRingType = .none
    font = .systemFont(ofSize: 12, weight: .medium)
    setAccessibilityRole(.popUpButton)
    heightAnchor.constraint(equalToConstant: controlSize).isActive = true
  }
  required init?(coder: NSCoder) { nil }
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }
  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, [36, 49, 125, 126].contains(event.keyCode) {
      performClick(nil)
      return
    }
    super.keyDown(with: event)
  }
  override var intrinsicContentSize: NSSize {
    let text = (title as NSString).size(withAttributes: [.font: font!]).width
    let detailWidth =
      detail.isEmpty
      ? 0 : (detail as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)]).width + 16
    return NSSize(
      width: title.isEmpty ? controlDimension : ceil(text + detailWidth + (symbol.isEmpty ? 0 : 21) + (showsChevron ? 15 : 0) + 20),
      height: controlDimension)
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(roundedRect: rect, xRadius: controlDimension / 3, yRadius: controlDimension / 3)
    shape.fill(
      with: active
        ? NSColor.controlAccentColor.withAlphaComponent(expanded ? 0.19 : 0.12)
        : NSColor.labelColor.withAlphaComponent(expanded || isHighlighted ? 0.12 : (isPointerInside ? 0.085 : 0.045)))
    if window?.firstResponder === self || ShelfStyle.increasedContrast {
      shape.stroke(
        with: (window?.firstResponder === self ? NSColor.controlAccentColor : .separatorColor),
        width: window?.firstResponder === self ? 1.5 : 1)
    }
    let ink: NSColor = active ? .controlAccentColor : .labelColor
    var x: CGFloat = title.isEmpty ? (bounds.width - 14) / 2 : 10
    if !symbol.isEmpty {
      shelfDrawSymbol(symbol, in: NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14), color: active ? ink : symbolTint)
      x += 21
    }
    guard !title.isEmpty else { return }
    var right = bounds.width - 10
    if showsChevron {
      shelfDrawSymbol("chevron.down", in: NSRect(x: right - 8, y: 11, width: 8, height: 8), color: ShelfStyle.secondaryText)
      right -= 15
    }
    if !detail.isEmpty {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: ShelfStyle.secondaryText,
      ]
      let size = (detail as NSString).size(withAttributes: attributes)
      let badge = NSRect(x: right - size.width - 10, y: 6, width: size.width + 10, height: 18)
      NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill(with: NSColor.labelColor.withAlphaComponent(0.055))
      (detail as NSString).draw(at: NSPoint(x: badge.minX + 5, y: 8), withAttributes: attributes)
      right = badge.minX - 6
    }
    (title as NSString).draw(
      in: NSRect(x: x, y: 7, width: max(0, right - x), height: 16),
      withAttributes: NativeUI.textAttributes(font: font!, color: ink, lineBreak: .byTruncatingTail))
  }
}

private final class ShelfMenuPanel: ClipEditorPanel {
  var handleKey: (NSEvent) -> Bool = { _ in false }
  var onPointerMoved: ((NSPoint) -> Void)?
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, handleKey(event) { return }
    super.sendEvent(event)
    if event.type == .mouseMoved || event.type == .scrollWheel { onPointerMoved?(event.locationInWindow) }
  }
}

final class ShelfMenuRow: NSButton {
  let choice: ShelfMenuChoice
  var onHover: (() -> Void)?
  private var tracking: NSTrackingArea?
  init(choice: ShelfMenuChoice, target: AnyObject?, action: Selector?) {
    self.choice = choice
    super.init(frame: .zero)
    title = choice.title
    self.target = target
    self.action = action
    isEnabled = choice.enabled
    isBordered = false
    focusRingType = .none
    font = .systemFont(ofSize: 13, weight: choice.selected ? .medium : .regular)
    setAccessibilityLabel(choice.title)
    setAccessibilityValue(choice.selected ? "Selected" : (choice.detail.isEmpty ? nil : choice.detail))
    if !choice.detail.isEmpty { setAccessibilityHelp("\(choice.detail) clips") }
    heightAnchor.constraint(equalToConstant: 36).isActive = true
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { isEnabled }
  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }
  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    replaceTrackingArea(&tracking, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect])
  }
  // A menu opening underneath a stationary pointer must not steal keyboard focus.
  override func mouseMoved(with event: NSEvent) { if isEnabled { onHover?() } }
  override func draw(_ dirtyRect: NSRect) {
    let focused = window?.firstResponder === self
    let rect = bounds.insetBy(dx: 0, dy: 1)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
    let tint: NSColor = choice.selected ? .controlAccentColor : .labelColor
    shape.fill(with: tint.withAlphaComponent(choice.selected ? (focused ? 0.17 : 0.10) : (focused || isHighlighted ? 0.065 : 0)))
    if focused && ShelfStyle.increasedContrast { shape.stroke(with: NSColor.controlAccentColor, width: 1) }
    let ink: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
    if !choice.symbol.isEmpty {
      let tile = NSRect(x: 7, y: 6, width: 24, height: 24)
      NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill(with: choice.tint.withAlphaComponent(isEnabled ? 0.10 : 0.04))
      shelfDrawSymbol(choice.symbol, in: tile.insetBy(dx: 5, dy: 5), color: isEnabled ? choice.tint : .disabledControlTextColor)
    }
    let detailWidth =
      choice.detail.isEmpty
      ? 0
      : (choice.detail as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width + 10
    (title as NSString).draw(
      in: NSRect(x: 41, y: 10, width: bounds.width - 68 - detailWidth, height: 17),
      withAttributes: NativeUI.textAttributes(font: font!, color: ink, lineBreak: .byTruncatingTail))
    if !choice.detail.isEmpty {
      (choice.detail as NSString).draw(
        in: NSRect(x: bounds.width - 23 - detailWidth, y: 11, width: detailWidth, height: 15),
        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ShelfStyle.secondaryText])
    }
    if choice.selected || choice.disclosure {
      shelfDrawSymbol(
        choice.selected ? "checkmark" : "chevron.right", in: NSRect(x: bounds.width - 20, y: 13, width: 10, height: 10),
        color: choice.selected ? .controlAccentColor : ShelfStyle.secondaryText)
    }
  }
}

/// Owned by the shelf, so interacting with a filter never dismisses the app.
final class ShelfMenuPresenter: NSObject, NSWindowDelegate {
  private(set) var window: NSWindow?
  private weak var anchor: NSButton?
  private weak var owner: NSWindow?
  private var rows: [ShelfMenuRow] = []
  private var typeAhead = ""
  private var lastKeyTime: TimeInterval = 0
  private var clickMonitor: Any?
  private let pointerObserver = ShelfPointerObserver()
  var onDismiss: (() -> Void)?

  deinit { pointerObserver.stop() }

  func show(title: String, sections: [ShelfMenuSection], from anchor: NSButton, matchesShelfSurface: Bool = false) {
    guard let parent = anchor.window else { return }
    if self.anchor === anchor, window != nil {
      close()
      return
    }
    close(restoreFocus: false)
    self.anchor = anchor
    owner = parent
    (anchor as? ShelfFilterButton)?.expanded = true
    let panel = ShelfMenuPanel(title: title, size: NSSize(width: 280, height: 100))
    panel.delegate = self
    panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
    pointerObserver.onMove = { [weak self] location in self?.updateHoverForPointer(atWindowLocation: location) }
    panel.onPointerMoved = { [weak self] location in self?.pointerObserver.observe(location) }
    window = panel

    let surface = ClipEditorSheetSurface(frame: .zero)
    let heading = NativeUI.label(
      title, font: .systemFont(ofSize: matchesShelfSurface ? 13 : 12, weight: .semibold),
      color: matchesShelfSurface ? .labelColor : ShelfStyle.secondaryText)
    heading.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(heading)
    let stack = ShelfMenuDocumentView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
    for (index, section) in sections.enumerated() {
      if index > 0 {
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        stack.setCustomSpacing(7, after: separator)
      }
      if let title = section.title {
        let label = NativeUI.label(title, font: .systemFont(ofSize: 11, weight: .medium), color: ShelfStyle.secondaryText)
        let header = NSView()
        header.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        NSLayoutConstraint.activate([
          label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 9),
          label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        stack.addArrangedSubview(header)
      }
      for choice in section.choices {
        let row = ShelfMenuRow(choice: choice, target: self, action: #selector(choose(_:)))
        row.onHover = { [weak self, weak row] in
          guard let self, let row else { return }
          self.window?.makeFirstResponder(row)
        }
        rows.append(row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(7, after: last) }
    }
    let scroll = NSScrollView()
    scroll.verticalScroller = ShelfScroller()
    scroll.configure(document: stack, vertical: true, autohides: true, style: .overlay)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(scroll)
    let menuWidth = stack.widthAnchor.constraint(equalToConstant: 260)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 19),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -19),
      heading.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
      scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
      scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 38),
      scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6), menuWidth,
    ])
    stack.layoutSubtreeIfNeeded()
    stack.setFrameSize(stack.fittingSize)
    let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
    let height = min(stack.fittingSize.height + 44, min(620, screen.height - 32))
    panel.contentView = surface
    panel.setContentSize(NSSize(width: 280, height: height))
    let source = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let x = min(max(screen.minX + 8, source.minX), screen.maxX - 288)
    let below = source.minY - height - 7
    let y = max(screen.minY + 8, below >= screen.minY + 8 ? below : min(source.maxY + 7, screen.maxY - height - 8))
    panel.setFrameOrigin(NSPoint(x: x, y: y))
    panel.attachToShelf(parent, levelOffset: 0, behavior: ShelfController.panelCollectionBehavior)
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      guard let self, event.window === self.owner, let anchor = self.anchor else { return event }
      let point = anchor.convert(event.locationInWindow, from: nil)
      if !anchor.bounds.contains(point) { self.close(restoreFocus: false) }
      return event
    }
    panel.alphaValue = ShelfMotion.reducesMotion ? 1 : 0
    panel.makeKeyAndOrderFront(nil)
    surface.layoutSubtreeIfNeeded()
    menuWidth.constant = scroll.contentView.bounds.width
    stack.layoutSubtreeIfNeeded()
    stack.setFrameSize(stack.fittingSize)
    if let first = rows.first(where: { $0.choice.selected && $0.isEnabled }) ?? rows.first(where: \.isEnabled) {
      panel.makeFirstResponder(first)
      first.scrollToVisible(first.bounds)
    }
    pointerObserver.start(in: panel, acknowledgeCurrent: true)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = ShelfMotion.duration(0.13)
      panel.animator().alphaValue = 1
    }
  }

  func close(restoreFocus: Bool = true) {
    guard let window else { return }
    pointerObserver.stop()
    self.window = nil
    if let clickMonitor {
      NSEvent.removeMonitor(clickMonitor)
      self.clickMonitor = nil
    }
    let parent = owner
    let button = anchor
    window.detachFromShelf()
    window.close()
    (button as? ShelfFilterButton)?.expanded = false
    rows.removeAll()
    anchor = nil
    owner = nil
    typeAhead = ""
    if restoreFocus, parent?.isVisible == true {
      parent?.makeKeyAndOrderFront(nil)
      if let button { parent?.makeFirstResponder(button) }
    }
    (button as? ShelfIconButton)?.refreshHoverFromPointer(animated: true)
    onDismiss?()
  }

  func windowDidResignKey(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window?.isKeyWindow == false, NSApp.keyWindow !== self.owner else { return }
      self.close(restoreFocus: false)
    }
  }

  @objc private func choose(_ sender: ShelfMenuRow) {
    guard sender.isEnabled else { return }
    let action = sender.choice.action
    close()
    action()
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    // Keyboard selection remains in place until the pointer actually moves.
    pointerObserver.acknowledgePointer()
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if event.keyCode == 53 || (event.keyCode == 13 && modifiers == .command) {
      close()
      return true
    }
    guard modifiers.isEmpty || modifiers == .shift else { return false }
    let enabled = rows.filter(\.isEnabled)
    guard !enabled.isEmpty else { return false }
    let current = enabled.firstIndex { $0 === window?.firstResponder }
    var next: Int?
    switch event.keyCode {
    case 125: next = ((current ?? -1) + 1) % enabled.count
    case 126: next = ((current ?? enabled.count) - 1 + enabled.count) % enabled.count
    case 48: next = ((current ?? (modifiers == .shift ? 0 : -1)) + (modifiers == .shift ? -1 : 1) + enabled.count) % enabled.count
    case 115: next = 0
    case 119: next = enabled.count - 1
    case 36, 76, 49:
      if let current { choose(enabled[current]) }
      return true
    default:
      guard let characters = event.characters, characters.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
      let now = ProcessInfo.processInfo.systemUptime
      typeAhead = now - lastKeyTime > 0.8 ? characters : typeAhead + characters
      lastKeyTime = now
      next = enabled.firstIndex { $0.title.localizedLowercase.hasPrefix(typeAhead.localizedLowercase) }
    }
    if let next {
      let row = enabled[next]
      window?.makeFirstResponder(row)
      row.scrollToVisible(row.bounds)
    }
    return true
  }

  private func updateHoverForPointer(atWindowLocation location: NSPoint) {
    guard let window else { return }
    guard
      let row = rows.first(where: { row in
        row.isEnabled && !row.isHiddenOrHasHiddenAncestor && row.bounds.contains(row.convert(location, from: nil))
      })
    else { return }
    if window.firstResponder !== row { window.makeFirstResponder(row) }
  }
}
