import AppKit
import CryptoKit
import Darwin
import Foundation
import SQLite3

struct ClipboardStoreRemoval {
  let item: ClipboardItem
  let index: Int
}

enum ClipboardStoreArchiveError: LocalizedError {
  case persistenceFailed
  case unreadableHistory
  case encryptionUnavailable

  var errorDescription: String? {
    switch self {
    case .persistenceFailed: return "Goldfish could not save the imported archive."
    case .unreadableHistory:
      return
        "Import paused to protect unreadable saved history. Restore Keychain access and relaunch before importing. Existing clips have not been replaced."
    case .encryptionUnavailable:
      return "Saving is paused because the history encryption key is unavailable. Unlock the login Keychain and try again."
    }
  }
}

final class ClipboardStore {
  private(set) var loadWarningMessage: String?
  private(set) var persistenceWarningMessage: String?
  var canPersistHistory: Bool { db != nil && loadWarningMessage == nil && encryptionService.canPersist }
  var savingUnavailableMessage: String {
    loadWarningMessage ?? persistenceWarningMessage ?? "Saving paused; history encryption key is unavailable."
  }
  private(set) var items: [ClipboardItem] = [] { didSet { notifyItemsChanged() } }

  private let settings: SettingsModel
  private let cacheService: ClipboardCacheService
  private let encryptionService: ClipboardEncryptionService
  private let dataQueue = DispatchQueue(label: "clipboard.store.persistence", qos: .utility)
  private let dataQueueKey = DispatchSpecificKey<Void>()
  private let baseURL: URL
  private let historyURL: URL
  private let dbURL: URL
  private var db: OpaquePointer?
  private var itemObservers: [([ClipboardItem]) -> Void] = []

  init(
    settings: SettingsModel, cacheService: ClipboardCacheService, baseURL: URL? = nil,
    encryptionService: ClipboardEncryptionService = ClipboardEncryptionService()
  ) {
    self.settings = settings
    self.cacheService = cacheService
    self.encryptionService = encryptionService
    self.baseURL = baseURL ?? ClipboardStore.storageDirectory()
    dbURL = self.baseURL.appendingPathComponent("history.sqlite")
    historyURL = self.baseURL.appendingPathComponent("history.json")
    settings.sanitizeLimits()
    dataQueue.setSpecific(key: dataQueueKey, value: ())
    performOnDataQueueAndWait {
      self.hardenStoragePermissions()
      self.openDatabase()
      self.configureDatabase()
      self.createSchema()
      self.hardenStoragePermissions()
      self.migrateLegacyJSONIfNeeded()
      self.load()
    }
  }

  deinit {
    let closeDatabase = {
      if let db = self.db {
        sqlite3_close(db)
        self.db = nil
      }
    }
    if DispatchQueue.getSpecific(key: dataQueueKey) != nil { closeDatabase() } else { dataQueue.sync(execute: closeDatabase) }
  }

  static func storageDirectory() -> URL {
    if let pointer = getenv(AppConfiguration.storageDirectoryOverrideEnvironmentKey), pointer.pointee != 0 {
      let base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true).standardizedFileURL
      try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
      return base
    }

    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let base = appSupport.appendingPathComponent(AppConfiguration.storageDirectoryName, isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    return base
  }

  // Mutations are proposed on the main thread, committed on the storage queue,
  // and published once. Failed transactions leave both memory and files intact.
  @discardableResult func upsert(_ incoming: ClipboardItem) -> ClipboardItem? {
    var proposed = items
    var saved = incoming
    if settings.pruneDuplicates, let index = proposed.firstIndex(where: { $0.payloadHash == incoming.payloadHash }) {
      let previous = proposed.remove(at: index)
      saved.id = previous.id
      saved.createdAt = Date()
      saved.lastUsedAt = Date()
      saved.useCount = min(Int(Int32.max), previous.useCount + 1)
      saved.isPinned = previous.isPinned
      saved.collectionName = incoming.collectionName ?? previous.collectionName
      saved.customTitle = incoming.customTitle ?? previous.customTitle
      if settings.keepFirstImage, incoming.kind == .image {
        saved.payload = previous.payload
        saved.imagePath = previous.imagePath
        saved.thumbnailPath = previous.thumbnailPath
        saved.ocrText = previous.ocrText
      }
    }
    proposed.insert(saved, at: 0)
    guard commitItems(proposed) else {
      cacheService.removeCachedReferences(incoming, preserving: Set(items.flatMap { cacheService.managedPaths(for: $0) }))
      return nil
    }
    let paths = Set(items.flatMap { cacheService.managedPaths(for: $0) })
    cacheService.removeCachedReferences(incoming, preserving: paths)
    return items.first { $0.id == saved.id }
  }

