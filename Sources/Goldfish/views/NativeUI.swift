import AppKit

/// Native controls with explicit layout and typography at their construction site.
/// Optional values leave AppKit defaults intact; these helpers do not own actions.
enum NativeUI {
  static func stack(
    _ views: [NSView], axis: NSUserInterfaceLayoutOrientation? = nil, alignment: NSLayoutConstraint.Attribute? = nil,
    spacing: CGFloat? = nil, distribution: NSStackView.Distribution? = nil, detachHidden: Bool? = nil, insets: NSEdgeInsets? = nil
  ) -> NSStackView {
    let stack = NSStackView(views: views)
    if let axis { stack.orientation = axis }
    if let alignment { stack.alignment = alignment }
    if let spacing { stack.spacing = spacing }
    if let distribution { stack.distribution = distribution }
    if let detachHidden { stack.detachesHiddenViews = detachHidden }
    if let insets { stack.edgeInsets = insets }
    return stack
  }

  static func label(
    _ text: String, wrap: Bool = false, font: NSFont? = nil, color: NSColor? = nil, alignment: NSTextAlignment? = nil,
    lineBreak: NSLineBreakMode? = nil, maxLines: Int? = nil
  ) -> NSTextField {
    let label = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    if let font { label.font = font }
    if let color { label.textColor = color }
    if let alignment { label.alignment = alignment }
    if let lineBreak { label.lineBreakMode = lineBreak }
    if let maxLines { label.maximumNumberOfLines = maxLines }
    return label
  }

  static func textAttributes(
    font: NSFont, color: NSColor, lineBreak: NSLineBreakMode, alignment: NSTextAlignment = .left, lineSpacing: CGFloat = 0
  ) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = lineBreak
    paragraph.alignment = alignment
    paragraph.lineSpacing = lineSpacing
    return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
  }

}

extension NSAlert {
  convenience init(title: String, message: String, style: Style = .warning, buttons: [String]) {
    self.init()
    messageText = title
    informativeText = message
    alertStyle = style
    buttons.forEach { addButton(withTitle: $0) }
  }
}

extension NSStackView {
  func removeAllArrangedSubviews() {
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }
}

extension NSScrollView {
  /// Shared setup keeps scroll policy beside the document without replacing
  /// native scrollers, responders, or subclass layout and event handling.
  func configure(
    document: NSView? = nil, vertical: Bool = false, horizontal: Bool = false, autohides: Bool? = nil, style: NSScroller.Style? = nil,
    border: NSBorderType? = nil, clipBackground: Bool? = nil
  ) {
    drawsBackground = false
    hasVerticalScroller = vertical
    hasHorizontalScroller = horizontal
    if let autohides { autohidesScrollers = autohides }
    if let style { scrollerStyle = style }
    if let border { borderType = border }
    if let clipBackground { contentView.drawsBackground = clipBackground }
    documentView = document
  }
}

extension NSBezierPath {
  func fill(with color: NSColor) {
    color.setFill()
    fill()
  }

  func stroke(with color: NSColor, width: CGFloat) {
    color.setStroke()
    lineWidth = width
    stroke()
  }

  func clipped(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    addClip()
    draw()
  }
}

extension NSRect {
  func fill(with color: NSColor) {
    color.setFill()
    fill()
  }
}

extension NSView {
  /// Fill a parent using native constraints; callers still own view hierarchy and actions.
  func pinEdges(to parent: NSView, inset: CGFloat = 0) {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
      trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
      topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
      bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
  }

  func constrainSize(width: CGFloat? = nil, height: CGFloat? = nil) {
    if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
    if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
  }

  /// Replace tracking geometry without changing the control's responder class.
  func replaceTrackingArea(_ area: inout NSTrackingArea?, options: NSTrackingArea.Options) {
    if let area { removeTrackingArea(area) }
    let next = NSTrackingArea(rect: .zero, options: options, owner: self)
    addTrackingArea(next)
    area = next
  }
}

/// Keeps pointer and appearance invalidation consistent without owning selection,
/// focus, actions, or drawing. Each button retains its native responder behavior.
class NativeHoverButton: NSButton {
  private var hoverArea: NSTrackingArea?
  private(set) var isPointerInside = false
  var trackingActivity: NSTrackingArea.Options { .activeAlways }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    replaceTrackingArea(&hoverArea, options: [.mouseEnteredAndExited, .inVisibleRect, trackingActivity])
  }

  override func mouseEntered(with event: NSEvent) {
    isPointerInside = true
    pointerAppearanceChanged()
  }

  override func mouseExited(with event: NSEvent) {
    isPointerInside = false
    pointerAppearanceChanged()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    pointerAppearanceChanged()
  }

  func pointerAppearanceChanged() { needsDisplay = true }
}

func shelfDrawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
  guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
  else { return }
  symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

/// One owner for the common-mode pointer timer. Native mouse events are still
/// delivered immediately; polling only supplies movement AppKit did not send.
final class ShelfPointerObserver {
  private weak var window: NSWindow?
  private var timer: Timer?
  private var lastLocation: NSPoint?
  var onMove: (NSPoint) -> Void = { _ in }
  deinit { stop() }

  func start(in window: NSWindow, acknowledgeCurrent: Bool = false) {
    stop()
    self.window = window
    if acknowledgeCurrent { acknowledgePointer() }
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self, let window = self.window, window.isVisible else { return }
      let location = window.mouseLocationOutsideOfEventStream
      if self.lastLocation != location { self.observe(location) }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func observe(_ location: NSPoint) {
    lastLocation = location
    onMove(location)
  }

  /// Keyboard navigation must stay selected until the pointer moves.
  func acknowledgePointer() { lastLocation = window?.mouseLocationOutsideOfEventStream }

  func stop() {
    timer?.invalidate()
    timer = nil
    window = nil
    lastLocation = nil
  }
}
