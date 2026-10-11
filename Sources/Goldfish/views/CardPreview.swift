import AppKit

/// One clip is one accessible button. This view paints its content without
/// creating hundreds of text controls or extra keyboard stops in the history.
final class CardPreview: NSView {
  private let item: Clip
  var thumbnail: NSImage? { didSet { needsDisplay = true } }
  private let cardLayout: CardLayout
  private let formatter = ClipPresentation()
  private let sourceIcon: NSImage?
  let textStatistics: ClipTextStatistics?
  var index: Int { didSet { needsDisplay = true } }
  private static let appIcons = NSCache<NSString, NSImage>()

  init(item: Clip, thumbnail: NSImage?, layout: CardLayout, index: Int) {
    self.item = item
    self.thumbnail = thumbnail
    self.cardLayout = layout
    textStatistics = ClipTextStatistics(item: item)
    self.index = index
    if let bundleID = item.sourceAppBundleId {
      if let cached = Self.appIcons.object(forKey: bundleID as NSString) {
        sourceIcon = cached
      } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.appIcons.setObject(image, forKey: bundleID as NSString)
        sourceIcon = image
      } else {
        sourceIcon = nil
      }
    } else {
      sourceIcon = nil
    }
    super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
    autoresizingMask = [.width, .height]
    setAccessibilityElement(false)
    toolTip = [
      formatter.footerSourceText(for: item), textStatistics.map { $0.accessibilityDescription + " (including spaces and line breaks)" },
    ].compactMap { $0 }.joined(separator: "\n")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    NSBezierPath(roundedRect: bounds, xRadius: cardLayout.cornerRadius, yRadius: cardLayout.cornerRadius).clipped {
      let header = NSRect(x: 0, y: 0, width: bounds.width, height: cardLayout.headerHeight)
      let footer = NSRect(x: 0, y: bounds.height - cardLayout.footerHeight, width: bounds.width, height: cardLayout.footerHeight)
      let body = NSRect(x: 0, y: header.maxY, width: bounds.width, height: max(1, footer.minY - header.maxY))
      drawHeader(header)
      NSBezierPath(rect: body).clipped { drawBody(body) }
      drawFooter(footer)
    }
  }

  private func drawHeader(_ rect: NSRect) {
    let accent = formatter.accentColor(for: item.presentationKind)
    rect.fill(with: accent)
    let ink = ShelfStyle.foregroundColor(on: accent)
    let scale = cardLayout.textScale
    let inset = cardLayout.contentInset
    let kind =
      item.presentationKind == .code
      ? CodeSnippetPayload.languageLabel(from: item.payload) : formatter.kindLabel(for: item.presentationKind)
    drawText(
      kind, in: NSRect(x: inset, y: 8, width: rect.width - inset * 2 - 42, height: 19 * scale),
      font: .systemFont(ofSize: 12.5 * scale, weight: .semibold), color: ink)
    drawText(
      formatter.relativeDateText(for: item.createdAt),
      in: NSRect(x: inset, y: rect.height - 19 * scale, width: rect.width - inset * 2 - 42, height: 16 * scale),
      font: .systemFont(ofSize: 10.5 * scale), color: ink.withAlphaComponent(0.88))
    let iconSize: CGFloat = cardLayout.width < 260 ? 28 : 32
    let iconRect = NSRect(x: rect.width - inset - iconSize, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize)
    if let sourceIcon {
      sourceIcon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
      NSBezierPath(roundedRect: iconRect, xRadius: cardLayout.width < 260 ? 7 : 8, yRadius: cardLayout.width < 260 ? 7 : 8).fill(
        with: ink.withAlphaComponent(0.10))
      let symbolInset: CGFloat = cardLayout.width < 260 ? 6 : 7
      shelfDrawSymbol(
        formatter.headerBadgeSymbol(for: item.presentationKind), in: iconRect.insetBy(dx: symbolInset, dy: symbolInset), color: ink)
    }
  }

  private func drawBody(_ rect: NSRect) {
    switch item.presentationKind {
    case .text, .richText, .unknown, .code:
      let isCode = item.presentationKind == .code
      if isCode { rect.fill(with: formatter.accentColor(for: .code).withAlphaComponent(0.055)) }
      let contentRect = rect.insetBy(dx: cardLayout.contentInset, dy: CardTextLayout.verticalInset)
      CardTextLayout(item: item, scale: cardLayout.textScale, size: contentRect.size).draw(at: contentRect.origin)
    case .image:
      if let thumbnail {
        drawImage(thumbnail, in: rect.insetBy(dx: 10, dy: 8))
      } else {
        drawFileIdentity(in: rect, symbol: "photo", title: formatter.imageTitle(for: item), detail: "Image preview unavailable")
      }
    case .url: drawLink(in: rect)
    case .color: drawColor(in: rect)
    case .pdf:
      if let thumbnail {
        rect.fill(with: NSColor.labelColor.withAlphaComponent(0.035))
        drawImage(thumbnail, in: rect.insetBy(dx: 16, dy: 10))
      } else {
        drawFileIdentity(
          in: rect, symbol: "doc.richtext", title: formatter.fileTitle(for: item, fallback: "PDF document"), detail: "Preview unavailable")
      }
    case .file:
      let count = FilePayload.paths(from: item.payload).count
      drawFileIdentity(
        in: rect, symbol: count > 1 ? "doc.on.doc" : "doc", title: formatter.titleText(for: item),
        detail: count > 1 ? "Select to copy all \(count) files" : formatter.fileKindText(from: item.payload, fallback: "File"), icon: thumbnail)
    case .audio: drawFileIdentity(in: rect, symbol: "waveform", title: formatter.audioTitle(for: item), detail: "Audio clip")
    case .video:
      if let thumbnail {
        drawImage(thumbnail, in: rect)
        let circle = NSRect(x: rect.midX - 20, y: rect.midY - 20, width: 40, height: 40)
        NSBezierPath(ovalIn: circle).fill(with: NSColor.black.withAlphaComponent(0.55))
        shelfDrawSymbol("play.fill", in: circle.insetBy(dx: 12, dy: 12).offsetBy(dx: 1, dy: 0), color: .white)
      } else {
        drawFileIdentity(in: rect, symbol: "play.rectangle", title: formatter.videoTitle(for: item), detail: "Video clip")
      }
    }
  }

  private func drawLink(in rect: NSRect) {
    let host = formatter.webHostText(from: item.linkAddress) ?? "Link"
    let title = formatter.titleText(for: item)
    let accent = formatter.linkVisualColor(for: host)
    if let thumbnail {
      drawImage(thumbnail, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(40, rect.height - 56)))
      drawText(
        title, in: NSRect(x: 16, y: rect.maxY - 49, width: rect.width - 32, height: 22),
        font: .systemFont(ofSize: 14 * cardLayout.textScale, weight: .medium), color: .labelColor)
      drawText(
        host, in: NSRect(x: 16, y: rect.maxY - 27, width: rect.width - 32, height: 18),
        font: .systemFont(ofSize: 11.5 * cardLayout.textScale), color: ShelfStyle.secondaryText)
      return
    }
    if cardLayout.width < 260 {
      drawCompactIdentity(in: rect, title: title, detail: host, detailSize: 11.5) { tile in
        NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill(with: accent.withAlphaComponent(0.13))
        drawText(
          String(host.prefix(1)).uppercased(), in: tile.insetBy(dx: 3, dy: 3), font: .systemFont(ofSize: 13, weight: .semibold),
          color: .labelColor, alignment: .center)
      }
      return
    }
    let tile = NSRect(x: 16, y: rect.minY + 12, width: 44, height: 44)
    NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill(with: accent.withAlphaComponent(0.13))
    drawText(
      String(host.prefix(1)).uppercased(), in: tile.insetBy(dx: 6, dy: 7), font: .systemFont(ofSize: 24, weight: .medium),
      color: .labelColor, alignment: .center)
    drawText(
      title, in: NSRect(x: 72, y: rect.minY + 11, width: rect.width - 88, height: 24 * cardLayout.textScale),
      font: .systemFont(ofSize: 15 * cardLayout.textScale, weight: .semibold), color: .labelColor)
    drawText(
      host, in: NSRect(x: 72, y: rect.minY + 36 * cardLayout.textScale, width: rect.width - 88, height: 20 * cardLayout.textScale),
      font: .systemFont(ofSize: 12 * cardLayout.textScale), color: ShelfStyle.secondaryText)
    let address = formatter.webAddressText(from: item.linkAddress) ?? item.linkAddress
    if address != host {
      drawText(
        address,
        in: NSRect(
          x: 16, y: rect.minY + 68 * cardLayout.textScale, width: rect.width - 32, height: max(18, rect.height - 74 * cardLayout.textScale)),
        font: .systemFont(ofSize: 12 * cardLayout.textScale), color: ShelfStyle.secondaryText, wraps: true)
    }
  }

  private func drawFileIdentity(in rect: NSRect, symbol: String, title: String, detail: String, icon: NSImage? = nil) {
    if cardLayout.width < 260 {
      drawCompactIdentity(in: rect, title: title, detail: detail, detailSize: 11) { iconRect in
        if let icon {
          drawImage(icon, in: iconRect)
        } else {
          shelfDrawSymbol(symbol, in: iconRect, color: formatter.accentColor(for: item.presentationKind))
        }
      }
      return
    }
    let iconRect = NSRect(x: 18, y: rect.minY + 14, width: 40, height: 46)
    if let icon {
      drawImage(icon, in: iconRect)
    } else {
      shelfDrawSymbol(symbol, in: iconRect.insetBy(dx: 2, dy: 4), color: formatter.accentColor(for: item.presentationKind))
    }
    drawText(
      title, in: NSRect(x: 72, y: rect.minY + 14, width: rect.width - 88, height: 38 * cardLayout.textScale),
      font: .systemFont(ofSize: 14 * cardLayout.textScale, weight: .medium), color: .labelColor, wraps: true)
    drawText(
      detail, in: NSRect(x: 72, y: rect.minY + 58 * cardLayout.textScale, width: rect.width - 88, height: 24 * cardLayout.textScale),
      font: .systemFont(ofSize: 11.5 * cardLayout.textScale), color: ShelfStyle.secondaryText)
  }

  private func drawCompactIdentity(in rect: NSRect, title: String, detail: String, detailSize: CGFloat, icon: (NSRect) -> Void) {
    let inset = cardLayout.contentInset
    let scale = cardLayout.textScale
    let tile = NSRect(x: inset, y: rect.minY + 10, width: 24, height: 24)
    icon(tile)
    drawText(
      detail, in: NSRect(x: inset + 32, y: tile.minY + 3, width: rect.width - inset * 2 - 32, height: 20 * scale),
      font: .systemFont(ofSize: detailSize * scale), color: ShelfStyle.secondaryText)
    drawText(
      title, in: NSRect(x: inset, y: tile.maxY + 8, width: rect.width - inset * 2, height: rect.height - 48),
      font: .systemFont(ofSize: 14 * scale, weight: .medium), color: .labelColor, wraps: true)
  }

  private func drawColor(in rect: NSRect) {
    guard let color = ColorPayload.color(from: item.payload)?.usingColorSpace(.sRGB) else { return }
    rect.fill(with: NSColor(white: 0.96, alpha: 1))
    if color.alphaComponent < 1 {
      NSColor(white: 0.88, alpha: 1).setFill()
      for row in 0...Int(rect.height / 12) {
        for column in 0...Int(rect.width / 12) where (row + column) % 2 == 0 {
          NSRect(x: CGFloat(column) * 12, y: rect.minY + CGFloat(row) * 12, width: 12, height: 12).fill()
        }
      }
    }
    rect.fill(with: color)
    let blended = NSColor(
      srgbRed: color.redComponent * color.alphaComponent + 0.92 * (1 - color.alphaComponent),
      green: color.greenComponent * color.alphaComponent + 0.92 * (1 - color.alphaComponent),
      blue: color.blueComponent * color.alphaComponent + 0.92 * (1 - color.alphaComponent), alpha: 1)
    let ink = ShelfStyle.foregroundColor(on: blended)
    drawText(
      ColorPayload.displayHex(from: item.payload), in: NSRect(x: 16, y: rect.midY - 23, width: rect.width - 32, height: 32),
      font: .monospacedSystemFont(ofSize: (cardLayout.width < 260 ? 19 : 23) * cardLayout.textScale, weight: .medium), color: ink,
      alignment: .center)
    drawText(
      ColorPayload.componentSummary(from: item.payload), in: NSRect(x: 16, y: rect.midY + 14, width: rect.width - 32, height: 22),
      font: .systemFont(ofSize: 11.5 * cardLayout.textScale), color: ink, alignment: .center)
  }

  private func drawFooter(_ rect: NSRect) {
    let source = item.sourceApp?.clipboardTrimmed
    let label =
      item.collectionName
      ?? ((thumbnail != nil && [.pdf, .video].contains(item.presentationKind))
        ? formatter.titleText(for: item) : (source?.isEmpty == false ? source! : "Copied clip"))
    let shortcut = index < 9 ? "⌘\(index + 1)" : ""
    let inset = cardLayout.contentInset
    let scale = cardLayout.textScale
    let font = NSFont.systemFont(ofSize: 11 * scale)
    let ink = ShelfStyle.secondaryText
    let labelY = rect.minY + max(0, (rect.height - 16 * scale) / 2 - 2)
    var trailingX = rect.maxX - inset

    // Pack compact metadata from the trailing edge, giving the source all
    // remaining space. Native measurement keeps counts and shortcuts apart.
    if !shortcut.isEmpty {
      let width = ceil((shortcut as NSString).size(withAttributes: [.font: font]).width)
      drawText(
        shortcut, in: NSRect(x: trailingX - width, y: labelY, width: width, height: 16 * scale), font: font, color: ink, alignment: .right)
      trailingX -= width + 10 * scale
    }
    if item.isPinned {
      shelfDrawSymbol(
        "pin.fill", in: NSRect(x: trailingX - 9 * scale, y: labelY + 2 * scale, width: 9 * scale, height: 11 * scale), color: ink)
      trailingX -= 17 * scale
    }
    if let textStatistics {
      let count = characterCountLabel(textStatistics.formattedCount, scale: scale, color: ink)
      let countWidth = ceil(count.size().width)
      count.draw(
        with: NSRect(x: trailingX - countWidth, y: labelY, width: countWidth, height: 16 * scale),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      trailingX -= countWidth + 10 * scale
    }
    drawText(label, in: NSRect(x: inset, y: labelY, width: max(0, trailingX - inset), height: 16 * scale), font: font, color: ink)
  }

  private func drawImage(_ image: NSImage, in rect: NSRect) {
    guard image.size.width > 0, image.size.height > 0, rect.width > 0, rect.height > 0 else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  private func characterCountLabel(_ count: String, scale: CGFloat, color: NSColor) -> NSAttributedString {
    let pointSize = 10.5 * scale
    let result = NSMutableAttributedString()
    let attachment = NSTextAttachment()
    let symbol = NSImage(systemSymbolName: "character", accessibilityDescription: nil)?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    symbol?.isTemplate = true
    attachment.image = symbol
    // Text attachments share the following digits' baseline. Keeping the
    // image at its configured size avoids the optical drift from stretching a
    // symbol into an arbitrary drawing rectangle.
    result.append(NSAttributedString(attachment: attachment))
    result.append(
      NSAttributedString(
        string: " \(count)",
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular), .foregroundColor: color]))
    result.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: result.length))
    return result
  }

  private func drawText(
    _ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, wraps: Bool = false
  ) {
    guard rect.width > 0, rect.height > 0 else { return }
    let attributes = NativeUI.textAttributes(
      font: font, color: color, lineBreak: wraps ? .byWordWrapping : .byTruncatingTail, alignment: alignment, lineSpacing: 3)
    NSAttributedString(string: text, attributes: attributes).draw(
      with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
  }

}
