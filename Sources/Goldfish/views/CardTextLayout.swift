import AppKit

/// Use the same native text layout for measuring and painting a card. NSString
/// bounding boxes can omit paragraph leading and truncate readable larger text.
final class CardTextLayout {
  static let verticalInset: CGFloat = 10
  private let storage: NSTextStorage
  private let manager = NSLayoutManager()
  private let container: NSTextContainer

  init(item: Clip, scale: CGFloat, size: NSSize) {
    let formatter = ClipPresentation()
    let isCode = item.presentationKind == .code
    let font = isCode ? NSFont.monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular) : NSFont.systemFont(ofSize: 13.5 * scale)
    storage = NSTextStorage(
      string: formatter.cardText(for: item),
      attributes: NativeUI.textAttributes(font: font, color: .labelColor, lineBreak: .byWordWrapping, lineSpacing: isCode ? 3 : 4))
    if let title = item.customTitle?.clipboardTrimmed, !title.isEmpty, storage.string.hasPrefix(title) {
      storage.addAttribute(
        .font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
        range: NSRange(location: 0, length: (title as NSString).length))
    }
    if isCode {
      for (expression, color) in Self.codeRules {
        for match in expression.matches(in: storage.string, range: NSRange(location: 0, length: storage.length)) {
          storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
      }
    }
    container = NSTextContainer(containerSize: NSSize(width: max(1, size.width), height: max(1, size.height)))
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byTruncatingTail
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
  }

  var height: CGFloat { ceil(manager.usedRect(for: container).height) }
  func draw(at origin: NSPoint) {
    let glyphs = manager.glyphRange(for: container)
    manager.drawBackground(forGlyphRange: glyphs, at: origin)
    manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
  }

  private static let codeRules: [(NSRegularExpression, NSColor)] = [
    (
      #"\b(func|let|var|class|struct|enum|return|if|else|import|def|const|function|async|await|public|private|for|in|true|false|nil|null)\b"#,
      NSColor.systemPurple
    ), (#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, NSColor.systemRed), (#"(?m)//.*$|#.*$"#, ShelfStyle.secondaryText),
  ].compactMap { pattern, color in (try? NSRegularExpression(pattern: pattern)).map { ($0, color) } }
}
