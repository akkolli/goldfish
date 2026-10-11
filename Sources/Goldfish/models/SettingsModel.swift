import Foundation

enum HistoryRetention: Int {
  case forever = 0
  case oneDay = 1
  case oneWeek = 7
  case oneMonth = 30
  case oneYear = 365

  static let allCases: [HistoryRetention] = [.oneDay, .oneWeek, .oneMonth, .oneYear, .forever]

  var title: String {
    switch self {
    case .oneDay: return "1 Day"
    case .oneWeek: return "1 Week"
    case .oneMonth: return "1 Month"
    case .oneYear: return "1 Year"
    case .forever: return "Forever"
    }
  }

  func cutoffDate(relativeTo now: Date = Date()) -> Date? {
    guard self != .forever else { return nil }
    return now.addingTimeInterval(-Double(rawValue) * 24 * 60 * 60)
  }
}

enum ClipboardPanelSide: Int, CaseIterable {
  case left = 0
  case right = 1

  var title: String {
    switch self {
    case .left: return "Left"
    case .right: return "Right"
    }
  }
}

enum ClipboardShelfWidth: Int, CaseIterable {
  case compact = 336
  case standard = 420
  case wide = 540
  var title: String {
    switch self {
    case .compact: return "Compact"
    case .standard: return "Standard"
    case .wide: return "Wide"
    }
  }
}

enum ClipboardShelfLayout: Int, CaseIterable {
  case cards = 0
  case sidebar = 1
  static let allCases: [ClipboardShelfLayout] = [.sidebar, .cards]
  var title: String { self == .cards ? "Horizontal shelf" : "Vertical shelf" }
}

final class SettingsModel {
  enum Change: Equatable {
    case maxHistoryItems
    case historyRetention
    case defaultSortMode
    case imageCacheMaxBytes
    case includeImageTextInSearch
    case pruneDuplicates
    case openShortcut
    case settingsShortcut
    case launchAtLogin
    case showMenuBarIcon
    case goldMenuBarIcon
    case soundEffects
    case showDockIcon
    case panelSide
    case cloudSync
    case pauseCapture
    case ignoredApps
    case ignoredItemKinds
    case keepFirstImage
    case excludeSensitive
    case hideFromScreenCapture
    case clearHistoryOnQuit
    case pollProfile
    case captureStatus
    case collections
    case status
    case other
  }

  enum Keys {
    static let maxHistoryItems = "maxHistoryItems"
    static let historyRetention = "historyRetentionDays"
    static let defaultSortMode = "defaultSortMode"
    static let imageCacheMaxBytes = "imageCacheMaxBytes"
    static let includeImageTextInSearch = "includeImageTextInSearch"
    static let pruneDuplicates = "pruneDuplicates"
    static let launchAtLogin = "launchAtLogin"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let goldMenuBarIcon = "goldMenuBarIcon"
    static let copySoundEnabled = "copySoundEnabled"
    static let pasteSoundEnabled = "pasteSoundEnabled"
    static let soundVolume = "soundVolume"
    static let showDockIcon = "showDockIcon"
    static let panelSide = "panelSide"
    static let shelfWidth = "shelfWidth"
    static let shelfLayout = "shelfLayout"
    static let largerShelfText = "largerShelfText"
    static let sortByUsage = "sortByUsage"
    static let iCloudSyncEnabled = "iCloudSyncEnabled"
    static let openShortcut = "openShortcut"
    static let settingsShortcut = "settingsShortcut"
    static let ignoredApps = "ignoredApps"
    static let ignoredItemKinds = "ignoredItemKinds"
    static let pollProfile = "pollProfile"
    static let keepFirstImage = "keepFirstImage"
    static let excludeSensitive = "excludeSensitive"
    static let pauseCapture = "pauseCapture"
    static let pauseCaptureUntil = "pauseCaptureUntil"
    static let hideFromScreenCapture = "hideFromScreenCapture"
    static let clearHistoryOnQuit = "clearHistoryOnQuit"
    static let onboardingCompleted = "onboardingCompleted"
    static let accessibilityNoticeShown = "accessibilityNoticeShown"
    static let customCollectionNames = "customCollectionNames"
    static let collectionColorHexes = "collectionColorHexes"
    static let collectionIcons = "collectionIcons"
  }

