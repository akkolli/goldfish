import Foundation

struct ClipTextStatistics: Equatable {
  let characters: Int

  static func supports(_ item: Clip) -> Bool { [.text, .richText, .code, .unknown].contains(item.presentationKind) }

  init?(item: Clip) {
    guard Self.supports(item) else { return nil }
    // Count the stored text, not the truncated preview, custom title, or RTF path.
    let text = item.kind == .richText ? item.displayText : (item.payload.isEmpty ? item.displayText : item.payload)
    characters = text.count
  }

  var formattedCount: String { characters.formatted() }

  var accessibilityDescription: String { "\(formattedCount) \(characters == 1 ? "character" : "characters")" }
}
