import XCTest

@testable import Goldfish

final class SettingsModelTests: IsolatedTestCase {
  func testNewAndLegacyProfilesKeepTheVerticalShelf() {
    let defaults = makeTestDefaults()
    XCTAssertEqual(SettingsModel(defaults: defaults).shelfLayout, .sidebar)
    defaults.removeObject(forKey: SettingsModel.Keys.shelfLayout)
    XCTAssertEqual(SettingsModel(defaults: defaults).shelfLayout, .sidebar)
    defaults.set(999, forKey: SettingsModel.Keys.shelfLayout)
    XCTAssertEqual(SettingsModel(defaults: defaults).shelfLayout, .sidebar)
    // An explicit layout choice still persists across launches.
    let settings = SettingsModel(defaults: defaults)
    settings.shelfLayout = .cards
    XCTAssertEqual(SettingsModel(defaults: defaults).shelfLayout, .cards)
  }

  func testFreshProfileRequiresOnboardingUntilCompleted() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    XCTAssertFalse(settings.onboardingCompleted)
    XCTAssertFalse(defaults.bool(forKey: SettingsModel.Keys.onboardingCompleted))
    XCTAssertTrue(settings.excludeSensitive)

    settings.markOnboardingCompleted()

    XCTAssertTrue(settings.onboardingCompleted)
    XCTAssertTrue(defaults.bool(forKey: SettingsModel.Keys.onboardingCompleted))
    XCTAssertEqual(changes, [.other])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertTrue(restored.onboardingCompleted)
  }

  func testLegacyProfileDoesNotShowOnboardingAfterUpgrade() {
    let defaults = makeTestDefaults()
    defaults.set(AppConfiguration.defaultHistoryLength, forKey: SettingsModel.Keys.maxHistoryItems)

    let settings = SettingsModel(defaults: defaults)

    XCTAssertTrue(settings.onboardingCompleted)
    XCTAssertTrue(defaults.bool(forKey: SettingsModel.Keys.onboardingCompleted))
  }

  func testAppearancePreferencesPersistAndNotify() {
    let cases: [(ReferenceWritableKeyPath<SettingsModel, Bool>, String, SettingsModel.Change)] = [
      (\.showDockIcon, SettingsModel.Keys.showDockIcon, .showDockIcon),
      (\.goldMenuBarIcon, SettingsModel.Keys.goldMenuBarIcon, .goldMenuBarIcon),
      (\.hideFromScreenCapture, SettingsModel.Keys.hideFromScreenCapture, .hideFromScreenCapture),
    ]
    for (property, storageKey, change) in cases {
      let defaults = makeTestDefaults()
      let settings = SettingsModel(defaults: defaults)
      var changes: [SettingsModel.Change] = []
      settings.observe { changes.append($0) }
      XCTAssertFalse(settings[keyPath: property], storageKey)
      settings[keyPath: property] = true
      XCTAssertTrue(defaults.bool(forKey: storageKey), storageKey)
      XCTAssertEqual(changes.count, 1, storageKey)
      XCTAssertEqual(changes, [change], storageKey)
      XCTAssertTrue(SettingsModel(defaults: defaults)[keyPath: property], storageKey)
    }
  }

  func testPanelSidePersistsAndNotifies() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    XCTAssertEqual(settings.panelSide, .right)

    settings.panelSide = .left

    XCTAssertEqual(defaults.integer(forKey: SettingsModel.Keys.panelSide), ClipboardPanelSide.left.rawValue)
    XCTAssertEqual(changes, [.panelSide])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.panelSide, .left)
  }

  func testImageCacheMinimumAllowsTwoMegabytes() {
    let defaults = makeTestDefaults()
    let twoMegabytes = Int64(2 * 1024 * 1024)
    defaults.set(twoMegabytes, forKey: SettingsModel.Keys.imageCacheMaxBytes)

    let settings = SettingsModel(defaults: defaults)

    XCTAssertEqual(AppConfiguration.minCacheMaxBytes, twoMegabytes)
    XCTAssertEqual(settings.imageCacheMaxBytes, twoMegabytes)
  }

  func testICloudSyncPersistsAndNotifies() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    XCTAssertFalse(settings.iCloudSyncEnabled)

    settings.setCloudSyncStatus(message: "Backed up 3 clips to iCloud.")
    XCTAssertEqual(settings.cloudSyncStatusMessage, "Backed up 3 clips to iCloud.")
    changes.removeAll()

    settings.iCloudSyncEnabled = true

    XCTAssertTrue(defaults.bool(forKey: SettingsModel.Keys.iCloudSyncEnabled))
    XCTAssertEqual(settings.cloudSyncStatusMessage, "")
    XCTAssertEqual(changes, [.cloudSync])

    settings.setCloudSyncStatus(message: "Backed up 3 clips to iCloud.")
    changes.removeAll()
    settings.iCloudSyncEnabled = false

    XCTAssertFalse(defaults.bool(forKey: SettingsModel.Keys.iCloudSyncEnabled))
    XCTAssertEqual(settings.cloudSyncStatusMessage, "")
    XCTAssertEqual(changes, [.cloudSync])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertFalse(restored.iCloudSyncEnabled)
  }

  func testPauseCaptureUntilPersistsAndCanBeCleared() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    let pauseUntil = Date(timeIntervalSince1970: 1_234_567)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.pauseCapture = true
    settings.pauseCaptureUntil = pauseUntil

    XCTAssertTrue(defaults.bool(forKey: SettingsModel.Keys.pauseCapture))
    XCTAssertEqual(defaults.double(forKey: SettingsModel.Keys.pauseCaptureUntil), pauseUntil.timeIntervalSince1970)
    XCTAssertEqual(changes, [.pauseCapture, .pauseCapture])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertTrue(restored.pauseCapture)
    XCTAssertEqual(restored.pauseCaptureUntil, pauseUntil)

    restored.pauseCaptureUntil = nil

    XCTAssertNil(defaults.object(forKey: SettingsModel.Keys.pauseCaptureUntil))
  }

  func testIgnoredAppsPersistsAndNotifiesNarrowChange() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.ignoredApps = ["Safari", "Xcode"]

    XCTAssertEqual(defaults.stringArray(forKey: SettingsModel.Keys.ignoredApps), ["Safari", "Xcode"])
    XCTAssertEqual(changes, [.ignoredApps])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.ignoredApps, ["Safari", "Xcode"])
  }

  func testCommonControlSettingsNotifyNarrowChanges() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    settings.excludeSensitive = false
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.defaultSortMode = .links
    settings.includeImageTextInSearch = true
    settings.pruneDuplicates = false
    settings.ignoredItemKindsRaw = [ClipboardItemKind.image.rawValue]
    settings.keepFirstImage = false
    settings.excludeSensitive = true
    settings.clearHistoryOnQuit = true

    XCTAssertEqual(
      changes,
      [
        .defaultSortMode, .includeImageTextInSearch, .pruneDuplicates, .ignoredItemKinds, .keepFirstImage, .excludeSensitive,
        .clearHistoryOnQuit,
      ])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.defaultSortMode, .links)
    XCTAssertTrue(restored.includeImageTextInSearch)
    XCTAssertFalse(restored.pruneDuplicates)
    XCTAssertEqual(restored.ignoredItemKindsRaw, [ClipboardItemKind.image.rawValue])
    XCTAssertFalse(restored.keepFirstImage)
    XCTAssertTrue(restored.excludeSensitive)
    XCTAssertTrue(restored.clearHistoryOnQuit)
  }

  func testIgnoredItemKindsCannotDisableEveryVisibleKind() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    let allVisibleKindRawValues = Self.visibleItemKinds.map(\.rawValue)
    let expectedIgnoredKindRawValues = allVisibleKindRawValues.filter { $0 != ClipboardItemKind.text.rawValue }
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.ignoredItemKindsRaw = allVisibleKindRawValues

    XCTAssertEqual(settings.ignoredItemKindsRaw, expectedIgnoredKindRawValues)
    XCTAssertEqual(defaults.object(forKey: SettingsModel.Keys.ignoredItemKinds) as? [Int], expectedIgnoredKindRawValues)
    XCTAssertEqual(changes, [.ignoredItemKinds])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.ignoredItemKindsRaw, expectedIgnoredKindRawValues)
  }

  func testStoredIgnoredItemKindsCannotDisableEveryVisibleKind() {
    let defaults = makeTestDefaults()
    let allVisibleKindRawValues = Self.visibleItemKinds.map(\.rawValue)
    let expectedIgnoredKindRawValues = allVisibleKindRawValues.filter { $0 != ClipboardItemKind.text.rawValue }
    defaults.set(allVisibleKindRawValues, forKey: SettingsModel.Keys.ignoredItemKinds)

    let settings = SettingsModel(defaults: defaults)

    XCTAssertEqual(settings.ignoredItemKindsRaw, expectedIgnoredKindRawValues)
    XCTAssertEqual(defaults.object(forKey: SettingsModel.Keys.ignoredItemKinds) as? [Int], expectedIgnoredKindRawValues)
  }

  func testStoredLimitsAreClampedAndPersisted() {
    let cacheCases: [(Int64, Int64)] = [
      (0, AppConfiguration.defaultCacheMaxBytes), (1 * 1024 * 1024, AppConfiguration.minCacheMaxBytes),
      (2048 * 1024 * 1024, AppConfiguration.maxCacheMaxBytes),
    ]
    assertStoredLimits(\.imageCacheMaxBytes, key: SettingsModel.Keys.imageCacheMaxBytes, cases: cacheCases)
    assertStoredLimits(
      \.maxHistoryItems, key: SettingsModel.Keys.maxHistoryItems,
      cases: [
        (0, AppConfiguration.defaultHistoryLength), (1, AppConfiguration.minHistoryLength), (100_000, AppConfiguration.maxHistoryLength),
      ])
  }

  private func assertStoredLimits<Value: BinaryInteger>(
    _ property: KeyPath<SettingsModel, Value>, key: String, cases: [(Value, Value)], file: StaticString = #filePath, line: UInt = #line
  ) {
    for (input, expected) in cases {
      let defaults = makeTestDefaults()
      defaults.set(input, forKey: key)
      XCTAssertEqual(SettingsModel(defaults: defaults)[keyPath: property], expected, "\(key): \(input)", file: file, line: line)
      XCTAssertEqual(Value(defaults.integer(forKey: key)), expected, "\(key): \(input)", file: file, line: line)
    }
  }

  func testLimitAssignmentsAreClampedAndPersisted() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.maxHistoryItems = 1
    settings.maxHistoryItems = 100_000
    settings.imageCacheMaxBytes = 1
    settings.imageCacheMaxBytes = 2048 * 1024 * 1024

    XCTAssertEqual(settings.maxHistoryItems, AppConfiguration.maxHistoryLength)
    XCTAssertEqual(defaults.integer(forKey: SettingsModel.Keys.maxHistoryItems), AppConfiguration.maxHistoryLength)
    XCTAssertEqual(settings.imageCacheMaxBytes, AppConfiguration.maxCacheMaxBytes)
    XCTAssertEqual(Int64(defaults.integer(forKey: SettingsModel.Keys.imageCacheMaxBytes)), AppConfiguration.maxCacheMaxBytes)
    XCTAssertEqual(changes, [.maxHistoryItems, .maxHistoryItems, .imageCacheMaxBytes, .imageCacheMaxBytes])
  }

  func testHistoryRetentionDefaultsToOneMonthAndPersists() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    XCTAssertEqual(settings.historyRetention, .oneMonth)
    XCTAssertEqual(defaults.integer(forKey: SettingsModel.Keys.historyRetention), HistoryRetention.oneMonth.rawValue)

    settings.historyRetention = .oneWeek

    XCTAssertEqual(defaults.integer(forKey: SettingsModel.Keys.historyRetention), HistoryRetention.oneWeek.rawValue)
    XCTAssertEqual(changes, [.historyRetention])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.historyRetention, .oneWeek)
  }

  func testCustomCollectionsPersistWithNormalizedColors() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }

    settings.ensureCollection(named: "  Research   Stack  ", colorHex: "0a9eb8")
    settings.ensureCollection(named: "research stack", colorHex: "#FF3355")
    settings.ensureCollection(named: "Client Work", colorHex: "not-a-color")

    XCTAssertEqual(settings.customCollectionNames, ["Research Stack", "Client Work"])
    XCTAssertEqual(settings.collectionColorHex(forCollectionNamed: "research stack"), "#FF3355")
    XCTAssertNil(settings.collectionColorHex(forCollectionNamed: "Client Work"))
    XCTAssertEqual(changes, [.collections, .collections, .collections])

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.customCollectionNames, ["Research Stack", "Client Work"])
    XCTAssertEqual(restored.collectionColorHex(forCollectionNamed: "Research Stack"), "#FF3355")
  }

  func testCustomCollectionsCanBeUpdatedAndDeleted() {
    let defaults = makeTestDefaults()
    let settings = SettingsModel(defaults: defaults)

    settings.ensureCollection(named: "Research Stack", colorHex: "#0A9EB8", icon: "book.closed.fill")
    settings.ensureCollection(named: "Client Work", colorHex: "#FF3355")

    let updatedName = settings.updateCollection(named: "research stack", to: "Product Research", colorHex: "#3366FF", icon: "star.fill")

    XCTAssertEqual(updatedName, "Product Research")
    XCTAssertEqual(settings.customCollectionNames, ["Product Research", "Client Work"])
    XCTAssertNil(settings.collectionColorHex(forCollectionNamed: "Research Stack"))
    XCTAssertEqual(settings.collectionColorHex(forCollectionNamed: "Product Research"), "#3366FF")
    XCTAssertNil(settings.collectionIcon(forCollectionNamed: "Research Stack"))
    XCTAssertEqual(settings.collectionIcon(forCollectionNamed: "Product Research"), "star.fill")

    settings.deleteCollection(named: "client work")

    XCTAssertEqual(settings.customCollectionNames, ["Product Research"])
    XCTAssertNil(settings.collectionColorHex(forCollectionNamed: "Client Work"))

    let restored = SettingsModel(defaults: defaults)
    XCTAssertEqual(restored.customCollectionNames, ["Product Research"])
    XCTAssertEqual(restored.collectionColorHex(forCollectionNamed: "Product Research"), "#3366FF")
    XCTAssertEqual(restored.collectionIcon(forCollectionNamed: "Product Research"), "star.fill")
  }

  func testCollectionRenameAndMergePreserveMetadataAndCanonicalKeys() {
    for (newName, expectedNames) in [("research", ["research", "Client"]), ("CLIENT", ["Client"]), ("Fresh", ["Fresh", "Client"])] {
      let defaults = makeTestDefaults()
      let settings = SettingsModel(defaults: defaults)
      settings.ensureCollection(named: "Research", colorHex: "#3366FF", icon: "star.fill")
      settings.ensureCollection(named: "Client", colorHex: "#FF3355", icon: "book.closed.fill")
      var changes: [SettingsModel.Change] = []
      settings.observe { changes.append($0) }
      let canonical = expectedNames[0]
      XCTAssertEqual(settings.updateCollection(named: "RESEARCH", to: newName, colorHex: "invalid", icon: "invalid"), canonical)
      XCTAssertEqual(settings.customCollectionNames, expectedNames)
      XCTAssertEqual(settings.collectionColorHexes[canonical], "#3366FF")
      XCTAssertEqual(settings.collectionIcons[canonical], "star.fill")
      XCTAssertNil(settings.collectionColorHexes["Research"])
      XCTAssertNil(settings.collectionIcons["Research"])
      XCTAssertEqual(changes, [.collections])
      let restored = SettingsModel(defaults: defaults)
      XCTAssertEqual(restored.customCollectionNames, expectedNames)
      XCTAssertEqual(restored.collectionColorHexes, settings.collectionColorHexes)
      XCTAssertEqual(restored.collectionIcons, settings.collectionIcons)
      restored.deleteCollection(named: canonical.uppercased())
      XCTAssertNil(restored.collectionColorHex(forCollectionNamed: canonical))
      XCTAssertNil(restored.collectionIcon(forCollectionNamed: canonical))
    }
  }

  private static let visibleItemKinds: [ClipboardItemKind] = [.text, .code, .url, .image, .color, .audio, .video, .richText, .pdf, .file]
}
