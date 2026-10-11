import AppKit

/// Owns the search field, clear button, focus ring, and field-editor behavior.
/// The shelf supplies actions; it does not manage the control's internal state.
final class ShelfSearchControl: NSView, NSSearchFieldDelegate {
  private enum Metrics {
    static let searchControlSize = ShelfStyle.controlSize
    static let searchFont = NSFont.systemFont(ofSize: 14, weight: .regular)
  }

  private enum Palette {
    static let searchFill = NSColor(name: "Goldfish search fill") { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.07)
    }
    static let searchBorder = NSColor(name: "Goldfish search border") { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
    }
  }

  private let searchField = ClipboardPanelSearchField()
  private let searchIconButton = NSButton()
  private let clearSearchButton = ClipboardPanelClearSearchButton()
  private var clearSearchButtonWidthConstraint: NSLayoutConstraint?

  var onTextChanged: ((String) -> Void)?
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onNavigateResults: (() -> Void)?

  var text: String {
    get { searchField.stringValue }
    set {
      if searchField.stringValue != newValue { searchField.stringValue = newValue }
      if newValue.isEmpty && !isEditing { searchField.setKeyboardFocusForPresentation(false) }
      updateAppearance()
    }
  }

  var isEditing: Bool {
    guard let responder = window?.firstResponder else { return false }
    return responder === searchField || responder === searchField.currentEditor()
      || (responder as? NSView)?.isDescendant(of: searchField) == true
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    configureSearchIconButton()
    let searchCell = ClipboardPanelSearchFieldCell(textCell: "")
    searchCell.searchButtonCell = nil
    searchCell.cancelButtonCell = nil
    searchCell.font = Metrics.searchFont
    searchField.cell = searchCell
    searchField.isEditable = true
    searchField.isSelectable = true
    searchField.isHidden = false
    searchField.setAccessibilityLabel("Search clipboard history")
    searchField.delegate = self
    searchField.target = self
    searchField.action = #selector(searchFieldChanged)
    searchField.onFocusStateChanged = { [weak self] in self?.updateAppearance() }
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = false
    searchField.isBezeled = false
    searchField.drawsBackground = false
    searchField.backgroundColor = .clear
    searchField.font = Metrics.searchFont
    searchField.textColor = .labelColor
    searchField.placeholderAttributedString = NSAttributedString(
      string: "Search", attributes: [.font: Metrics.searchFont, .foregroundColor: ShelfStyle.secondaryText])
    searchField.focusRingType = .none
    searchField.toolTip = "Search clipboard history."
    searchField.setAccessibilityHelp("Search clips. Use Destination, Content type, and Filter to narrow results. Command-F focuses search.")
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    clearSearchButton.isBordered = false
    clearSearchButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
    clearSearchButton.imagePosition = .imageOnly
    clearSearchButton.contentTintColor = .secondaryLabelColor
    clearSearchButton.focusRingType = .none
    clearSearchButton.toolTip = "Clear search"
    clearSearchButton.setAccessibilityLabel("Clear search")
    clearSearchButton.setAccessibilityHelp("Clear the search query and show all matching clips.")
    clearSearchButton.target = self
    clearSearchButton.action = #selector(clearSearchFromButton)
    clearSearchButton.isHidden = true
    clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
    configureSearchControlContainer()
    updateAppearance()
  }

  convenience init() { self.init(frame: .zero) }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func configureSearchIconButton() {
    let toolTip = "Search"
    let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: toolTip)
    image?.isTemplate = true
    searchIconButton.image = image
    searchIconButton.imagePosition = .imageOnly
    searchIconButton.imageScaling = .scaleProportionallyDown
    searchIconButton.bezelStyle = .smallSquare
    searchIconButton.isBordered = false
    searchIconButton.wantsLayer = true
    searchIconButton.layer?.cornerRadius = Metrics.searchControlSize / 2
    searchIconButton.layer?.borderWidth = 0
    searchIconButton.layer?.borderColor = NSColor.clear.cgColor
    searchIconButton.layer?.backgroundColor = NSColor.clear.cgColor
    searchIconButton.contentTintColor = ShelfStyle.secondaryText
    searchIconButton.toolTip = toolTip
    searchIconButton.target = self
    searchIconButton.action = #selector(focusSearchFromIcon)
    searchIconButton.setAccessibilityLabel(toolTip)
    searchIconButton.setAccessibilityHelp("Search clipboard history.")
    searchIconButton.translatesAutoresizingMaskIntoConstraints = false
    searchIconButton.constrainSize(width: Metrics.searchControlSize, height: Metrics.searchControlSize)
  }

  private func configureSearchControlContainer() {
    self.translatesAutoresizingMaskIntoConstraints = false
    self.wantsLayer = true
    self.layer?.cornerRadius = Metrics.searchControlSize / 2
    self.layer?.cornerCurve = .continuous
    self.layer?.masksToBounds = true
    self.layer?.backgroundColor = Palette.searchFill.cgColor
    self.layer?.borderWidth = 0.8
    self.layer?.borderColor = Palette.searchBorder.cgColor
    self.setContentHuggingPriority(.defaultLow, for: .horizontal)
    self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    heightAnchor.constraint(equalToConstant: Metrics.searchControlSize).isActive = true

    self.addSubview(searchField)
    self.addSubview(searchIconButton)
    self.addSubview(clearSearchButton)
    clearSearchButtonWidthConstraint = clearSearchButton.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      searchField.leadingAnchor.constraint(equalTo: searchIconButton.trailingAnchor),
      searchField.trailingAnchor.constraint(equalTo: clearSearchButton.leadingAnchor, constant: -4),
      // AppKit draws the search cell's glyphs above its geometric center.
      // Lower the field while keeping the icon and capsule mathematically centered.
      searchField.centerYAnchor.constraint(equalTo: self.centerYAnchor, constant: 3),
      searchField.heightAnchor.constraint(equalToConstant: 24), searchIconButton.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      searchIconButton.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      clearSearchButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -1),
      clearSearchButton.centerYAnchor.constraint(equalTo: self.centerYAnchor), clearSearchButtonWidthConstraint!,
      clearSearchButton.heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    let showsClear = !text.isEmpty
    clearSearchButtonWidthConstraint?.constant = showsClear ? 28 : 0
    clearSearchButton.isHidden = !showsClear
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let focused = searchField.hasKeyboardFocusForPresentation
      layer?.backgroundColor = Palette.searchFill.cgColor
      layer?.borderColor = focused ? NSColor.keyboardFocusIndicatorColor.cgColor : Palette.searchBorder.cgColor
      layer?.borderWidth = focused ? 2.5 : 0.8
    }
  }

  func releaseIdleFocus() { if text.isEmpty { searchField.setKeyboardFocusForPresentation(false) } }

  func focus() {
    searchField.setKeyboardFocusForPresentation(true)
    window?.makeFirstResponder(searchField)
  }

  @discardableResult func clear() -> Bool {
    guard !text.isEmpty else { return false }
    text = ""
    onTextChanged?(text)
    focus()
    return true
  }

  func startSearch(with value: String) {
    guard !value.isEmpty else { return }
    focus()
    let current = text.clipboardTrimmed
    text = current.isEmpty ? value : "\(current) \(value)"
    onTextChanged?(text)
  }

  func controlTextDidChange(_ notification: Notification) { searchFieldChanged() }

  func controlTextDidBeginEditing(_ notification: Notification) { searchField.setKeyboardFocusForPresentation(true) }

  func controlTextDidEndEditing(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isEditing else { return }
      self.searchField.setKeyboardFocusForPresentation(false)
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
    switch command {
    case #selector(NSResponder.insertNewline(_:)): onSubmit?()
    case #selector(NSResponder.cancelOperation(_:)): if !clear() { onCancel?() }
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)): onNavigateResults?()
    default: return false
    }
    return true
  }

  @objc private func searchFieldChanged() {
    if text.isEmpty && !isEditing { searchField.setKeyboardFocusForPresentation(false) }
    onTextChanged?(text)
    updateAppearance()
  }

  @objc private func clearSearchFromButton() { clear() }
  @objc private func focusSearchFromIcon() { focus() }
}

