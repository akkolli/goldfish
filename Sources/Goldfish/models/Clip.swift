import AppKit

enum ShelfFilter: Int {
  case mostRecent = 0
  case mostUsed
  case images
  case links
  case text
  case pinned
  case files
  case audio
  case colors
  case code
  case videos

  static let allCases: [ShelfFilter] = [.mostRecent, .mostUsed, .text, .links, .images, .colors, .audio, .videos, .files, .pinned, .code]

  // Each filter's membership and native rail identity live together. Raw values
  // and the visible ordering above remain separate compatibility contracts.
  private var definition: (title: String, kinds: [ClipKind]?, symbol: String, tint: NSColor) {
    switch self {
    case .mostRecent: return ("Most Recent", nil, "square.grid.2x2", .secondaryLabelColor)
    case .mostUsed: return ("Most Used", nil, "square.grid.2x2", .secondaryLabelColor)
    case .pinned: return ("Pinned", nil, "square.grid.2x2", .secondaryLabelColor)
    case .text: return ("Text", [.text, .richText, .code], "text.alignleft", .systemOrange)
    case .images: return ("Images", [.image], "photo", .systemPink)
    case .links: return ("Links", [.url], "link", .systemBlue)
    case .files: return ("Files", [.file, .pdf], "doc", .systemTeal)
    case .audio: return ("Audio", [.audio], "waveform", .systemOrange)
    case .colors: return ("Colors", [.color], "paintpalette", .systemIndigo)
    case .code: return ("Code", [.code], "chevron.left.forwardslash.chevron.right", .systemPurple)
    case .videos: return ("Videos", [.video], "play.rectangle", .systemRed)
    }
  }
  var title: String { definition.title }
  var visuals: (String, NSColor) { (definition.symbol, definition.tint) }

  func includes(_ item: Clip) -> Bool { self == .pinned ? item.isPinned : (definition.kinds?.contains(item.presentationKind) ?? true) }

}

enum PinboardNames { static func normalizedName(_ value: String?) -> String? { value?.clipboardLabel(limit: 40) } }

struct Clip: Codable, Equatable {
  // Persist the raw kind so archive import can skip future types while still
  // decoding and validating the complete record. Live clips use the typed API.
  private var kindValue: Int
  var kind: ClipKind {
    get { ClipKind(rawValue: kindValue) ?? .unknown }
    set { kindValue = newValue.rawValue }
  }
  var hasKnownKind: Bool { ClipKind(rawValue: kindValue) != nil }
  private enum CodingKeys: String, CodingKey {
    case kindValue = "kind"
    case id, displayText, payload, payloadHash, createdAt, lastUsedAt, useCount, sourceApp, imagePath, thumbnailPath, isPinned
    case sourceAppBundleId, ocrText, collectionName, customTitle, sourceDeviceName
  }
  var id: UUID
  var displayText: String
  var payload: String
  var payloadHash: String
  var createdAt: Date
  var lastUsedAt: Date
  var useCount: Int
  var sourceApp: String?
  var imagePath: String?
  var thumbnailPath: String?
  var isPinned: Bool
  var sourceAppBundleId: String?
  var ocrText: String?
  var collectionName: String?
  var customTitle: String?
  var sourceDeviceName: String?

  /// A URL copied as plain or rich text is still recognizable as a link. Preserve the
  /// original clipboard representation for paste and archive compatibility.
  var presentationKind: ClipKind { linkURL == nil ? kind : .url }

  var linkURL: URL? {
    guard [.url, .text, .richText, .unknown].contains(kind) else { return nil }
    let candidate = (kind == .richText ? displayText : payload).clipboardTrimmed
    guard !candidate.contains(where: { $0.isWhitespace }), let url = URL(string: candidate),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false
    else { return nil }
    return url
  }

  var linkAddress: String { linkURL?.absoluteString ?? payload }

  var searchableFields: [String?] {
    [kind.presentation.searchTerms, displayText, payload, customTitle, sourceApp, sourceAppBundleId, collectionName, sourceDeviceName]
  }

  var searchableText: String { searchableFields.compactMap { $0?.lowercased() }.joined(separator: " ") }

  var effectiveSourceDeviceName: String { Clip.normalizedDeviceName(sourceDeviceName) ?? Self.localDeviceName }

  init(
    id: UUID, kind: ClipKind, displayText: String, payload: String, payloadHash: String, createdAt: Date, lastUsedAt: Date, useCount: Int,
    sourceApp: String? = nil, imagePath: String? = nil, thumbnailPath: String? = nil, isPinned: Bool = false,
    sourceAppBundleId: String? = nil, ocrText: String? = nil, collectionName: String? = nil, customTitle: String? = nil,
    sourceDeviceName: String? = Clip.localDeviceName
  ) {
    self.id = id
    kindValue = kind.rawValue
    self.displayText = displayText
    self.payload = payload
    self.payloadHash = payloadHash
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.useCount = min(Int(Int32.max), max(0, useCount))
    self.sourceApp = sourceApp
    self.imagePath = imagePath
    self.thumbnailPath = thumbnailPath
    self.isPinned = isPinned
    self.sourceAppBundleId = sourceAppBundleId
    self.ocrText = ocrText
    self.collectionName = collectionName
    self.customTitle = Clip.normalizedCustomTitle(customTitle)
    self.sourceDeviceName = Clip.normalizedDeviceName(sourceDeviceName)
  }

  static func normalizedCustomTitle(_ value: String?) -> String? { value?.clipboardLabel(limit: 80) }

  static var localDeviceName: String {
    normalizedDeviceName(Host.current().localizedName) ?? normalizedDeviceName(Host.current().name) ?? normalizedDeviceName(
      ProcessInfo.processInfo.hostName) ?? "This Mac"
  }

  static func normalizedDeviceName(_ value: String?) -> String? { value?.clipboardLabel(limit: 60) }
}
