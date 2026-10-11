import AppKit

struct CardLayout: Equatable {
  var width: CGFloat
  var height: CGFloat
  let headerHeight: CGFloat
  var bodyHeight: CGFloat { height - headerHeight - footerHeight }
  let footerHeight: CGFloat
  var textScale: CGFloat = 1
  var usesGalleryStyle = false

  static func gallery(width: ShelfWidth, largerText: Bool) -> CardLayout {
    let size: NSSize
    switch width {
    case .compact: size = NSSize(width: 204, height: 224)
    case .standard: size = NSSize(width: 240, height: 260)
    case .wide: size = NSSize(width: 280, height: 300)
    }
    let height = size.height + (largerText ? 28 : 0)
    return CardLayout(
      width: size.width, height: height, headerHeight: 52, footerHeight: 32, textScale: largerText ? 1.2 : 1, usesGalleryStyle: true)
  }

  static let compact = CardLayout(width: 264, height: 244, headerHeight: 84, footerHeight: 32)

  var contentInset: CGFloat { width < 260 ? 12 : 16 }
  var cornerRadius: CGFloat { width < 260 ? 18 : ShelfStyle.cardRadius }

  func fittingVerticalContent(of item: Clip) -> CardLayout {
    // AppKit rounds autoresized child frames to backing pixels. Integral
    // sections keep that rounding from taking a fraction off the final text line.
    let isTile = width < 260
    let header: CGFloat = ceil((isTile ? 44 : 46) * textScale)
    let footer: CGFloat = ceil((isTile ? 28 : 30) * textScale)
    let body: CGFloat
    switch item.presentationKind {
    case .text, .richText, .code, .unknown:
      let measured = CardTextLayout(item: item, scale: textScale, size: NSSize(width: max(1, width - contentInset * 2), height: 10_000))
        .height
      let maximum = isTile ? 142 : 154
      body = min(CGFloat(maximum) * textScale, max(44 * textScale, measured + CardTextLayout.verticalInset * 2))
    case .image, .video, .pdf: body = (isTile ? 132 : min(180, max(148, width * 0.40))) * textScale
    case .color: body = (isTile ? 112 : 120) * textScale
    case .url: body = (isTile ? 88 : 92) * textScale
    case .file, .audio: body = (isTile ? 82 : 88) * textScale
    }
    return CardLayout(
      width: width, height: header + ceil(body) + footer, headerHeight: header, footerHeight: footer, textScale: textScale,
      usesGalleryStyle: true)
  }

  var size: NSSize { NSSize(width: width, height: height) }

  func withWidth(_ width: CGFloat) -> CardLayout {
    var result = self
    result.width = width
    return result
  }

  func withHeight(_ height: CGFloat) -> CardLayout {
    var result = self
    result.height = height
    return result
  }

  func fittingGalleryHeight(_ availableHeight: CGFloat) -> CardLayout {
    guard usesGalleryStyle, availableHeight > 120, availableHeight < height else { return self }
    return withHeight(availableHeight)
  }

  func withLargerText(_ larger: Bool) -> CardLayout {
    var result = self
    result.textScale = larger ? 1.2 : 1
    return result
  }
}
