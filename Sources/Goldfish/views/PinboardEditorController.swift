import AppKit

/// A small, shelf-owned editor for the two pinboard operations. It shares the
/// same surface as the clip composer and stays beside the pinboard controls.
final class PinboardEditorController: NSObject, NSTextFieldDelegate {
  private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]

  let window: ClipEditorPanel
  private let input = NSTextField()
  private let inputSurface = PinboardNameSurface()
  private let saveButton = ClipboardToolbarIconButton(title: "Save Pinboard", target: nil, action: nil)
  private let message = NSTextField(labelWithString: "")
  private var swatches: [PinboardColorChoiceButton] = []
  private var iconButtons: [PinboardIconChoiceButton] = []
  private var color: NSColor
  private var icon: String
  private let initialName: String
  private let existingNames: () -> [String]
  private let onSave: (CollectionCreationRequest) -> Void
  private let onFinish: () -> Void
  private weak var parentWindow: NSWindow?
  private weak var anchorView: NSView?
  private var isFinished = false

  init(
    editing: Bool, initialName: String, initialColor: NSColor, initialIcon: String, existingNames: @escaping () -> [String],
    onSave: @escaping (CollectionCreationRequest) -> Void, onFinish: @escaping () -> Void
  ) {
    self.initialName = initialName
    self.color = initialColor
    self.icon = ClipboardCollectionIcon.normalized(initialIcon) ?? ClipboardCollectionIcon.defaultSymbol
    self.existingNames = existingNames
    self.onSave = onSave
    self.onFinish = onFinish
    window = ClipEditorPanel(title: editing ? "Edit Pinboard" : "New Pinboard", size: NSSize(width: 318, height: 176))
    super.init()

    let surface = ClipEditorSheetSurface(frame: window.contentView?.bounds ?? .zero)
    window.contentView = surface

    let heading = NativeUI.label(
      editing ? "Edit pinboard" : "New pinboard", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    let cancel = iconButton("xmark", label: "Cancel", action: #selector(dismiss))
    saveButton.target = self
    saveButton.action = #selector(save)
    configureIcon(saveButton, symbol: "checkmark", label: editing ? "Save Pinboard" : "Create Pinboard")
    saveButton.keyEquivalent = "\r"
    saveButton.keyEquivalentModifierMask = []

    input.placeholderString = "Pinboard name"
    input.setAccessibilityLabel("Pinboard name")
    input.stringValue = initialName
    input.font = .systemFont(ofSize: 14)
    input.isBezeled = false
    input.drawsBackground = false
    input.focusRingType = .none
    input.delegate = self
    inputSurface.addSubview(input)

    let colorLabel = NativeUI.label("Color", font: .systemFont(ofSize: 11, weight: .medium), color: ClipboardShelfStyle.secondaryText)
    let iconLabel = NativeUI.label("Icon", font: .systemFont(ofSize: 11, weight: .medium), color: ClipboardShelfStyle.secondaryText)

    message.font = .systemFont(ofSize: 11)
    message.textColor = .systemRed
    message.lineBreakMode = .byTruncatingTail

    for view in [heading, cancel, saveButton, inputSurface, colorLabel, iconLabel, message] {
      view.translatesAutoresizingMaskIntoConstraints = false
      surface.addSubview(view)
    }
    input.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
      heading.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: 23),
      saveButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
      saveButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
      cancel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      inputSurface.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
      inputSurface.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
      inputSurface.topAnchor.constraint(equalTo: surface.topAnchor, constant: 50),
      inputSurface.heightAnchor.constraint(equalToConstant: 36),
      input.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 12),
      input.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -12),
      input.centerYAnchor.constraint(equalTo: inputSurface.centerYAnchor), input.heightAnchor.constraint(equalToConstant: 22),
      colorLabel.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 2),
      colorLabel.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: 112),
      iconLabel.leadingAnchor.constraint(equalTo: colorLabel.leadingAnchor),
      iconLabel.centerYAnchor.constraint(equalTo: surface.topAnchor, constant: 152),
      message.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 2),
      message.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor),
      message.topAnchor.constraint(equalTo: surface.topAnchor, constant: 176),
    ])

    var previous: NSView = colorLabel
    for (index, swatchColor) in Self.palette.enumerated() {
      let swatch = PinboardColorChoiceButton(color: swatchColor, target: self, action: #selector(selectSwatch(_:)))
      swatch.tag = index
      swatch.translatesAutoresizingMaskIntoConstraints = false
      surface.addSubview(swatch)
      NSLayoutConstraint.activate([
        swatch.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: index == 0 ? 13 : 9),
        swatch.centerYAnchor.constraint(equalTo: colorLabel.centerYAnchor), swatch.widthAnchor.constraint(equalToConstant: 22),
        swatch.heightAnchor.constraint(equalToConstant: 22),
      ])
      swatches.append(swatch)
      previous = swatch
    }
    previous = iconLabel
    for (index, choice) in ClipboardCollectionIcon.choices.enumerated() {
      let button = PinboardIconChoiceButton(symbol: choice.symbol, label: choice.label, target: self, action: #selector(selectIcon(_:)))
      button.tag = index
      button.translatesAutoresizingMaskIntoConstraints = false
      surface.addSubview(button)
      NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: index == 0 ? 13 : 4),
        button.centerYAnchor.constraint(equalTo: iconLabel.centerYAnchor), button.widthAnchor.constraint(equalToConstant: 25),
        button.heightAnchor.constraint(equalToConstant: 25),
      ])
      iconButtons.append(button)
      previous = button
    }
    window.initialFirstResponder = input
    updateValidation()
    updateSwatchSelection()
    updateIconSelection()
  }

  func show(relativeTo parent: NSWindow, anchoredTo anchor: NSView?) {
    parentWindow = parent
    anchorView = anchor
    positionNearAnchor()
    window.attachToShelf(parent)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(input)
  }

  private func positionNearAnchor() {
    guard let parent = parentWindow else { return }
    let screen = parent.screen?.visibleFrame ?? parent.frame
    let source = anchorView.map { parent.convertToScreen($0.convert($0.bounds, to: nil)) }
    let left = max(parent.frame.minX + 8, screen.minX + 8)
    let right = min(parent.frame.maxX - window.frame.width - 8, screen.maxX - window.frame.width - 8)
    let x = max(left, min((source?.minX ?? parent.frame.minX) - 8, max(left, right)))
    let below = (source?.minY ?? parent.frame.maxY) - window.frame.height - 6
    let y = below >= screen.minY + 8 ? below : min((source?.maxY ?? parent.frame.maxY) + 6, screen.maxY - window.frame.height - 8)
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  func controlTextDidChange(_ notification: Notification) { updateValidation() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      save()
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      dismiss()
      return true
    }
    return false
  }

  private func updateValidation() {
    let name = ClipboardCollectionDefaults.normalizedName(input.stringValue)
    let duplicate =
      name.map { candidate in
        existingNames().contains {
          $0.caseInsensitiveCompare(candidate) == .orderedSame && $0.caseInsensitiveCompare(initialName) != .orderedSame
        }
      } ?? false
    saveButton.isEnabled = name != nil && !duplicate
    saveButton.contentTintColor = saveButton.isEnabled ? ClipboardShelfStyle.brandAccent : .tertiaryLabelColor
    message.stringValue = duplicate ? "A pinboard with this name already exists" : ""
    message.isHidden = !duplicate
    let desiredHeight: CGFloat = duplicate ? 194 : 176
    if abs(window.frame.height - desiredHeight) > 0.5 {
      window.setContentSize(NSSize(width: 318, height: desiredHeight))
      positionNearAnchor()
    }
  }

  private func updateSwatchSelection() {
    let chosen = ClipboardCollectionVisuals.hexString(for: color)
    for (index, swatch) in swatches.enumerated() {
      swatch.isChoiceSelected = ClipboardCollectionVisuals.hexString(for: Self.palette[index]) == chosen
    }
  }

  @objc private func selectSwatch(_ sender: NSButton) {
    color = Self.palette[sender.tag]
    updateSwatchSelection()
    updateIconSelection()
  }

  private func updateIconSelection() {
    for (index, button) in iconButtons.enumerated() {
      button.isChoiceSelected = ClipboardCollectionIcon.choices[index].symbol == icon
      button.accentColor = color
    }
  }

  @objc private func selectIcon(_ sender: NSButton) {
    icon = ClipboardCollectionIcon.choices[sender.tag].symbol
    updateIconSelection()
  }

  @objc private func save() {
    guard saveButton.isEnabled, let name = ClipboardCollectionDefaults.normalizedName(input.stringValue) else { return }
    let request = CollectionCreationRequest(name: name, colorHex: ClipboardCollectionVisuals.hexString(for: color), icon: icon)
    dismiss()
    onSave(request)
  }

  @objc func dismiss() {
    guard !isFinished else { return }
    isFinished = true
    window.detachFromShelf()
    onFinish()
  }

  private func iconButton(_ symbol: String, label: String, action: Selector) -> ClipboardToolbarIconButton {
    let button = ClipboardToolbarIconButton(title: label, target: self, action: action)
    configureIcon(button, symbol: symbol, label: label)
    return button
  }

  private func configureIcon(_ button: ClipboardToolbarIconButton, symbol: String, label: String) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
      .init(pointSize: 12, weight: .semibold))
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.isBordered = false
    button.configureAppearance(size: 30)
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    button.toolTip = label
    button.setAccessibilityLabel(label)
  }
}

