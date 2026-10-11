import AppKit

final class ShelfIconButton: NSButton {
  private var hoverArea: NSTrackingArea?
  private(set) var isHovered = false

  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

  func configureIcon(
    _ symbol: String, label: String, size: CGFloat = 30, symbolConfiguration: NSImage.SymbolConfiguration? = nil,
    bezel: NSButton.BezelStyle? = nil, template: Bool? = nil
  ) {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    if let template { image?.isTemplate = template }
    self.image = symbolConfiguration.flatMap { image?.withSymbolConfiguration($0) } ?? image
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    if let bezel { bezelStyle = bezel }
    isBordered = false
    configureAppearance(size: size)
    constrainSize(width: size, height: size)
    toolTip = label
    setAccessibilityLabel(label)
  }

  func configureAppearance(size: CGFloat) {
    wantsLayer = true
    layer?.cornerRadius = size / 2
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    applyAppearance(animated: false)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    replaceTrackingArea(&hoverArea, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect])
    refreshHoverFromPointer()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds.intersection(visibleRect), cursor: .arrow)
  }

  override func mouseEntered(with event: NSEvent) { setHoverState(true) }

  override func mouseMoved(with event: NSEvent) { updateHover(atWindowLocation: event.locationInWindow) }

  override func mouseExited(with event: NSEvent) { setHoverState(false) }

  override func viewDidHide() {
    super.viewDidHide()
    setHoverState(false, animated: false)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance(animated: false)
  }

  func refreshHoverFromPointer(animated: Bool = false) {
    guard let window, window.isVisible else {
      setHoverState(false, animated: false)
      return
    }
    updateHover(atWindowLocation: window.mouseLocationOutsideOfEventStream, animated: animated)
  }

  func updateHover(atWindowLocation location: NSPoint, animated: Bool = true) {
    let point = convert(location, from: nil)
    setHoverState(window != nil && bounds.intersection(visibleRect).contains(point), animated: animated)
  }

  func setHoverState(_ hovered: Bool, animated: Bool = true) {
    let next = hovered && isEnabled && !isHiddenOrHasHiddenAncestor
    guard isHovered != next || !animated else { return }
    isHovered = next
    applyAppearance(animated: animated)
  }

  private func applyAppearance(animated: Bool) {
    guard let layer else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let fill = NSColor.labelColor.withAlphaComponent(isHovered ? 0.16 : 0.06).cgColor
      let outline = NSColor.labelColor.withAlphaComponent(isHovered ? 0.14 : 0).cgColor
      let scale: CGFloat = isHovered ? 1.045 : 1
      if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let transitions: [(path: String, from: Any?, to: Any, key: String)] = [
          ("backgroundColor", layer.presentation()?.backgroundColor ?? layer.backgroundColor, fill, "toolbarHoverFill"),
          ("borderColor", layer.presentation()?.borderColor ?? layer.borderColor, outline, "toolbarHoverOutline"),
          ("transform.scale", layer.presentation()?.transform.m11 ?? layer.transform.m11, scale, "toolbarHoverScale"),
        ]
        for transition in transitions {
          let animation = CABasicAnimation(keyPath: transition.path)
          animation.fromValue = transition.from
          animation.toValue = transition.to
          animation.duration = 0.16
          animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
          layer.add(animation, forKey: transition.key)
        }
      } else {
        for key in ["toolbarHoverFill", "toolbarHoverOutline", "toolbarHoverScale"] { layer.removeAnimation(forKey: key) }
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.backgroundColor = fill
      layer.borderColor = outline
      layer.transform = CATransform3DMakeScale(scale, scale, 1)
      CATransaction.commit()
      contentTintColor = isHovered ? .labelColor : ShelfStyle.secondaryText
    }
  }
}
