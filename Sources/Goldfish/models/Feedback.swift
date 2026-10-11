import AppKit

/// Transient feedback is separate from persisted preferences. Each source owns
/// its fallback and ordered display rules; a status message never changes data.
enum Feedback: CaseIterable {
  case launch, accessibility, capture, shortcut, paste, backup, data
  typealias Presentation = (message: String, textColor: NSColor)

  private struct Rule {
    let color: NSColor
    var prefixes: [String] = []
    var contains: [String] = []
    func matches(_ message: String) -> Bool { prefixes.contains(where: message.hasPrefix) || contains.contains(where: message.contains) }
  }

  func presentation(_ status: String, isTrusted: Bool = false, backupEnabled: Bool = false, cloudStatus: CloudBackupStatus? = nil)
    -> Presentation
  {
    let message = status.clipboardTrimmed
    if message.isEmpty {
      switch self {
      case .launch, .data: return ("", .secondaryLabelColor)
      case .shortcut: return ("Registered", .systemGreen)
      case .capture: return ("Capture status will appear after the app sees clipboard activity.", .secondaryLabelColor)
      case .paste: return ("No paste action yet.", .secondaryLabelColor)
      case .accessibility:
        return isTrusted
          ? ("Granted", .systemGreen) : ("Not granted (clipboard capture still works; paste falls back to copy)", .systemOrange)
      case .backup:
        guard backupEnabled else { return ("iCloud Backup is off.", .secondaryLabelColor) }
        return cloudStatus.map { ($0.message, $0.isAvailable ? .secondaryLabelColor : .systemOrange) } ?? (
          "iCloud Backup is unavailable.", .systemOrange
        )
      }
    }
    let folded = message.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    return (message, rules.first { $0.matches(folded) }?.color ?? .secondaryLabelColor)
  }

  private var rules: [Rule] {
    switch self {
    case .launch, .shortcut: return [Rule(color: .systemRed, prefixes: [""])]
    case .accessibility: return [Rule(color: .systemOrange, prefixes: [""])]
    case .capture:
      return [
        Rule(
          color: .systemGreen, prefixes: ["captured", "allowed content types updated"],
          contains: ["capture running", "capture is running", "capture resumed"]),
        Rule(color: .systemRed, prefixes: ["error"], contains: ["failed", "could not"]),
        Rule(color: .systemOrange, prefixes: ["skipped"], contains: ["ignored", "paused", "at least one"]),
      ]
    case .paste:
      return [
        Rule(color: .systemRed, contains: ["could not", "failed"]),
        Rule(color: .systemOrange, contains: ["grant accessibility", "not granted"]),
        Rule(color: .systemGreen, prefixes: ["pasted", "copied"]),
      ]
    case .data:
      return [
        Rule(
          color: .systemRed,
          contains: ["could not", "couldn", "denied", "error", "failed", "invalid", "missing", "not permitted", "unavailable"]),
        Rule(color: .systemOrange, contains: ["skipped"]), Rule(color: .systemGreen, prefixes: ["exported", "imported", "cleared"]),
      ]
    case .backup:
      return [
        Rule(color: .systemRed, contains: ["failed"]), Rule(color: .systemOrange, contains: ["unavailable", "turn on", "skipped"]),
        Rule(color: .systemGreen, prefixes: ["backed up", "restored", "opened"]),
      ]
    }
  }
}