private final class PinboardColorChoiceButton: NSButton {
  var isChoiceSelected = false { didSet { updateAppearance() } }
  private let swatchColor: NSColor
  private var isHovered = false
  private var hoverArea: NSTrackingArea?

  init(color: NSColor, target: AnyObject, action: Selector) {
    swatchColor = color
    super.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    toolTip = "\(color.accessibilityName.capitalized) pinboard color"
    setAccessibilityLabel(toolTip!)
    wantsLayer = true
    layer?.cornerRadius = 11
    layer?.borderWidth = 2
    updateAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    hoverArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(hoverArea!)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateAppearance()
  }
  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateAppearance()
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = swatchColor.cgColor
      let ink = NSColor.labelColor
      layer?.borderColor = isChoiceSelected ? ink.withAlphaComponent(0.9).cgColor : ink.withAlphaComponent(isHovered ? 0.42 : 0).cgColor
      layer?.shadowColor = NSColor.black.cgColor
      layer?.shadowOpacity = isChoiceSelected ? 0.22 : 0
      layer?.shadowRadius = 3
    }
  }
}

private final class PinboardIconChoiceButton: NSButton {
  var isChoiceSelected = false { didSet { updateAppearance() } }
  var accentColor: NSColor = .controlAccentColor { didSet { updateAppearance() } }
  private var isHovered = false
  private var hoverArea: NSTrackingArea?

  init(symbol: String, label: String, target: AnyObject, action: Selector) {
    super.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
      .init(pointSize: 12, weight: .medium))
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    toolTip = label
    setAccessibilityLabel("\(label) icon")
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    updateAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    hoverArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(hoverArea!)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateAppearance()
  }
  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateAppearance()
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      contentTintColor = isChoiceSelected ? accentColor : .secondaryLabelColor
      layer?.backgroundColor =
        isChoiceSelected
        ? accentColor.withAlphaComponent(0.17).cgColor : NSColor.labelColor.withAlphaComponent(isHovered ? 0.08 : 0).cgColor
      layer?.borderColor = isChoiceSelected ? accentColor.withAlphaComponent(0.42).cgColor : NSColor.clear.cgColor
    }
  }
}

private final class PinboardNameSurface: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    updateAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
      layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
  }
}
