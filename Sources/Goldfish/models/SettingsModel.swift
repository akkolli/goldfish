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

enum ShelfSide: Int, CaseIterable {
  case left = 0
  case right = 1

  var title: String {
    switch self {
    case .left: return "Left"
    case .right: return "Right"
    }
  }
}

enum ShelfWidth: Int, CaseIterable {
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

enum ShelfLayout: Int, CaseIterable {
  case cards = 0
  case sidebar = 1
  static let allCases: [ShelfLayout] = [.sidebar, .cards]
  var title: String { self == .cards ? "Horizontal shelf" : "Vertical shelf" }
}

final class SettingsModel {
  enum Change: Equatable {
    case maxHistoryItems, historyRetention, defaultSortMode, imageCacheMaxBytes
    case includeImageTextInSearch, pruneDuplicates, keepFirstImage, excludeSensitive, ignoredApps, ignoredItemKinds, pollProfile
    case openShortcut, settingsShortcut, launchAtLogin, showMenuBarIcon, goldMenuBarIcon, soundEffects, showDockIcon, panelSide
    case cloudSync, pauseCapture, hideFromScreenCapture, clearHistoryOnQuit
    case captureStatus, collections, status, other
  }

  // These raw values are persisted identities, independent of UI labels.
  enum Keys: String {
    case maxHistoryItems, defaultSortMode, imageCacheMaxBytes, includeImageTextInSearch, pruneDuplicates, keepFirstImage
    case launchAtLogin, showMenuBarIcon, goldMenuBarIcon, showDockIcon, copySoundEnabled, pasteSoundEnabled, soundVolume
    case panelSide, shelfWidth, shelfLayout, largerShelfText, sortByUsage, iCloudSyncEnabled, openShortcut, settingsShortcut
    case ignoredApps, ignoredItemKinds, pollProfile, excludeSensitive, pauseCapture, pauseCaptureUntil, hideFromScreenCapture
    case clearHistoryOnQuit, onboardingCompleted, accessibilityNoticeShown, customCollectionNames, collectionColorHexes, collectionIcons
    case historyRetention = "historyRetentionDays"
  }

  @Preference(
    .maxHistoryItems, AppConfig.defaultHistoryLength, key: .maxHistoryItems, read: { ($0 as? Int).flatMap { $0 > 0 ? $0 : nil } },
    normalize: SettingsModel.clampedMaxHistoryItems) var maxHistoryItems: Int
  @Preference(.historyRetention, raw: .oneMonth, key: .historyRetention) var historyRetention: HistoryRetention
  @Preference(.defaultSortMode, raw: .mostRecent, key: .defaultSortMode) var defaultSortMode: ShelfFilter
  @Preference(
    .imageCacheMaxBytes, AppConfig.defaultCacheMaxBytes, key: .imageCacheMaxBytes, read: { ($0 as? Int64).flatMap { $0 > 0 ? $0 : nil } },
    normalize: SettingsModel.clampedImageCacheMaxBytes) var imageCacheMaxBytes: Int64
  @Preference(.includeImageTextInSearch, false, key: .includeImageTextInSearch) var includeImageTextInSearch: Bool
  @Preference(.pruneDuplicates, true, key: .pruneDuplicates) var pruneDuplicates: Bool
  @Preference(.launchAtLogin, false, key: .launchAtLogin) var launchAtLogin: Bool
  @Preference(.showMenuBarIcon, true, key: .showMenuBarIcon) var showMenuBarIcon: Bool
  @Preference(.goldMenuBarIcon, false, key: .goldMenuBarIcon) var goldMenuBarIcon: Bool
  @Preference(.soundEffects, false, key: .copySoundEnabled) var copySoundEnabled: Bool
  @Preference(.soundEffects, false, key: .pasteSoundEnabled) var pasteSoundEnabled: Bool
  @Preference(.soundEffects, 0.30, key: .soundVolume, normalize: SettingsModel.clampedSoundVolume) var soundVolume: Double
  @Preference(.showDockIcon, false, key: .showDockIcon) var showDockIcon: Bool
  @Preference(.panelSide, raw: .right, key: .panelSide) var panelSide: ShelfSide
  @Preference(.other, raw: .standard, key: .shelfWidth) var shelfWidth: ShelfWidth
  @Preference(.other, raw: .sidebar, key: .shelfLayout) var shelfLayout: ShelfLayout
  @Preference(.other, false, key: .largerShelfText) var largerShelfText: Bool
  @Preference(.other, false, key: .sortByUsage) var sortByUsage: Bool
  @Preference(.cloudSync, false, key: .iCloudSyncEnabled) var iCloudSyncEnabled: Bool
  @Preference(.openShortcut, shortcut: AppConfig.defaultOpenShortcut, key: .openShortcut) var openShortcut: ShortcutBinding
  @Preference(.settingsShortcut, shortcut: AppConfig.defaultSettingsShortcut, key: .settingsShortcut) var settingsShortcut: ShortcutBinding
  @Preference(.ignoredApps, AppConfig.defaultIgnoredApps, key: .ignoredApps) var ignoredApps: [String]
  @Preference(.ignoredItemKinds, [], key: .ignoredItemKinds, normalize: SettingsModel.normalizedIgnoredItemKinds) var ignoredItemKindsRaw:
    [Int]
  @Preference(.pollProfile, raw: AppConfig.defaultPollProfile, key: .pollProfile) var pollProfileRaw: AppConfig.PollProfile
  @Preference(.keepFirstImage, true, key: .keepFirstImage) var keepFirstImage: Bool
  @Preference(.excludeSensitive, true, key: .excludeSensitive) var excludeSensitive: Bool
  @Preference(.pauseCapture, false, key: .pauseCapture) var pauseCapture: Bool
  @Preference(
    .pauseCapture, nil, key: .pauseCaptureUntil, read: { ($0 as? TimeInterval).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } },
    encode: { $0?.timeIntervalSince1970 }) var pauseCaptureUntil: Date?
  @Preference(.hideFromScreenCapture, false, key: .hideFromScreenCapture) var hideFromScreenCapture: Bool
  @Preference(.clearHistoryOnQuit, false, key: .clearHistoryOnQuit) var clearHistoryOnQuit: Bool

