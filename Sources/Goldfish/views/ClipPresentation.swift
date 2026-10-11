import AppKit

struct ClipPresentation {
  func titleText(for item: Clip) -> String {
    if let customTitle = item.customTitle?.clipboardTrimmed, !customTitle.isEmpty { return customTitle }

    switch item.presentationKind {
    case .url: return linkTitle(for: item)
    case .file: return fileTitle(for: item, fallback: "File")
    case .pdf: return fileTitle(for: item, fallback: "PDF document")
    case .audio: return audioTitle(for: item)
    case .video: return videoTitle(for: item)
    case .image: return imageTitle(for: item)
    case .color: return ColorPayload.displayHex(from: item.payload)
    case .code:
      return item.payload.components(separatedBy: .newlines).map(\.clipboardTrimmed).first { !$0.isEmpty && !$0.hasPrefix("```") }
        ?? CodeSnippetPayload.title(from: item.payload)
    default: break
    }

    let candidate = firstUsefulLine(item.displayText).isEmpty ? firstUsefulLine(item.payload) : firstUsefulLine(item.displayText)
    if candidate.isEmpty || looksInternal(candidate) { return "Copied \(kindLabel(for: item.kind).lowercased())" }
    return candidate
  }

  func cardText(for item: Clip) -> String {
    var text = item.kind == .richText ? item.displayText : (item.payload.clipboardTrimmed.isEmpty ? item.displayText : item.payload)
    if item.kind == .code, text.hasPrefix("```") {
      var lines = text.components(separatedBy: .newlines)
      if !lines.isEmpty { lines.removeFirst() }
      if lines.last?.clipboardTrimmed == "```" { lines.removeLast() }
      text = lines.joined(separator: "\n")
    }
    if let title = item.customTitle?.clipboardTrimmed, !title.isEmpty, !text.hasPrefix(title) { text = title + "\n\n" + text }
    return String(text.clipboardTrimmed.prefix(1800))
  }

  func footerSourceText(for item: Clip) -> String? {
    let source = item.sourceApp?.clipboardTrimmed
    let device = sourceDeviceText(for: item)
    let usage = usageText(for: item.useCount)

    var parts: [String] = []
    if let source, !source.isEmpty {
      if let device { parts.append("\(source) on \(device)") } else { parts.append(source) }
    } else if let device {
      parts.append(device)
    }
    if let usage { parts.append(usage) }
    return parts.isEmpty ? nil : parts.joined(separator: " - ")
  }

  func sourceDeviceText(for item: Clip) -> String? {
    guard let device = Clip.normalizedDeviceName(item.sourceDeviceName) else { return nil }
    let localDevice = Clip.localDeviceName
    guard device.caseInsensitiveCompare(localDevice) != .orderedSame else { return nil }
    return device
  }

  func usageText(for useCount: Int) -> String? {
    guard useCount > 0 else { return nil }
    return useCount == 1 ? "Used once" : "Used \(useCount) times"
  }

  func linkTitle(for item: Clip) -> String {
    let display = firstUsefulLine(item.displayText)
    let payload = firstUsefulLine(item.linkAddress)
    if !display.isEmpty, display != payload, !looksInternal(display), !looksGenericLink(display), !looksLikeWebAddress(display) {
      return display
    }
    if let pageTitle = webPageTitleText(from: item.linkAddress) { return pageTitle }
    if let hostTitle = webHostTitleText(from: item.linkAddress) { return hostTitle }
    return webHostText(from: item.linkAddress) ?? "Link"
  }

  func fileTitle(for item: Clip, fallback: String) -> String {
    let paths = FilePayload.paths(from: item.payload)
    if item.kind == .file, paths.count > 1 { return "\(paths.count) files" }

    let display = firstUsefulLine(item.displayText)
    if !display.isEmpty, !looksInternal(display), !looksGenericFileTitle(display), !display.hasPrefix("/"), !display.hasPrefix("file://") {
      return display
    }

    if let name = fileName(from: item.payload), !name.isEmpty, !looksInternal(name) { return name }

    return fallback
  }

