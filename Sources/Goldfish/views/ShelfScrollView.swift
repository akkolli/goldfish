import AppKit

enum ClipDragPasteboard {
  static let itemIDType = NSPasteboard.PasteboardType("com.goldfish.clipboard-item-id")

}

func shelfSearchText(from event: NSEvent) -> String? {
  let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
  guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return nil }
  guard let characters = event.characters, !characters.isEmpty else { return nil }
  guard characters.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
  return characters
}

func selectionMode(from modifiers: NSEvent.ModifierFlags) -> ClipSelection {
  let relevantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
  if relevantModifiers.contains(.shift) { return .range }
  if relevantModifiers.contains(.command) { return .toggle }
  return .replace
}

enum ClipDragContext { static var itemID: UUID? }

final class ShelfScrollView: NSScrollView {
  private let overflowMask = CAGradientLayer()
  private let fadeWidth: CGFloat
  var onVisibleBoundsChanged: (() -> Void)?
  var onScrollActivity: (() -> Void)?

  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

  init(edgeFadeWidth: CGFloat = 26) {
    self.fadeWidth = edgeFadeWidth
    super.init(frame: .zero)
    configureOverflowFades()
  }

  override init(frame frameRect: NSRect) {
    self.fadeWidth = 26
    super.init(frame: frameRect)
    configureOverflowFades()
  }

  required init?(coder: NSCoder) {
    self.fadeWidth = 26
    super.init(coder: coder)
    configureOverflowFades()
  }

  override func scrollWheel(with event: NSEvent) {
    onScrollActivity?()
    let horizontalDelta = event.scrollingDeltaX
    let verticalDelta = event.scrollingDeltaY
    if abs(verticalDelta) > abs(horizontalDelta), abs(verticalDelta) > 0, canScrollHorizontally {
      scrollHorizontally(by: -verticalDelta)
      return
    }

    super.scrollWheel(with: event)
    updateOverflowFades()
  }

  override func layout() {
    super.layout()
    updateOverflowFades()
    onVisibleBoundsChanged?()
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    updateOverflowFades()
    onVisibleBoundsChanged?()
  }

  private func configureOverflowFades() { contentView.wantsLayer = true }

  private var canScrollHorizontally: Bool { maxHorizontalOffset > 0 }

  private var maxHorizontalOffset: CGFloat {
    guard let documentView else { return 0 }
    return max(0, documentView.frame.width - contentView.bounds.width)
  }

  private func scrollHorizontally(by deltaX: CGFloat) {
    let maxOffset = maxHorizontalOffset
    guard maxOffset > 0 else { return }
    let origin = contentView.bounds.origin
    let targetX = min(max(origin.x + deltaX, 0), maxOffset)
    guard targetX != origin.x else { return }

    contentView.scroll(to: NSPoint(x: targetX, y: origin.y))
    reflectScrolledClipView(contentView)
  }

  private func updateOverflowFades() {
    let maxVerticalOffset = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
    let vertical = hasVerticalScroller && maxVerticalOffset > 0
    let maxOffset = vertical ? maxVerticalOffset : maxHorizontalOffset
    guard maxOffset > 0, !ShelfStyle.increasedContrast, !ShelfStyle.reducedTransparency else {
      contentView.layer?.mask = nil
      return
    }
    // Fade pixels into the shared material instead of painting an opaque strip.
    // The mask belongs to the content clip, so native scrollers stay visible.
    let origin = vertical ? contentView.bounds.minY : contentView.bounds.minX
    let extent = max(1, vertical ? contentView.bounds.height : contentView.bounds.width)
    let leadingWidth: CGFloat = vertical ? 24 : fadeWidth
    let trailingWidth: CGFloat = vertical ? 36 : fadeWidth
    let leading = min(1, max(0, origin / leadingWidth))
    let trailing = min(1, max(0, (maxOffset - origin) / (vertical ? 32 : fadeWidth)))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    overflowMask.frame = contentView.bounds
    overflowMask.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
    overflowMask.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
    overflowMask.locations = [
      0, NSNumber(value: Double(min(0.18, leadingWidth / extent))), NSNumber(value: Double(1 - min(0.18, trailingWidth / extent))), 1,
    ]
    overflowMask.colors = [
      NSColor.black.withAlphaComponent(1 - leading).cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
      NSColor.black.withAlphaComponent(1 - trailing).cgColor,
    ]
    contentView.layer?.mask = overflowMask
    CATransaction.commit()
  }
}

/// Card slots are positioned by the shelf's grid/rail layout, not Auto Layout.
final class ClipboardCardsDocumentView: NSView {
  var contentInsets = NSEdgeInsetsZero
  override var isFlipped: Bool { true }
}