  static func clampedSoundVolume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.30 }
  private(set) var customCollectionNames: [String]
  private(set) var collectionColorHexes: [String: String]
  private(set) var collectionIcons: [String: String]
  private var feedback: [Feedback: String] = [:]
  private(set) var onboardingCompleted: Bool
  private(set) var accessibilityNoticeShown: Bool

  private let defaults: UserDefaults
  private var observers: [(Change) -> Void] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let existingProfile = [Keys.maxHistoryItems.rawValue, Keys.historyRetention.rawValue, Keys.openShortcut.rawValue].contains {
      defaults.object(forKey: $0) != nil
    }
    let savedUsageSort = defaults.object(forKey: Keys.sortByUsage.rawValue) as? Bool
    customCollectionNames = Self.normalizedCollectionNames(defaults.stringArray(forKey: Keys.customCollectionNames.rawValue) ?? [])
    collectionColorHexes = Self.normalizedMetadata(
      defaults.dictionary(forKey: Keys.collectionColorHexes.rawValue), normalize: Self.normalizedHexColor)
    collectionIcons = Self.normalizedMetadata(
      defaults.dictionary(forKey: Keys.collectionIcons.rawValue), normalize: PinboardIcon.normalized)
    onboardingCompleted = defaults.object(forKey: Keys.onboardingCompleted.rawValue) as? Bool ?? existingProfile
    accessibilityNoticeShown = defaults.object(forKey: Keys.accessibilityNoticeShown.rawValue) as? Bool ?? false
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
        if change == .cloudSync { self?.feedback[.backup] = "" }
        self?.notify(change)
      }
    }
    sortByUsage = savedUsageSort ?? (defaultSortMode == .mostUsed)
    store()
  }

  private func store() {
    defaults.set(customCollectionNames, forKey: Keys.customCollectionNames.rawValue)
    defaults.set(collectionColorHexes, forKey: Keys.collectionColorHexes.rawValue)
    defaults.set(collectionIcons, forKey: Keys.collectionIcons.rawValue)
    defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted.rawValue)
  }

  func observe(_ observer: @escaping (Change) -> Void) { observers.append(observer) }

  private func storeAndNotify(_ change: Change) {
    store()
    notify(change)
  }

  private func notify(_ change: Change) { for observer in observers { observer(change) } }

  func status(_ source: Feedback) -> String { feedback[source] ?? "" }

  func setStatus(_ source: Feedback, _ message: String) {
    guard status(source) != message else { return }
    feedback[source] = message
    notify(source == .capture ? .captureStatus : .status)
  }

  func markAccessibilityNoticeShown() {
    guard !accessibilityNoticeShown else { return }
    accessibilityNoticeShown = true
    defaults.set(true, forKey: Keys.accessibilityNoticeShown.rawValue)
  }

  func markOnboardingCompleted() {
    guard !onboardingCompleted else { return }
    onboardingCompleted = true
    defaults.set(true, forKey: Keys.onboardingCompleted.rawValue)
    notify(.other)
  }

  @discardableResult func ensureCollection(named name: String, colorHex: String? = nil, icon: String? = nil) -> String? {
    guard let normalizedName = PinboardNames.normalizedName(name) else { return nil }
    let existingName = customCollectionNames.first { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }
    let canonicalName = existingName ?? normalizedName
    var changed = false

    if existingName == nil {
      customCollectionNames.append(normalizedName)
      changed = true
    }

    changed = writeMetadata(\.collectionColorHexes, name: canonicalName, value: Self.normalizedHexColor(colorHex)) || changed
    changed = writeMetadata(\.collectionIcons, name: canonicalName, value: PinboardIcon.normalized(icon)) || changed

    if changed { storeAndNotify(.collections) }
    return normalizedName
  }

  func collectionColorHex(forCollectionNamed name: String) -> String? { metadata(\.collectionColorHexes, name: name) }
  func collectionIcon(forCollectionNamed name: String) -> String? { metadata(\.collectionIcons, name: name) }

  private typealias MetadataKey = ReferenceWritableKeyPath<SettingsModel, [String: String]>
  private func metadata(_ field: MetadataKey, name: String) -> String? {
    guard let name = PinboardNames.normalizedName(name) else { return nil }
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
    guard let normalizedCurrentName = PinboardNames.normalizedName(currentName),
      let normalizedNewName = PinboardNames.normalizedName(newName)
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
      moveMetadata(\.collectionIcons, from: oldCanonicalName, to: targetCanonicalName, value: PinboardIcon.normalized(icon)) || changed

    if changed { storeAndNotify(.collections) }
    return targetCanonicalName
  }

  @discardableResult func deleteCollection(named name: String) -> String? {
    guard let normalizedName = PinboardNames.normalizedName(name) else { return nil }
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

  var pollProfile: AppConfig.PollProfile {
    get { pollProfileRaw }
    set { pollProfileRaw = newValue }
  }

  func sanitizeLimits() {
    maxHistoryItems = Self.clampedMaxHistoryItems(maxHistoryItems)
    imageCacheMaxBytes = Self.clampedImageCacheMaxBytes(imageCacheMaxBytes)
  }

  private static func clampedMaxHistoryItems(_ count: Int) -> Int {
    max(AppConfig.minHistoryLength, min(AppConfig.maxHistoryLength, count))
  }

  private static func clampedImageCacheMaxBytes(_ bytes: Int64) -> Int64 {
    max(AppConfig.minCacheMaxBytes, min(AppConfig.maxCacheMaxBytes, bytes))
  }

  private static func normalizedCollectionNames(_ names: [String]) -> [String] {
    names.compactMap(PinboardNames.normalizedName).reduce(into: []) { result, name in
      if !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { result.append(name) }
    }
  }

  private static let userVisibleItemKindRawValues: Set<Int> = [
    ClipKind.text.rawValue, ClipKind.code.rawValue, ClipKind.url.rawValue, ClipKind.image.rawValue, ClipKind.color.rawValue,
    ClipKind.audio.rawValue, ClipKind.video.rawValue, ClipKind.richText.rawValue, ClipKind.pdf.rawValue, ClipKind.file.rawValue,
  ]

  private static func normalizedIgnoredItemKinds(_ values: [Int]) -> [Int] {
    let ignoredVisibleKinds = Set(values).intersection(userVisibleItemKindRawValues)
    guard userVisibleItemKindRawValues.isSubset(of: ignoredVisibleKinds) else { return values }
    return values.filter { $0 != ClipKind.text.rawValue }
  }

  private static func normalizedMetadata(_ raw: [String: Any]?, normalize: (String?) -> String?) -> [String: String] {
    var values: [String: String] = [:]
    for (name, value) in raw ?? [:] {
      guard let name = PinboardNames.normalizedName(name), let value = normalize(value as? String) else { continue }
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
    _ change: SettingsModel.Change, _ initial: Value, key: SettingsModel.Keys, read: @escaping (Any?) -> Value? = { $0 as? Value },
    encode: @escaping (Value) -> Any? = { $0 }, normalize: @escaping (Value) -> Value = { $0 }
  ) {
    value = initial
    self.change = change
    self.key = key.rawValue
    self.read = read
    self.encode = encode
    self.normalize = normalize
  }

  convenience init(_ change: SettingsModel.Change, raw initial: Value, key: SettingsModel.Keys)
  where Value: RawRepresentable, Value.RawValue == Int {
    self.init(change, initial, key: key, read: { ($0 as? Int).flatMap(Value.init(rawValue:)) }, encode: { $0.rawValue })
  }

  convenience init(_ change: SettingsModel.Change, shortcut initial: Value, key: SettingsModel.Keys) where Value == ShortcutBinding {
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