  func markUsed(_ id: UUID) { markUsed([id]) }

  @discardableResult func markUsed(_ ids: [UUID]) -> Bool {
    let idSet = Set(ids)
    var proposed = items
    var used: [ClipboardItem] = []
    proposed.removeAll { item in
      guard idSet.contains(item.id) else { return false }
      var updated = item
      updated.lastUsedAt = Date()
      updated.useCount = min(Int(Int32.max), updated.useCount + 1)
      used.insert(updated, at: 0)
      return true
    }
    return commitItems(used + proposed)
  }

  @discardableResult func togglePin(_ id: UUID) -> Bool { updateItem(id) { $0.isPinned.toggle() } }

  @discardableResult func setCollection(_ id: UUID, name: String?) -> Bool { setCollection([id], name: name) }

  @discardableResult func setCollection(_ ids: [UUID], name: String?) -> Bool {
    let idSet = Set(ids)
    let normalizedName = ClipboardCollectionDefaults.normalizedName(name)
    return commitItems(
      items.map { item in
        var updated = item
        if idSet.contains(item.id) { updated.collectionName = normalizedName }
        return updated
      })
  }

  @discardableResult func setCustomTitle(_ id: UUID, title: String?) -> Bool {
    updateItem(id) { $0.customTitle = ClipboardItem.normalizedCustomTitle(title) }
  }

  @discardableResult func updateText(_ id: UUID, text: String) -> Bool {
    guard !text.isEmpty, let item = items.first(where: { $0.id == id }), [.text, .code].contains(item.kind) else { return false }
    return updateItem(id) {
      $0.displayText = text
      $0.payload = text
      $0.payloadHash = hashString(text)
      $0.ocrText = nil
    }
  }

  @discardableResult func updateImage(_ id: UUID, imagePath: String, thumbnailPath: String, payloadHash: String) -> Bool {
    guard items.contains(where: { $0.id == id && $0.kind == .image }), cacheService.isManagedSidecar(path: imagePath),
      cacheService.isManagedSidecar(path: thumbnailPath), !payloadHash.isEmpty
    else { return false }
    return updateItem(id) {
      $0.payload = imagePath
      $0.imagePath = imagePath
      $0.thumbnailPath = thumbnailPath
      $0.payloadHash = payloadHash
    }
  }

  @discardableResult func updateImageText(_ id: UUID, ocrText: String) -> Bool {
    guard let text = ImageTextExtractor.normalizedRecognizedText(ocrText), items.contains(where: { $0.id == id && $0.kind == .image })
    else { return false }
    return updateItem(id) { $0.ocrText = text }
  }

