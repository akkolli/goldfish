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
}