  func imageTitle(for item: Clip) -> String {
    let display = firstUsefulLine(item.displayText)
    if !display.isEmpty, !looksInternal(display), display.lowercased() != "image" { return display }

    let ocr = firstUsefulLine(item.ocrText ?? "")
    if !ocr.isEmpty, !looksInternal(ocr) { return ocr }

    return "Image"
  }

  func audioTitle(for item: Clip) -> String { fileTitle(for: item, fallback: "Audio clip") }

  func videoTitle(for item: Clip) -> String { fileTitle(for: item, fallback: "Video clip") }

  func webComponents(from value: String) -> URLComponents? {
    let trimmed = value.clipboardTrimmed
    guard !trimmed.isEmpty else { return nil }
    if let components = URLComponents(string: trimmed), components.host?.isEmpty == false { return components }
    if !trimmed.contains("://"), let components = URLComponents(string: "https://\(trimmed)"), components.host?.isEmpty == false {
      return components
    }
    return nil
  }

  func webHostText(from value: String) -> String? {
    guard let host = webComponents(from: value)?.host?.clipboardTrimmed, !host.isEmpty else { return nil }
    return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  func webAddressText(from value: String) -> String? {
    guard let components = webComponents(from: value), let host = webHostText(from: value) else { return nil }

    var address = host
    let path = components.path.clipboardTrimmed
    if !path.isEmpty, path != "/" { address += path }
    return address
  }

  func webPageTitleText(from value: String) -> String? {
    guard let components = webComponents(from: value) else { return nil }
    let segments = components.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }.map {
      $0.clipboardTrimmed
    }.filter { !$0.isEmpty }

    for segment in segments.reversed() where !isLikelyVersionPathSegment(segment) {
      if let title = humanReadableWebTitle(from: segment) { return title }
    }
    return nil
  }

  func webHostTitleText(from value: String) -> String? {
    guard let host = webHostText(from: value) else { return nil }
    let labels = host.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    guard let label = labels.first else { return nil }
    return humanReadableWebTitle(from: label)
  }

  func humanReadableWebTitle(from value: String) -> String? {
    var slug = value.clipboardTrimmed
    guard !slug.isEmpty else { return nil }
    guard UUID(uuidString: slug) == nil,
      !(slug.count > 20 && !slug.contains("-") && !slug.contains("_") && slug.contains(where: \.isNumber))
    else { return nil }
    if let dotIndex = slug.lastIndex(of: ".") {
      let extensionText = slug[slug.index(after: dotIndex)...]
      let base = slug[..<dotIndex]
      if !base.isEmpty, (1...6).contains(extensionText.count), extensionText.allSatisfy(\.isLetter) { slug = String(base) }
    }

    let words = slug.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !isLikelyVersionPathSegment($0) }
    guard !words.isEmpty else { return nil }

