import AppKit

/// Top-left coordinates keep preview content anchored while its clipping height changes.
final class CardSurface: NSView { override var isFlipped: Bool { true } }

final class CardSlot: NSView {
  let card: CardView
  private var isLifted = false

  init(card: CardView, frame: NSRect) {
    self.card = card
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.zPosition = 0
    card.translatesAutoresizingMaskIntoConstraints = true
    card.frame = bounds
    card.autoresizingMask = [.width, .height]
    addSubview(card)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }

  var representedItemID: UUID { card.representedItemID }

  func setLifted(_ lifted: Bool) {
    guard isLifted != lifted else { return }
    isLifted = lifted
    layer?.zPosition = lifted ? 20 : 0
  }

}

/// The complete immutable input to a card. Reuse compares this same value, so
/// a new item field cannot silently be omitted from a parallel fingerprint.
struct CardConfiguration: Equatable {
  let item: Clip
  let layout: CardLayout
  let collectionNames: [String]
  let canShowInClipboard: Bool
}