  @Preference(
    .maxHistoryItems, AppConfiguration.defaultHistoryLength, key: Keys.maxHistoryItems,
    read: { ($0 as? Int).flatMap { $0 > 0 ? $0 : nil } }, normalize: SettingsModel.clampedMaxHistoryItems) var maxHistoryItems: Int
  @Preference(.historyRetention, raw: .oneMonth, key: Keys.historyRetention) var historyRetention: HistoryRetention
  @Preference(.defaultSortMode, raw: .mostRecent, key: Keys.defaultSortMode) var defaultSortMode: ClipboardSortMode
  @Preference(
    .imageCacheMaxBytes, AppConfiguration.defaultCacheMaxBytes, key: Keys.imageCacheMaxBytes,
    read: { ($0 as? Int64).flatMap { $0 > 0 ? $0 : nil } }, normalize: SettingsModel.clampedImageCacheMaxBytes) var imageCacheMaxBytes:
    Int64
  @Preference(.includeImageTextInSearch, false, key: Keys.includeImageTextInSearch) var includeImageTextInSearch: Bool
  @Preference(.pruneDuplicates, true, key: Keys.pruneDuplicates) var pruneDuplicates: Bool
  @Preference(.launchAtLogin, false, key: Keys.launchAtLogin) var launchAtLogin: Bool
  @Preference(.showMenuBarIcon, true, key: Keys.showMenuBarIcon) var showMenuBarIcon: Bool
  @Preference(.goldMenuBarIcon, false, key: Keys.goldMenuBarIcon) var goldMenuBarIcon: Bool
  @Preference(.soundEffects, false, key: Keys.copySoundEnabled) var copySoundEnabled: Bool
  @Preference(.soundEffects, false, key: Keys.pasteSoundEnabled) var pasteSoundEnabled: Bool
  @Preference(.soundEffects, 0.30, key: Keys.soundVolume, normalize: SettingsModel.clampedSoundVolume) var soundVolume: Double
  @Preference(.showDockIcon, false, key: Keys.showDockIcon) var showDockIcon: Bool
  @Preference(.panelSide, raw: .right, key: Keys.panelSide) var panelSide: ClipboardPanelSide
  @Preference(.other, raw: .standard, key: Keys.shelfWidth) var shelfWidth: ClipboardShelfWidth
  @Preference(.other, raw: .sidebar, key: Keys.shelfLayout) var shelfLayout: ClipboardShelfLayout
  @Preference(.other, false, key: Keys.largerShelfText) var largerShelfText: Bool
  @Preference(.other, false, key: Keys.sortByUsage) var sortByUsage: Bool
  @Preference(.cloudSync, false, key: Keys.iCloudSyncEnabled) var iCloudSyncEnabled: Bool
  @Preference(.openShortcut, shortcut: AppConfiguration.defaultOpenShortcut, key: Keys.openShortcut) var openShortcut: ShortcutBinding
  @Preference(.settingsShortcut, shortcut: AppConfiguration.defaultSettingsShortcut, key: Keys.settingsShortcut) var settingsShortcut:
    ShortcutBinding
  @Preference(.ignoredApps, AppConfiguration.defaultIgnoredApps, key: Keys.ignoredApps) var ignoredApps: [String]
  @Preference(.ignoredItemKinds, [], key: Keys.ignoredItemKinds, normalize: SettingsModel.normalizedIgnoredItemKinds)
  var ignoredItemKindsRaw: [Int]
  @Preference(.pollProfile, raw: AppConfiguration.defaultPollProfile, key: Keys.pollProfile) var pollProfileRaw:
    AppConfiguration.PollProfile
  @Preference(.keepFirstImage, true, key: Keys.keepFirstImage) var keepFirstImage: Bool
  @Preference(.excludeSensitive, true, key: Keys.excludeSensitive) var excludeSensitive: Bool
  @Preference(.pauseCapture, false, key: Keys.pauseCapture) var pauseCapture: Bool
  @Preference(
    .pauseCapture, nil, key: Keys.pauseCaptureUntil,
    read: { ($0 as? TimeInterval).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }, encode: { $0?.timeIntervalSince1970 })
  var pauseCaptureUntil: Date?
  @Preference(.hideFromScreenCapture, false, key: Keys.hideFromScreenCapture) var hideFromScreenCapture: Bool
  @Preference(.clearHistoryOnQuit, false, key: Keys.clearHistoryOnQuit) var clearHistoryOnQuit: Bool

