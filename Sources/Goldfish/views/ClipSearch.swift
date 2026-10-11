import Foundation

final class ClipSearch {
  private static let searchDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    let calendar = Calendar.clipboardSearchCalendar
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let searchLocale = Locale(identifier: "en_US_POSIX")
  private static let fallbackSourceDeviceName = Clip.localDeviceName

  fileprivate enum Field: String {
    case app, device, collection

    static func named(_ key: String) -> Field? {
      switch key {
      case "app", "source", "from": return .app
      case "device", "devices", "machine", "computer": return .device
      case "collection", "folder", "list", "pinboard", "pinboards", "board", "boards": return .collection
      default: return nil
      }
    }
  }

  fileprivate struct StructuredFilterMatcher {
    let tokens: [String]
    let exactValue: String?
  }

  fileprivate struct StructuredFilterValue {
    let value: String
    let isExact: Bool
  }

  struct Query {
    var textTokens: [String] = []
    fileprivate var fields: [Field: [StructuredFilterMatcher]] = [:]
    fileprivate var typeKinds: Set<ClipKind> = []
    fileprivate var createdAfter: Date?
    fileprivate var createdBefore: Date?
    fileprivate var pinned: Bool?

    var isEmpty: Bool {
      textTokens.isEmpty && fields.isEmpty && typeKinds.isEmpty && createdAfter == nil && createdBefore == nil && pinned == nil
    }
  }

  private struct SearchDocument {
    let fingerprint: [String?]
    let text: String
    let textIncludingOCR: String
    let fields: [Field: [String]]
  }

  private var documentsByItemID: [UUID: SearchDocument] = [:]

  func pruneDocuments(keeping keep: (UUID) -> Bool) { documentsByItemID = documentsByItemID.filter { keep($0.key) } }

  func matches(_ item: Clip, query: Query, includeImageText: Bool) -> Bool {
    let needsSearchDocument = !query.textTokens.isEmpty || !query.fields.isEmpty
    let document = needsSearchDocument ? searchDocument(for: item) : nil

    if !query.textTokens.isEmpty {
      guard let document else { return false }
      let text = includeImageText ? document.textIncludingOCR : document.text
      guard query.textTokens.allSatisfy({ text.contains($0) }) else { return false }
    }

    for (field, groups) in query.fields {
      guard let values = document?.fields[field], !values.isEmpty, matches(groups, exactValues: values, text: values.joined(separator: " "))
      else { return false }
    }

    if !query.typeKinds.isEmpty, !query.typeKinds.contains(item.presentationKind) { return false }

    if let pinned = query.pinned, item.isPinned != pinned { return false }

    if let createdAfter = query.createdAfter, item.createdAt < createdAfter { return false }

    if let createdBefore = query.createdBefore, item.createdAt >= createdBefore { return false }

    return true
  }

  private func matches(_ groups: [StructuredFilterMatcher], exactValues: [String], text: String) -> Bool {
    groups.contains { group in
      if let exact = group.exactValue { return exactValues.contains(exact) }
      return group.tokens.allSatisfy { text.contains($0) }
    }
  }

  private func searchDocument(for item: Clip) -> SearchDocument {
    let fingerprint = [String(item.kind.rawValue)] + item.searchableFields + [item.ocrText]
    if let cached = documentsByItemID[item.id], cached.fingerprint == fingerprint { return cached }

    let sourceDeviceName = effectiveSourceDeviceName(for: item)
    let text = normalized(item.searchableText)
    let normalizedOCR = item.ocrText.map(normalized) ?? ""
    let textIncludingOCR = normalizedOCR.isEmpty ? text : "\(text) \(normalizedOCR)"
    let sourceValues = [item.sourceApp, item.sourceAppBundleId].compactMap { $0 }.map(normalizedStructuredValue).filter { !$0.isEmpty }
    let document = SearchDocument(
      fingerprint: fingerprint, text: text, textIncludingOCR: textIncludingOCR,
      fields: [
        .app: sourceValues, .device: [normalizedStructuredValue(sourceDeviceName)],
        .collection: item.collectionName.map(normalizedStructuredValue).flatMap { $0.isEmpty ? nil : [$0] } ?? [],
      ])
    documentsByItemID[item.id] = document
    return document
  }

  private func effectiveSourceDeviceName(for item: Clip) -> String {
    Clip.normalizedDeviceName(item.sourceDeviceName) ?? Self.fallbackSourceDeviceName
  }

  func parse(_ query: String) -> Query {
    var parsed = Query()
    for part in searchParts(from: query) {
      guard !part.isEmpty else { continue }
      guard let delimiter = part.firstIndex(of: ":") else {
        parsed.textTokens.append(contentsOf: searchTokens(from: part))
        continue
      }

      let key = normalized(String(part[..<delimiter]))
      let value = String(part[part.index(after: delimiter)...]).clipboardTrimmed
      guard !value.isEmpty, applyStructuredSearchToken(key: key, value: value, to: &parsed) else {
        parsed.textTokens.append(contentsOf: searchTokens(from: part))
        continue
      }
    }
    return parsed
  }