private final class ClipboardPanelSearchFieldCell: NSSearchFieldCell {
  private enum Metrics {
    static let textLeadingInset: CGFloat = 2
    static let textTrailingInset: CGFloat = 4
  }

  override func searchButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

  override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
    let editor = super.setUpFieldEditorAttributes(textObj)
    if let textView = editor as? NSTextView {
      textView.drawsBackground = false
      textView.backgroundColor = .clear
      textView.font = font
      textView.textColor = .labelColor
    }
    return editor
  }

  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    return NSRect(
      x: rect.minX + Metrics.textLeadingInset, y: rect.minY,
      width: max(0, rect.width - Metrics.textLeadingInset - Metrics.textTrailingInset), height: rect.height)
  }
}

private final class ClipboardPanelClearSearchButton: NSButton {
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
  }
}

private final class ClipboardPanelSearchField: NSSearchField {
  var onFocusStateChanged: (() -> Void)?
  private(set) var hasKeyboardFocusForPresentation = false

  override func becomeFirstResponder() -> Bool {
    let becameFirstResponder = super.becomeFirstResponder()
    if becameFirstResponder { setKeyboardFocusForPresentation(true) }
    return becameFirstResponder
  }

  override func resignFirstResponder() -> Bool {
    let resignedFirstResponder = super.resignFirstResponder()
    if resignedFirstResponder { setKeyboardFocusForPresentation(false) }
    return resignedFirstResponder
  }

  func setKeyboardFocusForPresentation(_ focused: Bool) {
    guard hasKeyboardFocusForPresentation != focused else {
      onFocusStateChanged?()
      return
    }
    hasKeyboardFocusForPresentation = focused
    onFocusStateChanged?()
  }
}
