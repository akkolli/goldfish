import AppKit

enum ClipKind: Int, CaseIterable {
  case text = 0
  case url
  case image
  case richText
  case file
  case unknown
  case pdf
  case audio
  case color
  case code
  case video

  var displayName: String { presentation.displayName }
  var statusName: String { displayName == displayName.uppercased() ? displayName : displayName.capitalized }
  var canOpen: Bool { [.url, .file, .image, .pdf, .audio, .video].contains(self) }
  var canReveal: Bool { [.file, .image, .pdf, .audio, .video].contains(self) }

  func attachmentExtension(for payload: String = "") -> String? {
    switch self {
    case .pdf: return "pdf"
    case .audio: return "sound"
    case .richText: return "rtf"
    case .video: return VideoPayload.fileExtension(from: payload)
    default: return nil
    }
  }
  var usesManagedPayloadAttachment: Bool { attachmentExtension() != nil }

}

/// The type's identity is shared by capture feedback, search, cards, and filters.
/// Storage raw values remain declared separately in ClipKind.
struct ClipKindPresentation {
  let label: String
  let symbol: String
  let accentColor: NSColor
  let searchTerms: String
  let displayName: String

  init(_ label: String, _ symbol: String, _ rgb: (CGFloat, CGFloat, CGFloat)?, searchTerms: String? = nil, displayName: String? = nil) {
    self.label = label
    self.symbol = symbol
    accentColor = rgb.map { NSColor(calibratedRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } ?? .systemGray
    self.searchTerms = searchTerms ?? label.lowercased()
    self.displayName = displayName ?? (label == "PDF" ? label : label.lowercased())
  }
}

extension ClipKind {
  var presentation: ClipKindPresentation { Self.presentations[self]! }
  private static let presentations = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makePresentation()) })

  private func makePresentation() -> ClipKindPresentation {
    switch self {
    case .text: return .init("Text", "text.alignleft", (0.96, 0.64, 0.00))
    case .url: return .init("Link", "link", (0.02, 0.47, 0.98), searchTerms: "link url")
    case .image: return .init("Image", "photo", (1.00, 0.22, 0.25))
    case .richText: return .init("Rich Text", "doc.richtext", (0.94, 0.12, 0.48), searchTerms: "richtext rtf")
    case .file: return .init("File", "doc", (0.11, 0.68, 0.36))
    case .unknown: return .init("Unknown", "questionmark", nil, displayName: "item")
    case .pdf: return .init("PDF", "doc.text.fill", (0.55, 0.35, 0.88), searchTerms: "pdf document")
    case .audio: return .init("Audio", "music.note", (0.93, 0.12, 0.34), searchTerms: "audio sound")
    case .color: return .init("Color", "paintpalette", (0.00, 0.65, 0.74), searchTerms: "color swatch hex")
    case .code:
      return .init("Code", "chevron.left.forwardslash.chevron.right", (0.25, 0.38, 0.78), searchTerms: "code snippet source programming")
    case .video: return .init("Video", "film", (0.43, 0.32, 0.94), searchTerms: "video movie mp4 quicktime")
    }
  }
}