  @discardableResult private func applyStructuredSearchToken(key: String, value: String, to query: inout Query) -> Bool {
    if let field = Field.named(key) {
      let groups = structuredTokenGroups(from: value)
      guard !groups.isEmpty else { return false }
      query.fields[field, default: []].append(contentsOf: groups)
      return true
    }
    switch key {
    case "type", "kind":
      var matchedKinds = Set<ClipKind>()
      for segment in structuredValueSegments(from: value) {
        guard let kinds = itemKinds(matching: segment.value), !kinds.isEmpty else { return false }
        matchedKinds.formUnion(kinds)
      }
      guard !matchedKinds.isEmpty else { return false }
      query.typeKinds.formUnion(matchedKinds)
      return true
    case "pin", "pinned":
      guard let pinned = booleanValue(from: value) else { return false }
      query.pinned = pinned
      return true
    case "after", "since":
      guard let start = startOfDay(from: value) else { return false }
      query.createdAfter = max(query.createdAfter ?? start, start)
      return true
    case "before", "until":
      guard let start = startOfDay(from: value) else { return false }
      query.createdBefore = min(query.createdBefore ?? start, start)
      return true
    case "on", "date":
      guard let start = startOfDay(from: value), let end = Calendar.clipboardSearchCalendar.date(byAdding: .day, value: 1, to: start) else {
        return false
      }
      query.createdAfter = max(query.createdAfter ?? start, start)
      query.createdBefore = min(query.createdBefore ?? end, end)
      return true
    default: return false
    }
  }

  private func searchParts(from query: String) -> [String] {
    splitRespectingQuotes(query, on: \.isWhitespace).map(\.clipboardTrimmed).filter { !$0.isEmpty }
  }

  private func structuredValueSegments(from value: String) -> [StructuredFilterValue] {
    splitStructuredValues(from: value).compactMap { segment in
      let trimmed = segment.clipboardTrimmed
      guard !trimmed.isEmpty else { return nil }
      if let unquoted = unquotedStructuredValue(trimmed) {
        let normalized = normalizedStructuredValue(unquoted)
        return normalized.isEmpty ? nil : StructuredFilterValue(value: normalized, isExact: true)
      }
      let normalized = normalizedStructuredValue(trimmed)
      return normalized.isEmpty ? nil : StructuredFilterValue(value: normalized, isExact: false)
    }
  }

  private func structuredTokenGroups(from value: String) -> [StructuredFilterMatcher] {
    structuredValueSegments(from: value).compactMap { segment in
      let tokens = searchTokens(from: segment.value)
      guard !tokens.isEmpty else { return nil }
      return StructuredFilterMatcher(tokens: tokens, exactValue: segment.isExact ? segment.value : nil)
    }
  }

  private func splitStructuredValues(from value: String) -> [String] { splitRespectingQuotes(value) { $0 == "," } }

  private func splitRespectingQuotes(_ value: String, on boundary: (Character) -> Bool) -> [String] {
    var segments: [String] = []
    var current = ""
    var quotedBy: Character?
    var isEscaping = false
    for character in value {
      if isEscaping {
        current += "\\\(character)"
        isEscaping = false
      } else if character == "\\", quotedBy != nil {
        isEscaping = true
      } else if character == "\"" || character == "'" {
        if quotedBy == character { quotedBy = nil } else if quotedBy == nil { quotedBy = character }
        current.append(character)
      } else if boundary(character), quotedBy == nil {
        segments.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if isEscaping { current.append("\\") }
    return segments + [current]
  }

  private func unquotedStructuredValue(_ value: String) -> String? {
    guard let first = value.first, first == "\"" || first == "'", value.last == first, value.count >= 2 else { return nil }
    // Unescape any following character, including newlines; a trailing slash stays literal.
    return String(value.dropFirst().dropLast()).replacingOccurrences(of: #"\\([\s\S])"#, with: "$1", options: .regularExpression)
  }

  private func normalizedStructuredValue(_ value: String) -> String { normalized(value) }

  private func itemKinds(matching value: String) -> Set<ClipKind>? {
    switch value {
    case "text", "plain": return [.text]
    case "richtext", "rich-text", "rtf", "html": return [.richText]
    case "note", "notes", "writing": return [.text, .richText]
    case "code", "snippet", "snippets", "source", "programming", "script", "scripts", "json", "css", "sql": return [.code]
    case "link", "links", "url", "urls", "web": return [.url]
    case "image", "images", "photo", "photos", "picture", "pictures": return [.image]
    case "file", "files", "finder": return [.file, .pdf]
    case "pdf", "pdfs", "document", "documents": return [.pdf]
    case "audio", "sound", "music": return [.audio]
    case "video", "videos", "movie", "movies", "mp4", "quicktime", "mov": return [.video]
    case "color", "colors", "swatch", "swatches", "hex": return [.color]
    case "unknown", "item": return [.unknown]
    default: return nil
    }
  }

  private func booleanValue(from value: String) -> Bool? {
    switch normalized(value) {
    case "1", "true", "yes", "y", "on": return true
    case "0", "false", "no", "n", "off": return false
    default: return nil
    }
  }

  private func startOfDay(from value: String) -> Date? {
    guard let date = Self.searchDateFormatter.date(from: value) else { return nil }
    return Calendar.clipboardSearchCalendar.startOfDay(for: date)
  }

  private func searchTokens(from query: String) -> [String] {
    normalized(query).split { character in character.isWhitespace || character.isPunctuation }.map(String.init)
  }

  func normalized(_ value: String) -> String {
    value.clipboardTrimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Self.searchLocale).lowercased()
  }
}

extension Calendar {
  static var clipboardSearchCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }
}