  private func updateItem(_ id: UUID, _ update: (inout ClipboardItem) -> Void) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
    var proposed = items
    update(&proposed[index])
    return commitItems(proposed)
  }

  @discardableResult func remove(_ id: UUID, purgeManagedCache: Bool = true) -> ClipboardStoreRemoval? {
    remove([id], purgeManagedCache: purgeManagedCache)?.first
  }

  @discardableResult func remove(_ ids: [UUID], purgeManagedCache: Bool = true) -> [ClipboardStoreRemoval]? {
    let ids = Set(ids)
    let removals = items.enumerated().compactMap {
      ids.contains($0.element.id) ? ClipboardStoreRemoval(item: $0.element, index: $0.offset) : nil
    }
    guard !removals.isEmpty else { return nil }
    return commitItems(items.filter { !ids.contains($0.id) }, purgeRemoved: purgeManagedCache) ? removals : nil
  }

  @discardableResult func restore(_ removals: [ClipboardStoreRemoval]) -> Bool {
    var proposed = items
    for removal in removals.sorted(by: { $0.index < $1.index }) where !proposed.contains(where: { $0.id == removal.item.id }) {
      proposed.insert(removal.item, at: max(0, min(removal.index, proposed.count)))
    }
    return commitItems(proposed)
  }

  func purgeManagedCacheReferences(for removals: [ClipboardStoreRemoval]) {
    let paths = Set(items.flatMap { cacheService.managedPaths(for: $0) })
    for removal in removals { cacheService.removeCachedReferences(removal.item, preserving: paths) }
  }

  @discardableResult func removeAll() -> Bool { commitItems([], clearAll: true) }

  func updateHistoryLimit(_ newLimit: Int) {
    if settings.maxHistoryItems != newLimit { settings.maxHistoryItems = newLimit }
    normalizeHistoryLength()
  }

  func observeItems(_ observer: @escaping ([ClipboardItem]) -> Void) {
    performOnMainAndWait {
      self.itemObservers.append(observer)
      observer(self.items)
    }
  }

  @discardableResult func normalizeHistoryLength() -> Bool { commitItems(items) }

  private func commitItems(_ proposed: [ClipboardItem], purgeRemoved: Bool = true, clearAll: Bool = false) -> Bool {
    guard canPersistHistory else { return reportPersistenceFailure(savingUnavailableMessage) }
    let kept = retainedItems(from: proposed)
    let oldByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let keptIDs = Set(kept.map(\.id))
    let changed = kept.filter { oldByID[$0.id] != $0 }
    let removed = items.filter { !keptIDs.contains($0.id) }
    let saved = performOnDataQueueAndWait {
      self.transaction {
        if clearAll { return self.execute("DELETE FROM clipboard_items;") }
        return self.insert(changed) && (removed.isEmpty || self.delete(removed.map(\.id)))
      }
    }
    guard saved else {
      return reportPersistenceFailure(
        "Goldfish could not save history. Existing clips are unchanged; check disk space and storage access, then retry.")
    }
    persistenceWarningMessage = nil
    let oldItems = items
    if kept != items { items = kept }
    if purgeRemoved {
      let paths = Set(kept.flatMap { cacheService.managedPaths(for: $0) })
      let keptByID = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
      for item in oldItems where keptByID[item.id] != item { cacheService.removeCachedReferences(item, preserving: paths) }
      for item in proposed where !keptIDs.contains(item.id) { cacheService.removeCachedReferences(item, preserving: paths) }
    }
    if clearAll {
      performOnDataQueueAndWait {
        self.vacuumDatabase()
        self.encryptionService.resetStoredKey()
      }
    }
    hardenStoragePermissions()
    cacheService.purgeIfNeeded(maxBytes: settings.imageCacheMaxBytes)
    return true
  }

  private func reportPersistenceFailure(_ message: String) -> Bool {
    persistenceWarningMessage = message
    settings.setCaptureStatus(message: "Error: " + message)
    return false
  }

  func flushPersistence() { performOnDataQueueAndWait {} }

  func flushPersistenceForTesting() { flushPersistence() }

  @discardableResult func exportArchive(to url: URL, write: ArchiveWrite = { try $0() }) throws -> ClipboardArchiveSummary {
    guard loadWarningMessage == nil else { throw ClipboardStoreArchiveError.unreadableHistory }
    let snapshot = performOnMainAndWait {
      let collections = self.settings.customCollectionNames.map { name in
        ClipboardArchiveCollection(
          name: name, colorHex: self.settings.collectionColorHex(forCollectionNamed: name),
          icon: self.settings.collectionIcon(forCollectionNamed: name))
      }
      return (items: self.items, collections: collections)
    }
    performOnDataQueueAndWait {}
    return try ClipboardArchiveService().exportArchive(
      items: snapshot.items, to: url, cacheService: cacheService, collections: snapshot.collections, write: write)
  }

  @discardableResult func exportCollection(named name: String, to url: URL) throws -> ClipboardArchiveSummary {
    guard loadWarningMessage == nil else { throw ClipboardStoreArchiveError.unreadableHistory }
    guard let normalizedName = ClipboardCollectionDefaults.normalizedName(name) else {
      return try ClipboardArchiveService().exportArchive(items: [], to: url, cacheService: cacheService)
    }
    let snapshot = performOnMainAndWait {
      let collectionItems = self.items.filter { $0.collectionName?.caseInsensitiveCompare(normalizedName) == .orderedSame }
      let collection = ClipboardArchiveCollection(
        name: normalizedName, colorHex: self.settings.collectionColorHex(forCollectionNamed: normalizedName),
        icon: self.settings.collectionIcon(forCollectionNamed: normalizedName))
      return (items: collectionItems, collection: collection)
    }
    performOnDataQueueAndWait {}
    return try ClipboardArchiveService().exportArchive(
      items: snapshot.items, to: url, cacheService: cacheService, collections: [snapshot.collection])
  }

  @discardableResult func importArchive(from url: URL) throws -> ClipboardArchiveSummary {
    performOnDataQueueAndWait {}
    guard loadWarningMessage == nil else { throw ClipboardStoreArchiveError.unreadableHistory }
    guard canPersistHistory else { throw ClipboardStoreArchiveError.encryptionUnavailable }
    let archiveImport = try ClipboardArchiveService().importArchive(from: url, cacheService: cacheService)
    var didSave = false
    defer { if !didSave { cacheService.removeManagedFiles(archiveImport.createdPaths) } }
    didSave = performOnMainAndWait {
      var merged = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
      for item in archiveImport.items { merged[item.id] = item }
      guard self.commitItems(merged.values.sorted(by: self.historySort)) else { return false }
      for collection in archiveImport.collections {
        self.settings.ensureCollection(named: collection.name, colorHex: collection.colorHex, icon: collection.icon)
      }
      for item in archiveImport.items { if let name = item.collectionName { self.settings.ensureCollection(named: name) } }
      return true
    }
    guard didSave else { throw ClipboardStoreArchiveError.persistenceFailed }
    return archiveImport.summary
  }

  private func retainedItems(from sourceItems: [ClipboardItem]) -> [ClipboardItem] {
    var pinnedCount = 0
    var unpinnedCount = 0
    let retentionCutoff = settings.historyRetention.cutoffDate()
    return sourceItems.filter { item in
      if item.isPinned {
        if pinnedCount < AppConfiguration.maxPinnedItems {
          pinnedCount += 1
          return true
        }
        return isCollectionRetained(item)
      }
      if isCollectionRetained(item) { return true }
      if isExpiredByRetention(item, cutoff: retentionCutoff) { return false }
      guard unpinnedCount < settings.maxHistoryItems else { return false }
      unpinnedCount += 1
      return true
    }
  }

  private func historySort(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
    if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func isCollectionRetained(_ item: ClipboardItem) -> Bool {
    ClipboardCollectionDefaults.normalizedName(item.collectionName) != nil
  }

  private func isExpiredByRetention(_ item: ClipboardItem, cutoff: Date?) -> Bool {
    guard let cutoff else { return false }
    return item.createdAt < cutoff
  }

  private func performOnDataQueueAndWait<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: dataQueueKey) != nil { return work() }
    return dataQueue.sync(execute: work)
  }

  private func performOnMainAndWait<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync(execute: work)
  }

  private func load() { loadFromDatabase() }

  private func notifyItemsChanged() { for observer in itemObservers { observer(items) } }

  func hashString(_ value: String) -> String { hashData(Data(value.utf8)) }

  func hashData(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  private func openDatabase() {
    if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
      if let db { sqlite3_close(db) }
      db = nil
      loadWarningMessage = "Goldfish could not open saved history. Check storage access and relaunch; existing files are untouched."
    }
  }

  private func configureDatabase() {
    _ = execute("PRAGMA secure_delete = ON;")
    _ = execute("PRAGMA journal_mode = DELETE;")
  }

  private func hardenStoragePermissions() {
    try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseURL.path)
    if FileManager.default.fileExists(atPath: dbURL.path) {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
    }
    if FileManager.default.fileExists(atPath: historyURL.path) {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
  }

  private func createSchema() {
    if db == nil { return }
    let createTable = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
          id TEXT PRIMARY KEY NOT NULL,
          kind INTEGER NOT NULL,
          display_text TEXT NOT NULL,
          payload TEXT NOT NULL,
          payload_hash TEXT NOT NULL,
          created_at REAL NOT NULL,
          last_used_at REAL NOT NULL,
          use_count INTEGER NOT NULL DEFAULT 0,
          source_app TEXT,
          source_app_bundle_id TEXT,
          image_path TEXT,
          thumbnail_path TEXT,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          ocr_text TEXT,
          collection_name TEXT,
          custom_title TEXT,
          source_device_name TEXT
        );
      """

    let createIndexes = """
        CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_items (created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_last_used_at ON clipboard_items (last_used_at DESC);
        CREATE INDEX IF NOT EXISTS idx_use_count ON clipboard_items (use_count DESC);
        CREATE INDEX IF NOT EXISTS idx_kind ON clipboard_items (kind);
        CREATE INDEX IF NOT EXISTS idx_hash ON clipboard_items (payload_hash);
        CREATE INDEX IF NOT EXISTS idx_collection_name ON clipboard_items (collection_name);
      """

    guard execute(createTable) else {
      loadWarningMessage = "Goldfish could not initialize saved history. Existing files are untouched."
      return
    }
    _ = execute("ALTER TABLE clipboard_items ADD COLUMN collection_name TEXT;")
    _ = execute("ALTER TABLE clipboard_items ADD COLUMN custom_title TEXT;")
    _ = execute("ALTER TABLE clipboard_items ADD COLUMN source_device_name TEXT;")
    if !execute(createIndexes) { loadWarningMessage = "Goldfish could not initialize history indexes. Existing files are untouched." }
  }

  private func migrateLegacyJSONIfNeeded() {
    guard isDatabaseEmpty(), let data = try? Data(contentsOf: historyURL), !data.isEmpty else { return }

    if let decoded = decodeLegacyJSONItems(from: data) {
      items = decoded
      items = retainedItems(from: decoded)
      if saveAll(items) {
        try? FileManager.default.removeItem(at: historyURL)
        hardenStoragePermissions()
      }
    }
  }

  private func decodeLegacyJSONItems(from data: Data) -> [ClipboardItem]? {
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

    var items: [ClipboardItem] = []
    items.reserveCapacity(rows.count)
    for row in rows { if let item = decodeLegacyJSONItem(row) { items.append(item) } }
    return items
  }

  private func decodeLegacyJSONItem(_ row: [String: Any]) -> ClipboardItem? {
    guard let kindValue = row["kind"] as? Int, let kind = ClipboardItemKind(rawValue: kindValue),
      let displayText = row["displayText"] as? String, let payload = row["payload"] as? String,
      let payloadHash = row["payloadHash"] as? String, let createdAt = legacyDate(row["createdAt"]),
      let lastUsedAt = legacyDate(row["lastUsedAt"])
    else { return nil }

    let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
    let useCount = row["useCount"] as? Int ?? 0

    return ClipboardItem(
      id: id, kind: kind, displayText: displayText, payload: payload, payloadHash: payloadHash, createdAt: createdAt,
      lastUsedAt: lastUsedAt, useCount: useCount, sourceApp: row["sourceApp"] as? String, imagePath: row["imagePath"] as? String,
      thumbnailPath: row["thumbnailPath"] as? String, isPinned: row["isPinned"] as? Bool ?? false,
      sourceAppBundleId: row["sourceAppBundleId"] as? String, ocrText: row["ocrText"] as? String,
      collectionName: row["collectionName"] as? String, customTitle: row["customTitle"] as? String,
      sourceDeviceName: row["sourceDeviceName"] as? String ?? ClipboardItem.localDeviceName)
  }

  private func legacyDate(_ value: Any?) -> Date? {
    if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
    if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
    guard let string = value as? String else { return nil }

    return legacyISO8601Date(string)
  }

  private func legacyISO8601Date(_ string: String) -> Date? {
    let value = string.replacingOccurrences(of: " ", with: "T")
    return Self.legacyDateFormatters.lazy.compactMap { $0.date(from: value) }.first
  }

  private static let legacyDateFormatters: [ISO8601DateFormatter] = {
    let formats: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
    return formats.map { options in
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      return formatter
    }
  }()

  private func isDatabaseEmpty() -> Bool {
    guard let db else { return true }
    let query = "SELECT COUNT(*) FROM clipboard_items;"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return true }
    guard sqlite3_step(statement) == SQLITE_ROW else { return true }
    let count = sqlite3_column_int64(statement, 0)
    return count == 0
  }

  private func loadFromDatabase() {
    guard let db else { return }
    let query = "SELECT \(Self.columns.joined(separator: ", ")) FROM clipboard_items ORDER BY created_at DESC, last_used_at DESC;"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
      loadWarningMessage = "Goldfish could not read saved history. Existing files are untouched."
      return
    }

    var canEncryptCache: Bool?
    func canEncryptForMigration() -> Bool {
      if let canEncryptCache { return canEncryptCache }
      let canEncrypt = encryptionService.isAvailable
      canEncryptCache = canEncrypt
      return canEncrypt
    }

    var loaded: [ClipboardItem] = []
    var needsEncryptionMigration = false
    var hadDecodeFailure = false
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      defer { result = sqlite3_step(statement) }
      guard let idText = sqlite3_column_text(statement, 0), let kindValue = Int(exactly: sqlite3_column_int(statement, 1)),
        let kind = ClipboardItemKind(rawValue: kindValue)
      else { continue }

      let id = UUID(uuidString: String(cString: idText)) ?? UUID()

      func stringValue(_ index: Int32) -> (value: String?, migrationNeeded: Bool, decodeFailed: Bool) {
        guard let raw = sqlite3_column_text(statement, index) else { return (nil, false, false) }
        let value = String(cString: raw)
        if ClipboardEncryptionService.isProtected(value) {
          guard let decoded = encryptionService.unprotect(value) else { return (nil, false, true) }
          return (decoded, decoded == value && canEncryptForMigration(), false)
        }
        return (value, canEncryptForMigration(), false)
      }

      let required = [2, 3, 4].map { stringValue(Int32($0)) }
      hadDecodeFailure = hadDecodeFailure || required.contains { $0.decodeFailed }
      guard let displayText = required[0].value, let payload = required[1].value, let hash = required[2].value else { continue }
      needsEncryptionMigration = needsEncryptionMigration || required.contains { $0.migrationNeeded }
      var item = ClipboardItem(
        id: id, kind: kind, displayText: displayText, payload: payload, payloadHash: hash,
        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
        lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), useCount: Int(sqlite3_column_int64(statement, 7)),
        isPinned: sqlite3_column_int(statement, 12) != 0)
      for (index, key) in Self.optionalTextColumns {
        let field = stringValue(index)
        item[keyPath: key] = field.value
        needsEncryptionMigration = needsEncryptionMigration || field.migrationNeeded
        hadDecodeFailure = hadDecodeFailure || field.decodeFailed
      }
      // The constructor normalizes these values; loading through key paths must
      // apply the same normalization after all fields have been decrypted.
      item.customTitle = ClipboardItem.normalizedCustomTitle(item.customTitle)
      item.sourceDeviceName = ClipboardItem.normalizedDeviceName(item.sourceDeviceName ?? ClipboardItem.localDeviceName)
      loaded.append(item)
    }

    if result != SQLITE_DONE { loadWarningMessage = "Goldfish could not finish reading history. Existing files are untouched." }
    sqlite3_finalize(statement)
    statement = nil

    items = loaded
    if hadDecodeFailure {
      loadWarningMessage =
        "Some saved history could not be decrypted. Goldfish left the database intact. Do not clear history; restore Keychain access and relaunch."
    }
    if loadWarningMessage == nil { normalizeHistoryLength() }
    cacheService.encryptCachedReferencesIfNeeded(for: items)
    if needsEncryptionMigration, !hadDecodeFailure, saveAll(items) {
      vacuumDatabase()
      hardenStoragePermissions()
    }
  }

  // Zero-based SELECT indexes; INSERT bindings use the same order plus one.
  private static let columns = [
    "id", "kind", "display_text", "payload", "payload_hash", "created_at", "last_used_at", "use_count", "source_app",
    "source_app_bundle_id", "image_path", "thumbnail_path", "is_pinned", "ocr_text", "collection_name", "custom_title",
    "source_device_name",
  ]
  private static let optionalTextColumns: [(Int32, WritableKeyPath<ClipboardItem, String?>)] = [
    (8, \.sourceApp), (9, \.sourceAppBundleId), (10, \.imagePath), (11, \.thumbnailPath), (13, \.ocrText), (14, \.collectionName),
    (15, \.customTitle), (16, \.sourceDeviceName),
  ]
  private static let insertSQL =
    "INSERT OR REPLACE INTO clipboard_items (\(columns.joined(separator: ", "))) VALUES ("
    + Array(repeating: "?", count: columns.count).joined(separator: ", ") + ");"

  @discardableResult private func saveAll(_ items: [ClipboardItem]) -> Bool {
    transaction { execute("DELETE FROM clipboard_items;") && insert(items) }
  }

  private func transaction(_ work: () -> Bool) -> Bool {
    guard let db, execute("BEGIN IMMEDIATE TRANSACTION;") else { return false }
    defer { if sqlite3_get_autocommit(db) == 0 { _ = execute("ROLLBACK;") } }
    return work() && execute("COMMIT;")
  }

  private func insert(_ items: [ClipboardItem]) -> Bool {
    guard !items.isEmpty else { return true }
    guard let db else { return false }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, Self.insertSQL, -1, &statement, nil) == SQLITE_OK else { return false }
    for item in items {
      bindItem(item, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { return false }
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
    }
    return true
  }

  private func delete(_ ids: [UUID]) -> Bool {
    guard let db, !ids.isEmpty else { return false }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
    let query = "DELETE FROM clipboard_items WHERE id IN (\(placeholders));"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return false }
    for (offset, id) in ids.enumerated() { bindText(statement, Int32(offset + 1), id.uuidString) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  @discardableResult private func execute(_ sql: String) -> Bool {
    guard let db else { return false }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
  }

  private func vacuumDatabase() { _ = execute("VACUUM;") }

  private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }

    let destructor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = unsafeBitCast(
      -1, to: Optional<@convention(c) (UnsafeMutableRawPointer?) -> Void>.self)
    _ = value.withCString { ptr in sqlite3_bind_text(statement, index, ptr, -1, destructor) }
  }

  private func bindItem(_ item: ClipboardItem, to statement: OpaquePointer?) {
    bindText(statement, 1, item.id.uuidString)
    sqlite3_bind_int(statement, 2, Int32(item.kind.rawValue))
    bindText(statement, 3, encryptionService.protect(item.displayText))
    bindText(statement, 4, encryptionService.protect(item.payload))
    bindText(statement, 5, encryptionService.protect(item.payloadHash))
    sqlite3_bind_double(statement, 6, item.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 7, item.lastUsedAt.timeIntervalSince1970)
    sqlite3_bind_int64(statement, 8, Int64(item.useCount))
    sqlite3_bind_int(statement, 13, item.isPinned ? 1 : 0)
    for (index, key) in Self.optionalTextColumns { bindText(statement, index + 1, encryptionService.protect(item[keyPath: key])) }
  }
}
