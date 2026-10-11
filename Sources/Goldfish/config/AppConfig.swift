import AppKit
import Foundation

enum AppConfig {
  static let appName = "Goldfish"
  static var buildDescription: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"), let data = try? Data(contentsOf: url),
      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let revision = info["revision"] as? String
    else { return version }
    return "\(version) · \(revision.prefix(8))" + (info["dirty"] as? Bool == true ? " · preview" : "")
  }
  // Stable on-disk identity preserves history and backups across the rename.
  static let storageDirectoryName = "ClipBored"
  static let storageDirectoryOverrideEnvironmentKey = "CLIPBORED_STORAGE_DIR"
  static let defaultHistoryLength = 300
  static let minHistoryLength = 50
  static let maxHistoryLength = 2000
  static let minCacheMaxBytes: Int64 = 2 * 1024 * 1024
  static let defaultCacheMaxBytes: Int64 = 120 * 1024 * 1024
  static let maxCacheMaxBytes: Int64 = 512 * 1024 * 1024
  static let maxPinnedItems = 250
  static let maxFullImagePixelSize: CGFloat = 1600
  static let maxManagedPayloadBytes = 64 * 1024 * 1024
  static let maxPortableArchiveSidecarBytes = 96 * 1024 * 1024
  static let maxPortableArchiveBytes = 128 * 1024 * 1024
  static let maxRecognizedImageTextLength = 4096
  static let maxImageCacheFiles = 1000
  static let defaultOpenShortcut = ShortcutBinding(
    key: "v", modifierFlags: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue)
  static let defaultSettingsShortcut = ShortcutBinding(key: ",", modifierFlags: NSEvent.ModifierFlags.command.rawValue)
  static let defaultIgnoredApps: [String] = ["1password", "bitwarden", "lastpass", "dashlane", "keeper", "keepass", "authy"]
  static let defaultPollProfile: PollProfile = .balanced
  static let minResponsiveActiveInterval: TimeInterval = 0.075

  enum PollProfile: Int {
    case battery = 0
    case balanced = 1
    case responsive = 2

    static let allCases: [PollProfile] = [.battery, .balanced, .responsive]

    private var policy: (title: String, idle: TimeInterval, active: TimeInterval, recovery: TimeInterval) {
      switch self {
      case .battery: return ("Battery Saver", 0.50, 0.12, 3.5)
      case .balanced: return ("Balanced", 0.25, 0.075, 2.0)
      case .responsive: return ("Responsive", 0.12, 0.075, 1.2)
      }
    }
    var title: String { policy.title }
    var idleInterval: TimeInterval { policy.idle }
    var activeInterval: TimeInterval { policy.active }
    var idleRecoveryWindow: TimeInterval { policy.recovery }

  }
}

struct ShortcutBinding: Equatable {
  let key: String
  let modifierFlags: UInt

  init(key: String, modifierFlags: UInt) {
    self.key = key.lowercased()
    self.modifierFlags = modifierFlags
  }

  var displayText: String {
    var text = ""
    if modifierFlags & NSEvent.ModifierFlags.command.rawValue != 0 { text += "⌘" }
    if modifierFlags & NSEvent.ModifierFlags.option.rawValue != 0 { text += "⌥" }
    if modifierFlags & NSEvent.ModifierFlags.control.rawValue != 0 { text += "⌃" }
    if modifierFlags & NSEvent.ModifierFlags.shift.rawValue != 0 { text += "⇧" }
    return text + key.uppercased()
  }

  func matches(_ event: NSEvent) -> Bool {
    guard let eventChar = event.charactersIgnoringModifiers?.lowercased(), eventChar.count == 1 else { return false }
    let mask =
      event.modifierFlags.rawValue
      & (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.shift.rawValue)
    return eventChar == key && mask == modifierFlags
  }

  func encoded() -> String { "\(modifierFlags)|\(key)" }

  func has(_ flag: NSEvent.ModifierFlags) -> Bool { modifierFlags & flag.rawValue != 0 }

  init?(encoded value: String) {
    let parts = value.split(separator: "|")
    guard parts.count == 2, let flags = UInt(parts[0]), let key = parts.last else { return nil }
    self.key = String(key).lowercased()
    self.modifierFlags = flags
  }
}
