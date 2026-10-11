import AppKit

/// A small, shelf-owned editor for the two pinboard operations. It shares the
/// same surface as the clip composer and stays beside the pinboard controls.
final class PinboardEditorController: AttachedEditorController, NSTextFieldDelegate {
  private static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]

  private let input = NSTextField()
  private let inputSurface = PinboardNameSurface()
  private let saveButton = ShelfIconButton(title: "Save Pinboard", target: nil, action: nil)
  private let message = NSTextField(labelWithString: "")
  private var swatches: [PinboardChoiceButton] = []
  private var iconButtons: [PinboardChoiceButton] = []
  private var color: NSColor
  private var icon: String
  private let initialName: String
  private let existingNames: () -> [String]
  private let onSave: (PinboardRequest) -> Void

  init(
    editing: Bool, initialName: String, initialColor: NSColor, initialIcon: String, existingNames: @escaping () -> [String],
    onSave: @escaping (PinboardRequest) -> Void, onFinish: @escaping () -> Void
  ) {
    self.initialName = initialName
    self.color = initialColor
    self.icon = PinboardIcon.normalized(initialIcon) ?? PinboardIcon.defaultSymbol
    self.existingNames = existingNames
    self.onSave = onSave
    super.init(
      window: ClipEditorPanel(title: editing ? "Edit Pinboard" : "New Pinboard", size: NSSize(width: 318, height: 176)),
      position: .pinboard, onFinish: onFinish)

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

    let colorLabel = NativeUI.label("Color", font: .systemFont(ofSize: 11, weight: .medium), color: ShelfStyle.secondaryText)
    let iconLabel = NativeUI.label("Icon", font: .systemFont(ofSize: 11, weight: .medium), color: ShelfStyle.secondaryText)

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

    swatches = Self.palette.map { PinboardChoiceButton(color: $0, target: self, action: #selector(selectSwatch(_:))) }
    iconButtons = PinboardIcon.choices.map {
      PinboardChoiceButton(symbol: $0.symbol, label: $0.label, target: self, action: #selector(selectIcon(_:)))
    }
    for (label, buttons, size, gap) in [(colorLabel, swatches, CGFloat(22), CGFloat(9)), (iconLabel, iconButtons, 25, 4)] {
      var previous: NSView = label
      for (index, button) in buttons.enumerated() {
        button.tag = index
        button.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(button)
        NSLayoutConstraint.activate([
          button.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: index == 0 ? 13 : gap),
          button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        button.constrainSize(width: size, height: size)
        previous = button
      }
    }
    window.initialFirstResponder = input
    updateValidation()
    updateSwatchSelection()
    updateIconSelection()
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
    let name = PinboardNames.normalizedName(input.stringValue)
    let duplicate =
      name.map { candidate in
        existingNames().contains {
          $0.caseInsensitiveCompare(candidate) == .orderedSame && $0.caseInsensitiveCompare(initialName) != .orderedSame
        }
      } ?? false
    saveButton.isEnabled = name != nil && !duplicate
    saveButton.contentTintColor = saveButton.isEnabled ? ShelfStyle.brandAccent : .tertiaryLabelColor
    message.stringValue = duplicate ? "A pinboard with this name already exists" : ""
    message.isHidden = !duplicate
    let desiredHeight: CGFloat = duplicate ? 194 : 176
    if abs(window.frame.height - desiredHeight) > 0.5 {
      window.setContentSize(NSSize(width: 318, height: desiredHeight))
      positionNearAnchor()
    }
  }

  private func updateSwatchSelection() {
    let chosen = PinboardStyle.hexString(for: color)
    for (index, swatch) in swatches.enumerated() { swatch.isChoiceSelected = PinboardStyle.hexString(for: Self.palette[index]) == chosen }
  }

  @objc private func selectSwatch(_ sender: NSButton) {
    color = Self.palette[sender.tag]
    updateSwatchSelection()
    updateIconSelection()
  }

  private func updateIconSelection() {
    for (index, button) in iconButtons.enumerated() {
      button.isChoiceSelected = PinboardIcon.choices[index].symbol == icon
      button.accentColor = color
    }
  }

  @objc private func selectIcon(_ sender: NSButton) {
    icon = PinboardIcon.choices[sender.tag].symbol
    updateIconSelection()
  }

  @objc private func save() {
    guard saveButton.isEnabled, let name = PinboardNames.normalizedName(input.stringValue) else { return }
    let request = PinboardRequest(name: name, colorHex: PinboardStyle.hexString(for: color), icon: icon)
    dismiss()
    onSave(request)
  }

  private func iconButton(_ symbol: String, label: String, action: Selector) -> ShelfIconButton {
    let button = ShelfIconButton(title: label, target: self, action: action)
    configureIcon(button, symbol: symbol, label: label)
    return button
  }

  private func configureIcon(_ button: ShelfIconButton, symbol: String, label: String) {
    button.configureIcon(symbol, label: label, symbolConfiguration: .init(pointSize: 12, weight: .semibold))
  }
}

/// Color and symbol choices share selection, pointer and appearance ownership.
private final class PinboardChoiceButton: NativeHoverButton {
  private let swatchColor: NSColor?
  var isChoiceSelected = false { didSet { updateAppearance() } }
  var accentColor: NSColor = .controlAccentColor { didSet { updateAppearance() } }

  convenience init(color: NSColor, target: AnyObject, action: Selector) {
    self.init(color: color, symbol: nil, label: "\(color.accessibilityName.capitalized) pinboard color", target: target, action: action)
  }

  convenience init(symbol: String, label: String, target: AnyObject, action: Selector) {
    self.init(color: nil, symbol: symbol, label: label, target: target, action: action)
  }

  private init(color: NSColor?, symbol: String?, label: String, target: AnyObject, action: Selector) {
    swatchColor = color
    super.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    toolTip = label
    setAccessibilityLabel(color == nil ? "\(label) icon" : label)
    wantsLayer = true
    layer?.cornerRadius = color == nil ? 8 : 11
    layer?.borderWidth = color == nil ? 1 : 2
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
        .init(pointSize: 12, weight: .medium))
      imagePosition = .imageOnly
      imageScaling = .scaleProportionallyDown
      layer?.cornerCurve = .continuous
    }
    updateAppearance()
  }

  required init?(coder: NSCoder) { nil }
  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
  }
  override func pointerAppearanceChanged() { updateAppearance() }

  private func updateAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if let swatchColor {
        layer?.backgroundColor = swatchColor.cgColor
        let ink = NSColor.labelColor
        layer?.borderColor =
          isChoiceSelected ? ink.withAlphaComponent(0.9).cgColor : ink.withAlphaComponent(isPointerInside ? 0.42 : 0).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isChoiceSelected ? 0.22 : 0
        layer?.shadowRadius = 3
      } else {
        contentTintColor = isChoiceSelected ? accentColor : .secondaryLabelColor
        layer?.backgroundColor =
          isChoiceSelected
          ? accentColor.withAlphaComponent(0.17).cgColor : NSColor.labelColor.withAlphaComponent(isPointerInside ? 0.08 : 0).cgColor
        layer?.borderColor = isChoiceSelected ? accentColor.withAlphaComponent(0.42).cgColor : NSColor.clear.cgColor
      }
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
