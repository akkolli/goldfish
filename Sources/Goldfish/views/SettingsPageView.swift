import AppKit

private final class TopAlignedSettingsDocumentView: NSView { override var isFlipped: Bool { true } }

/// The document hugs its contents, but always fills the viewport. A fixed content
/// width makes wrapping labels participate in the measured height of each page.
final class SettingsPageScrollView: NSScrollView {
  private let page: NSView
  private let pageWidth: NSLayoutConstraint

  init(page: NSView) {
    self.page = page
    page.translatesAutoresizingMaskIntoConstraints = false
    pageWidth = page.widthAnchor.constraint(equalToConstant: 536)
    super.init(frame: .zero)
    let document = TopAlignedSettingsDocumentView()
    document.addSubview(page)
    configure(document: document, vertical: true, autohides: true)
    NSLayoutConstraint.activate([
      pageWidth, page.leadingAnchor.constraint(equalTo: document.leadingAnchor), page.topAnchor.constraint(equalTo: document.topAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func contentHeight(for width: CGFloat) -> CGFloat {
    pageWidth.constant = max(1, width)
    page.layoutSubtreeIfNeeded()
    return ceil(page.fittingSize.height)
  }

  override func layout() {
    super.layout()
    // Decide overflow at the full page width first. Otherwise a scrollbar can
    // keep text wrapped narrowly enough to perpetuate its own overflow.
    let needsScroller = contentHeight(for: bounds.width) > contentView.bounds.height + 0.5
    if hasVerticalScroller != needsScroller {
      hasVerticalScroller = needsScroller
      tile()
    }
    // Changing the document height can remove a legacy scrollbar, which in
    // turn changes wrapping width. Settle both dimensions in the same pass.
    for _ in 0..<3 {
      let width = contentView.bounds.width
      let height = max(contentView.bounds.height, contentHeight(for: width))
      let size = NSSize(width: width, height: height)
      if documentView?.frame.size != size { documentView?.setFrameSize(size) }
      tile()
      if abs(contentView.bounds.width - width) < 0.5 { break }
    }
  }
}

final class SettingsSectionView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = ShelfStyle.cardRadius
    layer?.borderWidth = 1
  }

  required init?(coder: NSCoder) { nil }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = ShelfStyle.cardBackground.cgColor
      layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