    let title = words.map(formattedWebTitleWord).joined(separator: " ").clipboardTrimmed
    guard !title.isEmpty else { return nil }
    return String(title.prefix(70))
  }

  func formattedWebTitleWord(_ word: String) -> String {
    let lower = word.lowercased()
    switch lower {
    case "api": return "API"
    case "appkit": return "AppKit"
    case "ios": return "iOS"
    case "macos": return "macOS"
    case "nscolor": return "NSColor"
    case "pdf": return "PDF"
    case "ui": return "UI"
    case "url": return "URL"
    case "wwdc": return "WWDC"
    case "xcode": return "Xcode"
    default:
      if word.count <= 5, word.allSatisfy(\.isUppercase) { return word }
      return lower.prefix(1).uppercased() + lower.dropFirst()
    }
  }

  func isLikelyVersionPathSegment(_ value: String) -> Bool {
    var text = value.clipboardTrimmed.lowercased()
    if text.hasPrefix("v"), text.count > 1 { text.removeFirst() }
    guard !text.isEmpty else { return false }
    return text.allSatisfy { character in character.isNumber || character == "." || character == "-" || character == "_" }
  }

  func linkVisualColor(for host: String) -> NSColor {
    let palette = [
      NSColor(calibratedRed: 0.02, green: 0.47, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.72, alpha: 1),
      NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.34, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.88, alpha: 1),
      NSColor(calibratedRed: 0.93, green: 0.12, blue: 0.34, alpha: 1), NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.00, alpha: 1),
    ]
    var hash: UInt64 = 1_469_598_103_934_665_603
    for scalar in host.lowercased().unicodeScalars {
      hash ^= UInt64(scalar.value)
      hash &*= 1_099_511_628_211
    }
    return palette[Int(hash % UInt64(palette.count))]
  }

  func fileURL(from value: String) -> URL? { FilePayload.urls(from: value).first }

  func fileName(from value: String) -> String? {
    guard let url = fileURL(from: value) else { return nil }
    let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    return name.clipboardTrimmed.isEmpty ? nil : name
  }

  func fileKindText(from value: String, fallback: String) -> String {
    let paths = FilePayload.paths(from: value)
    if paths.count > 1 { return "\(paths.count) files" }
    guard let fileExtension = fileURL(from: value)?.pathExtension.clipboardTrimmed, !fileExtension.isEmpty else { return fallback }
    return fileExtension.uppercased()
  }

  func accentColor(for kind: ClipKind) -> NSColor { kind.presentation.accentColor }
  func headerBadgeSymbol(for kind: ClipKind) -> String { kind.presentation.symbol }

  func firstUsefulLine(_ value: String) -> String {
    for line in value.components(separatedBy: .newlines) {
      let text = normalized(line)
      if !text.isEmpty { return text }
    }
    return ""
  }

  func normalized(_ value: String) -> String { value.split { $0.isWhitespace }.joined(separator: " ") }

  func looksInternal(_ value: String) -> Bool {
    let lower = value.lowercased()
    let stem = (value as NSString).lastPathComponent.components(separatedBy: ".").first ?? value
    return lower.hasPrefix("clipbored-flow-test-") || lower.hasPrefix("internal copy ") || isManagedStoragePath(value)
      || UUID(uuidString: stem) != nil
  }

  private func isManagedStoragePath(_ value: String) -> Bool {
    let normalized = value.replacingOccurrences(of: "%20", with: " ").lowercased()
    return normalized.contains("/application support/clipbored/") || normalized.contains("/application support/goldfish/")
  }

  func looksGenericLink(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower == "link" || lower == "url"
  }

  func looksGenericFileTitle(_ value: String) -> Bool {
    let lower = value.lowercased()
    return ["file", "pdf", "pdf document", "image", "audio", "video"].contains(lower)
      || lower.range(of: #"^(pdf|file|audio|video|image)( clip)?\s*\([^)]*\)$"#, options: .regularExpression) != nil
  }

  func looksLikeWebAddress(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.contains("://") || lower.hasPrefix("www.")
  }

  func accessibilityTitle(for item: Clip) -> String {
    let summary = titleText(for: item)
    return "\(kindLabel(for: item.presentationKind)): \(summary)"
  }

  func accessibilityHelpText() -> String {
    "Press Return to paste, or copy when automatic paste is unavailable. Space opens Quick Look. Command-R renames; Command-E edits text. Delete removes selected clips; Command-Z restores them."
  }

  func kindLabel(for kind: ClipKind) -> String { kind.presentation.label }

  func relativeDateText(for date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "Just now" }
    let units: [(limit: Int, divisor: Int, name: String)] = [
      (3600, 60, "minute"), (86400, 3600, "hour"), (604800, 86400, "day"), (Int.max, 604800, "week"),
    ]
    let unit = units.first { seconds < $0.limit } ?? units[3]
    let count = seconds / unit.divisor
    return "\(count) \(unit.name)\(count == 1 ? "" : "s") ago"
  }
}