  static func clampedSoundVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.30 }
  private(set) var customCollectionNames: [String]
  private(set) var collectionColorHexes: [String: String]
  private(set) var collectionIcons: [String: String]
  private(set) var launchAtLoginErrorMessage: String = ""
  private(set) var accessibilityPermissionStatusMessage: String = ""
  private(set) var captureStatusMessage: String = ""
  private(set) var shortcutStatusMessage: String = ""
  private(set) var pasteStatusMessage: String = ""
  private(set) var cloudSyncStatusMessage: String = ""
  private(set) var onboardingCompleted: Bool
  private(set) var accessibilityNoticeShown: Bool

  private let defaults: UserDefaults
  private var observers: [(Change) -> Void] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let existingProfile = [Keys.maxHistoryItems, Keys.historyRetention, Keys.openShortcut].contains { defaults.object(forKey: $0) != nil }
    let savedUsageSort = defaults.object(forKey: Keys.sortByUsage) as? Bool
    customCollectionNames = Self.normalizedCollectionNames(defaults.stringArray(forKey: Keys.customCollectionNames) ?? [])
    collectionColorHexes = Self.normalizedMetadata(
      defaults.dictionary(forKey: Keys.collectionColorHexes), normalize: Self.normalizedHexColor)
    collectionIcons = Self.normalizedMetadata(
      defaults.dictionary(forKey: Keys.collectionIcons), normalize: ClipboardCollectionIcon.normalized)
    onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted) as? Bool ?? existingProfile
    accessibilityNoticeShown = defaults.object(forKey: Keys.accessibilityNoticeShown) as? Bool ?? false
    let preferences: [any PreferenceLoading] = [
      _maxHistoryItems, _historyRetention, _defaultSortMode, _imageCacheMaxBytes, _includeImageTextInSearch, _pruneDuplicates,
      _launchAtLogin, _showMenuBarIcon, _goldMenuBarIcon, _copySoundEnabled, _pasteSoundEnabled, _soundVolume, _showDockIcon, _panelSide,
      _shelfWidth, _shelfLayout, _largerShelfText, _sortByUsage, _iCloudSyncEnabled, _openShortcut, _settingsShortcut, _ignoredApps,
      _ignoredItemKindsRaw, _pollProfileRaw, _keepFirstImage, _excludeSensitive, _pauseCapture, _pauseCaptureUntil, _hideFromScreenCapture,
      _clearHistoryOnQuit,
    ]
    for preference in preferences {
      preference.load(defaults)
      preference.onChange = { [weak self] change in
        if change == .cloudSync { self?.cloudSyncStatusMessage = "" }
        self?.notify(change)
      }
    }
    sortByUsage = savedUsageSort ?? (defaultSortMode == .mostUsed)
    store()
  }

  private func store() {
    defaults.set(customCollectionNames, forKey: Keys.customCollectionNames)
    defaults.set(collectionColorHexes, forKey: Keys.collectionColorHexes)
    defaults.set(collectionIcons, forKey: Keys.collectionIcons)
    defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
  }

  func observe(_ observer: @escaping (Change) -> Void) { observers.append(observer) }

  private func storeAndNotify(_ change: Change) {
    store()
    notify(change)
  }

  private func notify(_ change: Change) { for observer in observers { observer(change) } }

  func setLaunchAtLoginStatus(message: String) { setStatus(\.launchAtLoginErrorMessage, message: message, change: .status) }

  func setAccessibilityPermissionStatus(message: String) {
    setStatus(\.accessibilityPermissionStatusMessage, message: message, change: .status)
  }

  func setCaptureStatus(message: String) { setStatus(\.captureStatusMessage, message: message, change: .captureStatus) }

  private func setStatus(_ key: ReferenceWritableKeyPath<SettingsModel, String>, message: String, change: Change) {
    guard self[keyPath: key] != message else { return }
    self[keyPath: key] = message
    notify(change)
  }

  func markAccessibilityNoticeShown() {
    guard !accessibilityNoticeShown else { return }
    accessibilityNoticeShown = true
    defaults.set(true, forKey: Keys.accessibilityNoticeShown)
  }

  func markOnboardingCompleted() {
    guard !onboardingCompleted else { return }
    onboardingCompleted = true
    defaults.set(true, forKey: Keys.onboardingCompleted)
    notify(.other)
  }

  func setShortcutStatus(message: String) { setStatus(\.shortcutStatusMessage, message: message, change: .status) }

  func setPasteStatus(message: String) { setStatus(\.pasteStatusMessage, message: message, change: .status) }

  func setCloudSyncStatus(message: String) { setStatus(\.cloudSyncStatusMessage, message: message, change: .status) }

  @discardableResult func ensureCollection(named name: String, colorHex: String? = nil, icon: String? = nil) -> String? {
    guard let normalizedName = ClipboardCollectionDefaults.normalizedName(name) else { return nil }
    let existingName = customCollectionNames.first { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }
    let canonicalName = existingName ?? normalizedName
    var changed = false

    if existingName == nil {
      customCollectionNames.append(normalizedName)
      changed = true
    }

    changed = writeMetadata(\.collectionColorHexes, name: canonicalName, value: Self.normalizedHexColor(colorHex)) || changed
    changed = writeMetadata(\.collectionIcons, name: canonicalName, value: ClipboardCollectionIcon.normalized(icon)) || changed

    if changed { storeAndNotify(.collections) }
    return normalizedName
  }

  func collectionColorHex(forCollectionNamed name: String) -> String? { metadata(\.collectionColorHexes, name: name) }
  func collectionIcon(forCollectionNamed name: String) -> String? { metadata(\.collectionIcons, name: name) }

  private typealias MetadataKey = ReferenceWritableKeyPath<SettingsModel, [String: String]>
  private func metadata(_ field: MetadataKey, name: String) -> String? {
    guard let name = ClipboardCollectionDefaults.normalizedName(name) else { return nil }
    return self[keyPath: field][name] ?? self[keyPath: field].first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private func removeMetadata(_ field: MetadataKey, name: String, keeping canonicalName: String? = nil) -> Bool {
    let keys = self[keyPath: field].keys.filter { $0.caseInsensitiveCompare(name) == .orderedSame && $0 != canonicalName }
    for key in keys { self[keyPath: field].removeValue(forKey: key) }
    return !keys.isEmpty
  }

  private func writeMetadata(_ field: MetadataKey, name: String, value: String?) -> Bool {
    guard let value, self[keyPath: field][name] != value else { return false }
    _ = removeMetadata(field, name: name, keeping: name)
    self[keyPath: field][name] = value
    return true
  }

  private func moveMetadata(_ field: MetadataKey, from oldName: String, to newName: String, value: String?) -> Bool {
    let resolved = value ?? metadata(field, name: oldName)
    let removed = removeMetadata(field, name: oldName)
    return writeMetadata(field, name: newName, value: resolved) || removed
  }

  @discardableResult func updateCollection(named currentName: String, to newName: String, colorHex: String? = nil, icon: String? = nil)
    -> String?
  {
    guard let normalizedCurrentName = ClipboardCollectionDefaults.normalizedName(currentName),
      let normalizedNewName = ClipboardCollectionDefaults.normalizedName(newName)
    else { return nil }

    let oldIndex = customCollectionNames.firstIndex { $0.caseInsensitiveCompare(normalizedCurrentName) == .orderedSame }
    let oldCanonicalName = oldIndex.map { customCollectionNames[$0] } ?? normalizedCurrentName
    let targetIndex = customCollectionNames.firstIndex { $0.caseInsensitiveCompare(normalizedNewName) == .orderedSame }
    let targetCanonicalName: String
    if let targetIndex, targetIndex != oldIndex {
      targetCanonicalName = customCollectionNames[targetIndex]
    } else {
      targetCanonicalName = normalizedNewName
    }
    var changed = false

    if let oldIndex {
      if let targetIndex, targetIndex != oldIndex {
        customCollectionNames.remove(at: oldIndex)
        changed = true
      } else if customCollectionNames[oldIndex] != normalizedNewName {
        customCollectionNames[oldIndex] = normalizedNewName
        changed = true
      }
    } else if targetIndex == nil {
      customCollectionNames.append(normalizedNewName)
      changed = true
    }

    changed =
      moveMetadata(\.collectionColorHexes, from: oldCanonicalName, to: targetCanonicalName, value: Self.normalizedHexColor(colorHex))
      || changed
    changed =
      moveMetadata(\.collectionIcons, from: oldCanonicalName, to: targetCanonicalName, value: ClipboardCollectionIcon.normalized(icon))
      || changed

    if changed { storeAndNotify(.collections) }
    return targetCanonicalName
  }

  @discardableResult func deleteCollection(named name: String) -> String? {
    guard let normalizedName = ClipboardCollectionDefaults.normalizedName(name) else { return nil }
    var changed = false
    if let index = customCollectionNames.firstIndex(where: { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
      customCollectionNames.remove(at: index)
      changed = true
    }
    changed = removeMetadata(\.collectionColorHexes, name: normalizedName) || changed
    changed = removeMetadata(\.collectionIcons, name: normalizedName) || changed

    if changed { storeAndNotify(.collections) }
    return normalizedName
  }

  var pollProfile: AppConfiguration.PollProfile {
    get { pollProfileRaw }
    set { pollProfileRaw = newValue }
  }

  func sanitizeLimits() {
    maxHistoryItems = Self.clampedMaxHistoryItems(maxHistoryItems)
    imageCacheMaxBytes = Self.clampedImageCacheMaxBytes(imageCacheMaxBytes)
  }

  private static func clampedMaxHistoryItems(_ count: Int) -> Int {
    max(AppConfiguration.minHistoryLength, min(AppConfiguration.maxHistoryLength, count))
  }

  private static func clampedImageCacheMaxBytes(_ bytes: Int64) -> Int64 {
    max(AppConfiguration.minCacheMaxBytes, min(AppConfiguration.maxCacheMaxBytes, bytes))
  }

  private static func normalizedCollectionNames(_ names: [String]) -> [String] {
    var normalized: [String] = []
    for name in names {
      guard let value = ClipboardCollectionDefaults.normalizedName(name) else { continue }
      guard !normalized.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
      normalized.append(value)
    }
    return normalized
  }

  private static let userVisibleItemKindRawValues: Set<Int> = [
    ClipboardItemKind.text.rawValue, ClipboardItemKind.code.rawValue, ClipboardItemKind.url.rawValue, ClipboardItemKind.image.rawValue,
    ClipboardItemKind.color.rawValue, ClipboardItemKind.audio.rawValue, ClipboardItemKind.video.rawValue,
    ClipboardItemKind.richText.rawValue, ClipboardItemKind.pdf.rawValue, ClipboardItemKind.file.rawValue,
  ]

  private static func normalizedIgnoredItemKinds(_ values: [Int]) -> [Int] {
    let ignoredVisibleKinds = Set(values).intersection(userVisibleItemKindRawValues)
    guard userVisibleItemKindRawValues.isSubset(of: ignoredVisibleKinds) else { return values }
    return values.filter { $0 != ClipboardItemKind.text.rawValue }
  }

  private static func normalizedMetadata(_ raw: [String: Any]?, normalize: (String?) -> String?) -> [String: String] {
    var values: [String: String] = [:]
    for (name, value) in raw ?? [:] {
      guard let name = ClipboardCollectionDefaults.normalizedName(name), let value = normalize(value as? String) else { continue }
      values[name] = value
    }
    return values
  }

  private static func normalizedHexColor(_ value: String?) -> String? {
    guard let value else { return nil }
    var hex = value.clipboardTrimmed.uppercased()
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return "#\(hex)"
  }
}

// Each preference owns its normalization and serialization. A mutation writes
// only that key and emits one narrow change after the stored value is updated.
protocol PreferenceLoading: AnyObject {
  var onChange: ((SettingsModel.Change) -> Void)? { get set }
  func load(_ defaults: UserDefaults)
}

@propertyWrapper final class Preference<Value: Equatable>: PreferenceLoading {
  private var value: Value
  private var defaults: UserDefaults?
  var onChange: ((SettingsModel.Change) -> Void)?
  let change: SettingsModel.Change
  let key: String
  let read: (Any?) -> Value?
  let encode: (Value) -> Any?
  let normalize: (Value) -> Value

  init(
    _ change: SettingsModel.Change, _ initial: Value, key: String, read: @escaping (Any?) -> Value? = { $0 as? Value },
    encode: @escaping (Value) -> Any? = { $0 }, normalize: @escaping (Value) -> Value = { $0 }
  ) {
    value = initial
    self.change = change
    self.key = key
    self.read = read
    self.encode = encode
    self.normalize = normalize
  }

  convenience init(_ change: SettingsModel.Change, raw initial: Value, key: String) where Value: RawRepresentable, Value.RawValue == Int {
    self.init(change, initial, key: key, read: { ($0 as? Int).flatMap(Value.init(rawValue:)) }, encode: { $0.rawValue })
  }

  convenience init(_ change: SettingsModel.Change, shortcut initial: Value, key: String) where Value == ShortcutBinding {
    self.init(change, initial, key: key, read: { ($0 as? String).flatMap(ShortcutBinding.init(encoded:)) }, encode: { $0.encoded() })
  }

  func load(_ defaults: UserDefaults) {
    self.defaults = defaults
    value = normalize(read(defaults.object(forKey: key)) ?? value)
    defaults.set(encode(value), forKey: key)
  }

  var wrappedValue: Value {
    get { value }
    set {
      let normalized = normalize(newValue)
      guard value != normalized else { return }
      value = normalized
      defaults?.set(encode(normalized), forKey: key)
      onChange?(change)
    }
  }
}
