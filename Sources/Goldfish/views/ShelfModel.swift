import AppKit
import Foundation

enum ClipSelection {
  case replace
  case toggle
  case range
  case hover
  case activate
}
struct ShelfCounts {
  fileprivate let sortModeCounts: [Int: Int]
  fileprivate let collectionCounts: [String: Int]

  func count(for sortMode: ShelfFilter) -> Int { sortModeCounts[sortMode.rawValue] ?? 0 }

  func count(named name: String) -> Int {
    guard let normalizedName = PinboardNames.normalizedName(name) else { return 0 }
    return collectionCounts[normalizedName.lowercased()] ?? 0
  }
}

final class ShelfModel {
  /// Consumers read the completed model state; events never carry stale snapshots.
  enum Change: Equatable { case items, search, selection, status, sort, collections, capture }
  var onChange: ((Change) -> Void)?

  private struct VisibleItemsCacheKey: Hashable {
    let query: String
    let sortMode: Int
    let collectionNameKey: String?
  }

  private struct IndexedClipboardItem {
    let offset: Int
    let item: Clip
  }

  private struct SearchMatchCacheEntry {
    let query: String
    let indexedItems: [IndexedClipboardItem]
  }

  private struct ThumbnailRequestKey: Hashable {
    let itemID: UUID
    let kindRawValue: Int
    let source: String?
  }

  private typealias TransferIntent = PasteActionService.Intent

  private enum TransferContext {
    case single
    case selected
  }

  private(set) var visibleItemsRevision: UInt = 0
  private(set) var visibleItems: [Clip] = [] {
    didSet {
      visibleItemsRevision &+= 1
      var nextIndexByID: [UUID: Int] = [:]
      nextIndexByID.reserveCapacity(visibleItems.count)
      for (index, item) in visibleItems.enumerated() { if nextIndexByID[item.id] == nil { nextIndexByID[item.id] = index } }
      visibleIndexByID = nextIndexByID
      guard !isRecomputingVisibleItems else { return }
      publish(.items)
    }
  }
  private var shelfState: ShelfState
  var searchText: String {
    get { shelfState.query }
    set { applyShelfAction(.search(newValue)) }
  }
  var sortMode: ShelfFilter {
    get { shelfState.sortMode }
    set { applyShelfAction(.sort(newValue)) }
  }
  var selectedCollectionName: String? { shelfState.collectionName }

  private func applyShelfAction(_ action: ShelfState.Action) {
    let previous = shelfState
    shelfState.apply(action)
    guard previous != shelfState else { return }
    let searchChanged = previous.query != searchText
    if searchChanged { selectedItemID = selectedItem?.id }
    let sortChanged = previous.sortMode != sortMode
    let collectionChanged = previous.collectionName != selectedCollectionName
    if sortChanged { settings.defaultSortMode = sortMode }
    if sortChanged || collectionChanged || previous.contentFilter != contentFilter
      || searchEngine.normalized(previous.query) != searchEngine.normalized(searchText)
    {
      recomputeVisibleItems()
    }
    if searchChanged { publish(.search) }
    if sortChanged { publish(.sort) }
    if collectionChanged { publish(.collections) }
  }
  var selectedIndex: Int = 0 {
    didSet {
      guard oldValue != selectedIndex else { return }
      publish(.selection)
    }
  }
  private(set) var selectedItemIDs: [UUID] = [] {
    didSet {
      guard oldValue != selectedItemIDs else { return }
      selectedItemIDSet = Set(selectedItemIDs)
      publish(.selection)
    }
  }
  private(set) var statusMessage: String = "" { didSet { publish(.status) } }
  var contentFilter: ShelfFilter? {
    get { shelfState.contentFilter }
    set { applyShelfAction(.content(newValue)) }
  }
  var sortByUsage: Bool {
    get { settings.sortByUsage }
    set { settings.sortByUsage = newValue }
  }
  var largerShelfText: Bool { settings.largerShelfText }
  var shelfLayout: ShelfLayout { settings.shelfLayout }
  var shelfWidth: ShelfWidth { settings.shelfWidth }
  var usesCardShelf: Bool { shelfLayout == .cards }
  var isCapturePaused: Bool { settings.pauseCapture }
  var sourceAppNames: [String] { Array(Set(items.compactMap(\.sourceApp))).sorted() }
  private var hiddenCaptureIDs: [UUID] = []
  var hiddenCaptureCount: Int { hiddenCaptureIDs.count }
  var hasActiveFilters: Bool {
    !searchText.clipboardTrimmed.isEmpty || contentFilter != nil || (sortMode != .mostRecent && sortMode != .mostUsed)
      || selectedCollectionName != nil
  }

  /// Called after a clipboard capture has reached the store, independently of
  /// action feedback so background copies cannot replace Undo or paste results.
  func didCaptureItem(_ item: Clip) {
    guard itemByID[item.id] != nil else { return }
    guard visibleIndexByID[item.id] == nil else { return }
    hiddenCaptureIDs.removeAll { $0 == item.id }
    hiddenCaptureIDs.append(item.id)
    publish(.capture)
  }

  func showLatestHiddenCapture() {
    guard let id = hiddenCaptureIDs.last else { return }
    searchText = ""
    resetFilters()
    sortByUsage = false
    if let index = visibleIndexByID[id] { selectItem(at: index) }
    statusMessage = "Showing latest copy"
  }

  func toggleCapturePause() {
    settings.pauseCaptureUntil = nil
    settings.pauseCapture.toggle()
    statusMessage = settings.pauseCapture ? "Capture paused. New copies will not be saved." : "Capture resumed."
  }

  func clearActionStatus() { statusMessage = "" }

  func resetFilters() {
    applyShelfAction(.reset)
    recomputeVisibleItems()
  }

  private var items: [Clip] = [] {
    didSet {
      rebuildItemIndexes()
      collectionNamesCache = nil
      visibleItemsCache.removeAll(keepingCapacity: true)
      collectionCountCache = nil
      searchMatchCache = nil
      searchEngine.pruneDocuments { itemByID[$0] != nil }
    }
  }
  private let store: HistoryStore
  private let settings: SettingsModel
  private let cacheService: MediaCache
  private let dataCoordinator: DataCoordinator
  private let pasteService: PasteActionService
  private let imageTextExtractor: (NSImage) -> String?
  private let thumbnailLoader: (Clip) -> NSImage?
  private let thumbnailLoadQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "clipboard.panel.thumbnail-loader"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  private let mediaActionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "clipboard.panel.media-actions"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private let thumbnailRequestLock = NSLock()
  private var thumbnailCompletionsByRequest: [ThumbnailRequestKey: [(NSImage?) -> Void]] = [:]
  private var selectedItemID: UUID?
  private var selectionAnchorItemID: UUID?
  private var isRecomputingVisibleItems = false
  private var isApplyingLocalCollectionMutation = false
  private var isDeferringLocalStoreRecompute = false
  private var pendingDeletionUndo: [HistoryRemoval] = []
  private var contentTypeCountCache: (revision: UInt, counts: [ShelfFilter: Int])?
  private var collectionCountCache: (query: String, summary: ShelfCounts)?
  private var collectionNamesCache: [String]?
  private var visibleItemsCache: [VisibleItemsCacheKey: [Clip]] = [:]
  private var searchMatchCache: SearchMatchCacheEntry?
  private let searchEngine = ClipSearch()
  private var itemByID: [UUID: Clip] = [:]
  private var visibleIndexByID: [UUID: Int] = [:]
  private var selectedItemIDSet: Set<UUID> = []
  deinit { purgePendingDeletionUndo() }

  var targetApplicationProvider: () -> NSRunningApplication? = { nil }
  var willPasteToTarget: () -> Void = {}

  init(
    pasteboard: NSPasteboard = .general, store: HistoryStore, settings: SettingsModel, cacheService: MediaCache,
    dataCoordinator: DataCoordinator = DataCoordinator(),
    imageTextExtractor: @escaping (NSImage) -> String? = ImageTextExtractor.recognizedText(in:),
    thumbnailLoader: ((Clip) -> NSImage?)? = nil, transferFeedback: @escaping (TransferSound) -> Void = { _ in }
  ) {
    self.dataCoordinator = dataCoordinator
    self.store = store
    self.settings = settings
    self.cacheService = cacheService
    self.shelfState = ShelfState(sortMode: settings.defaultSortMode)
    self.pasteService = PasteActionService(pasteboard: pasteboard, cacheService: cacheService, feedback: transferFeedback)
    self.imageTextExtractor = imageTextExtractor
    self.thumbnailLoader = thumbnailLoader ?? { cacheService.previewThumbnail(for: $0) }

    store.observeItems { [weak self] list in
      guard let self else { return }
      let shouldDeferRecompute = self.isDeferringLocalStoreRecompute
      self.notifyMain {
        self.items = list
        if shouldDeferRecompute { return }
        self.recomputeVisibleItems()
      }
    }
    settings.observe { [weak self] change in
      self?.notifyMain {
        switch change {
        case .captureStatus, .pauseCapture: self?.publish(.capture)
        case .other: self?.recomputeVisibleItems()
        case .collections:
          guard let self else { return }
          self.collectionNamesCache = nil
          guard !self.isApplyingLocalCollectionMutation else { return }
          self.publish(.collections)
        case .defaultSortMode:
          guard let self else { return }
          self.sortMode = self.settings.defaultSortMode
        case .includeImageTextInSearch:
          guard let self else { return }
          self.collectionCountCache = nil
          self.visibleItemsCache.removeAll(keepingCapacity: true)
          self.searchMatchCache = nil
          let query = self.searchEngine.normalized(self.searchText)
          guard !query.isEmpty, !self.searchEngine.parse(query).textTokens.isEmpty else { return }
          self.recomputeVisibleItems()
        default: break
        }
      }
    }
  }

  var selectedItem: Clip? {
    guard selectedIndex >= 0, selectedIndex < visibleItems.count else { return nil }
    return visibleItems[selectedIndex]
  }

  var selectedItemCount: Int {
    let visibleSelectionCount = selectedItemIDs.reduce(into: 0) { count, id in if visibleIndexByID[id] != nil { count += 1 } }
    if visibleSelectionCount > 0 { return visibleSelectionCount }
    return selectedItem == nil ? 0 : 1
  }

  var canShowSelectedInClipboard: Bool { selectedItem != nil && canShowVisibleItemsInClipboard }

  var canShowVisibleItemsInClipboard: Bool {
    !visibleItems.isEmpty
      && (!searchText.clipboardTrimmed.isEmpty || sortMode != .mostRecent || contentFilter != nil || selectedCollectionName != nil)
  }

  var totalItemCount: Int { items.count }

  var collectionNames: [String] {
    if let collectionNamesCache { return collectionNamesCache }

    var assignedNamesByKey: [String: String] = [:]
    for item in items { if let name = PinboardNames.normalizedName(item.collectionName) { assignedNamesByKey[name.lowercased()] = name } }
    let assignedNames = Array(assignedNamesByKey.values)
    let configuredNames = settings.customCollectionNames
    let configuredNameSet = Set(configuredNames.map { $0.lowercased() })
    let assignedCustomNames = assignedNames.filter { !configuredNameSet.contains($0.lowercased()) }.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    let names = configuredNames + assignedCustomNames
    collectionNamesCache = names
    return names
  }

  func collectionCount(for sortMode: ShelfFilter) -> Int { collectionCountSummary().count(for: sortMode) }

  func collectionCount(named name: String) -> Int { collectionCountSummary().count(named: name) }

  func contentTypeCountsInCurrentScope() -> [ShelfFilter: Int] {
    if let cache = contentTypeCountCache, cache.revision == visibleItemsRevision { return cache.counts }
    let query = searchEngine.normalized(searchText)
    let scoped = cachedVisibleItems(query: query, sortMode: sortMode, collectionName: selectedCollectionName)
    var counts: [ShelfFilter: Int] = [.mostRecent: scoped.count]
    for type in ShelfFilter.allCases { counts[type] = scoped.filter { type.includes($0) }.count }
    contentTypeCountCache = (visibleItemsRevision, counts)
    return counts
  }

  func collectionCountSummary() -> ShelfCounts {
    let query = searchEngine.normalized(searchText)
    if let collectionCountCache, collectionCountCache.query == query { return collectionCountCache.summary }

    var sortModeCounts = Dictionary(uniqueKeysWithValues: ShelfFilter.allCases.map { ($0.rawValue, 0) })
    var collectionCounts: [String: Int] = [:]

    for indexedItem in indexedItemsMatchingSearch(query) {
      let item = indexedItem.item
      for mode in ShelfFilter.allCases where mode.includes(item) { sortModeCounts[mode.rawValue, default: 0] += 1 }
      if let collectionName = PinboardNames.normalizedName(item.collectionName) {
        collectionCounts[collectionName.lowercased(), default: 0] += 1
      }
    }

    let summary = ShelfCounts(sortModeCounts: sortModeCounts, collectionCounts: collectionCounts)
    collectionCountCache = (query, summary)
    return summary
  }

  var captureStatusMessage: String { settings.status(.capture) }

  /// Loads preview media away from the main thread and coalesces matching in-flight requests.
  /// The completion is always delivered asynchronously on the main queue.
  func loadThumbnail(for item: Clip, completion: @escaping (NSImage?) -> Void) {
    guard let requestKey = thumbnailRequestKey(for: item) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }

    thumbnailRequestLock.lock()
    if var completions = thumbnailCompletionsByRequest[requestKey] {
      completions.append(completion)
      thumbnailCompletionsByRequest[requestKey] = completions
      thumbnailRequestLock.unlock()
      return
    }
    thumbnailCompletionsByRequest[requestKey] = [completion]
    thumbnailRequestLock.unlock()

    thumbnailLoadQueue.addOperation { [self] in
      let thumbnail = self.thumbnailLoader(item)
      self.finishThumbnailRequest(requestKey, thumbnail: thumbnail)
    }
  }

  func selectItem(at index: Int, mode: ClipSelection = .replace) {
    guard index >= 0 && index < visibleItems.count else { return }
    let item = visibleItems[index]
    switch mode {
    case .replace: setActiveSelection(item, at: index, selectedIDs: [item.id], anchorID: item.id)
    case .toggle:
      var nextIDs = selectedItemIDs.isEmpty ? selectedItem.map { [$0.id] } ?? [] : selectedItemIDs
      if nextIDs.contains(item.id) { if nextIDs.count > 1 { nextIDs.removeAll { $0 == item.id } } } else { nextIDs.append(item.id) }
      setActiveSelection(item, at: index, selectedIDs: nextIDs, anchorID: item.id)
    case .range:
      let anchorIndex = selectionAnchorItemID.flatMap { visibleIndexByID[$0] } ?? selectedIndex
      let lower = min(anchorIndex, index)
      let upper = max(anchorIndex, index)
      let rangeIDs = visibleItems[lower...upper].map(\.id)
      let anchorID = visibleItems[anchorIndex].id
      setActiveSelection(item, at: index, selectedIDs: rangeIDs, anchorID: anchorID)
    case .hover:
      guard selectedItemID != item.id || selectedIndex != index || selectedItemIDs != [item.id] || selectionAnchorItemID != item.id else {
        return
      }
      setActiveSelection(item, at: index, selectedIDs: [item.id], anchorID: item.id)
    case .activate:
      if selectedItemIDSet.contains(item.id), selectedItemIDs.count > 1 {
        setActiveSelection(item, at: index, selectedIDs: selectedItemIDs, anchorID: selectionAnchorItemID ?? item.id)
      } else {
        setActiveSelection(item, at: index, selectedIDs: [item.id], anchorID: item.id)
      }
    }
  }

  func selectFirstItem() { selectEndpoint(at: 0) }

  func selectLastItem() { selectEndpoint(at: visibleItems.count - 1) }

  private func selectEndpoint(at index: Int) {
    guard visibleItems.indices.contains(index) else { return }
    let previousIndex = selectedIndex
    setIndexBasedSelection(at: index)
    if previousIndex == index { publish(.selection) }
  }

  func moveSelection(_ delta: Int) {
    let count = visibleItems.count
    guard count > 0 else { return }
    let target = max(0, min(count - 1, selectedIndex + delta))
    setIndexBasedSelection(at: target)
  }

  func selectAllVisibleItems() {
    guard !visibleItems.isEmpty else {
      selectedItemIDs = []
      statusMessage = "No clips to select"
      return
    }

    let activeIndex = max(0, min(visibleItems.count - 1, selectedIndex))
    let activeItem = visibleItems[activeIndex]
    selectedItemID = activeItem.id
    selectionAnchorItemID = activeItem.id
    selectedItemIDs = visibleItems.map(\.id)
    if selectedIndex == activeIndex { publish(.selection) } else { selectedIndex = activeIndex }
    let noun = visibleItems.count == 1 ? "clip" : "clips"
    statusMessage = "Selected \(visibleItems.count) \(noun)"
  }

  /// Returns false for commands that need a view, editor, or window.
  @discardableResult func performCommand(_ command: ClipCommand) -> Bool {
    switch command {
    case .paste: pasteSelected()
    case .copy: copySelected()
    case .pastePlainText: pasteSelectedPlainText()
    case .copyPlainText: copySelectedPlainText()
    case .pasteSelectionText: pasteSelectedItemsAsText()
    case .copySelectionText: copySelectedItemsAsText()
    case .rotateImage: rotateSelectedImageClockwise()
    case .extractImageText: extractTextFromSelectedImage()
    case .open: openSelected()
    case .reveal: revealSelected()
    case .togglePin: togglePinSelected()
    case .assignToCollection(let name): assignSelected(to: name)
    case .ignoreSourceApp: ignoreSelectedSourceApp()
    case .ignoreKind: ignoreSelectedKind()
    case .delete: deleteSelected()
    case .undoDelete: undoLastDelete()
    case .adjacentCollection(let delta): selectAdjacentCollection(delta: delta)
    default: return false
    }
    return true
  }

  func pasteSelected() { performSelectedTransfer(.paste) }

  func pasteSelectedPlainText() { performSelectedTransfer(.paste, asPlainText: true) }

  func pasteItem(at index: Int) {
    guard visibleItems.indices.contains(index) else { return }
    selectItem(at: index)
    pasteSelected()
  }

  func pasteItemPlainText(at index: Int) {
    guard visibleItems.indices.contains(index) else { return }
    selectItem(at: index)
    pasteSelectedPlainText()
  }

  func copySelected() { performSelectedTransfer(.copy) }

  func copySelectedPlainText() { performSelectedTransfer(.copy, asPlainText: true) }

  func isItemSelected(at index: Int) -> Bool {
    guard index >= 0 && index < visibleItems.count else { return false }
    return selectedItemIDSet.contains(visibleItems[index].id)
  }

  func copySelectedItemsAsText() { performSelectedTransfer(.copy, asPlainText: true, forceGroup: true) }

  func pasteSelectedItemsAsText() { performSelectedTransfer(.paste, asPlainText: true, forceGroup: true) }

  func pasteboardWriters(forItemAt index: Int) -> [NSPasteboardWriting] {
    guard index >= 0 && index < visibleItems.count else { return [] }
    return pasteService.pasteboardWriters(for: visibleItems[index])
  }

  func editableTextForSelected() -> String? {
    guard let item = selectedItem, item.kind == .text || item.kind == .code else { return nil }
    return item.payload
  }

  func updateTitle(itemID: UUID, to title: String) {
    guard let item = itemByID[itemID] else {
      statusMessage = "This clip is no longer available."
      return
    }
    let normalizedTitle = Clip.normalizedCustomTitle(title)
    guard item.customTitle != normalizedTitle else {
      statusMessage = "No changes"
      return
    }

    selectedItemID = item.id
    guard store.setCustomTitle(item.id, title: normalizedTitle) else {
      statusMessage = store.savingUnavailableMessage
      return
    }
    statusMessage = normalizedTitle == nil ? "Cleared clip title" : "Renamed clip"
  }

  @discardableResult func updateText(itemID: UUID, to text: String) -> Bool {
    guard let item = itemByID[itemID], item.kind == .text || item.kind == .code else {
      statusMessage = "This clip is no longer available. Copy your draft before closing."
      return false
    }
    guard store.canPersistHistory else {
      statusMessage = "Cannot save: \(store.savingUnavailableMessage) Your draft is still here."
      return false
    }
    let trimmed = text.clipboardTrimmed
    guard !trimmed.isEmpty else {
      statusMessage = "Text clip cannot be empty"
      return false
    }
    guard item.payload != text else {
      statusMessage = "No changes"
      return true
    }

    selectedItemID = item.id
    if store.updateText(item.id, text: text) {
      statusMessage = item.kind == .code ? "Updated code clip" : "Updated text clip"
      return true
    }
    statusMessage = "Could not update this clip. Your draft is still here."
    return false
  }

  @discardableResult func createTextClip(_ text: String) -> Bool {
    guard store.canPersistHistory else {
      statusMessage = "Cannot save: \(store.savingUnavailableMessage)"
      return false
    }
    let display = text.clipboardTrimmed
    guard !display.isEmpty else {
      statusMessage = "Text clip cannot be empty"
      return false
    }
    let now = Date()
    let collection = selectedCollectionName
    let item = Clip(
      id: UUID(), kind: CodeSnippetPayload.isLikelyCode(display) ? .code : .text, displayText: display, payload: text,
      payloadHash: store.hashString(text), createdAt: now, lastUsedAt: now, useCount: 0, sourceApp: AppConfig.appName, imagePath: nil,
      thumbnailPath: nil, sourceAppBundleId: Bundle.main.bundleIdentifier, collectionName: collection)
    guard let saved = store.upsert(item) else {
      statusMessage = store.savingUnavailableMessage
      return false
    }
    searchText = ""
    contentFilter = nil
    if collection == nil { selectSortMode(.mostRecent) }
    selectedItemID = saved.id
    recomputeVisibleItems()
    if let index = visibleItems.firstIndex(where: { $0.id == saved.id }) { selectItem(at: index) }
    statusMessage = "Created text clip"
    return true
  }

  func rotateSelectedImageClockwise(completion: (() -> Void)? = nil) {
    imageAction(unreadable: "Could not rotate image", completion: completion) { model, item, image in
      let storageID = UUID()
      guard let rotated = image.rotatedClockwise(), let fullData = rotated.pngData(),
        let thumbnailData = rotated.resized(to: CGSize(width: 320, height: 320)).pngData(),
        let fullPath = model.cacheService.cacheImageSidecarData(fullData, id: storageID)
      else { return "Could not rotate image" }
      guard let thumbnailPath = model.cacheService.cacheImageSidecarData(thumbnailData, id: storageID, fileNamePrefix: "thumb") else {
        model.cacheService.removeManagedFiles([fullPath])
        return "Could not rotate image"
      }
      let saved = DispatchQueue.main.sync {
        model.store.updateImage(item.id, imagePath: fullPath, thumbnailPath: thumbnailPath, payloadHash: model.store.hashData(fullData))
      }
      if !saved { model.cacheService.removeManagedFiles([fullPath, thumbnailPath]) }
      return saved ? "Rotated image" : "Could not save rotated image"
    }
  }

  func extractTextFromSelectedImage(completion: (() -> Void)? = nil) {
    imageAction(unreadable: "Could not read image", completion: completion) { model, item, image in
      guard let text = ImageTextExtractor.normalizedRecognizedText(model.imageTextExtractor(image)) else { return "No text found in image" }
      return DispatchQueue.main.sync { model.store.updateImageText(item.id, ocrText: text) }
        ? "Extracted text from image" : "Could not save image text"
    }
  }

  /// Media commands share one snapshot and worker queue; only the completed
  /// operation may publish feedback or change the stored clip on the main thread.
  private func imageAction(unreadable: String, completion: (() -> Void)?, work: @escaping (ShelfModel, Clip, NSImage) -> String) {
    guard let item = selectedItem, item.kind == .image else { return }
    selectedItemID = item.id
    mediaActionQueue.addOperation { [weak self] in
      guard let self else { return }
      let message =
        cacheService.data(for: item.imagePath ?? item.payload).flatMap(NSImage.init(data:)).map { work(self, item, $0) } ?? unreadable
      finishMediaAction(message: message, completion: completion)
    }
  }

  private func finishMediaAction(message: String, completion: (() -> Void)?) {
    DispatchQueue.main.async { [weak self] in
      self?.statusMessage = message
      completion?()
    }
  }

  func previewURLForSelected() -> URL? {
    guard let item = selectedItem else { return nil }
    return previewURL(for: item)
  }

  func reportPreviewUnavailable() { statusMessage = "Preview unavailable. The original file may have moved or been removed." }

  func linkPreviewRequestForSelected() -> LinkPreviewRequest? {
    guard let item = selectedItem else { return nil }
    return linkPreviewRequest(for: item)
  }

  internal func previewURL(for item: Clip) -> URL? { cacheService.temporaryPreviewURL(for: item) }

  internal func linkPreviewRequest(for item: Clip) -> LinkPreviewRequest? {
    guard let url = item.linkURL else { return nil }

    let title = ClipPresentation().titleText(for: item)
    return LinkPreviewRequest(url: url, title: title)
  }

  func openSelected() {
    guard let item = selectedItem else { return }
    switch item.presentationKind {
    case .url:
      guard let url = item.linkURL else { return }
      NSWorkspace.shared.open(url)
    case .file:
      guard let urls = fileActionURLs(for: item) else { return }
      NSWorkspace.shared.activateFileViewerSelecting(urls)
    case .image, .pdf, .audio, .video:
      guard let url = cacheService.temporaryReadableURL(for: item) else { return }
      NSWorkspace.shared.open(url)
    default: break
    }
  }

  func revealSelected() {
    guard let item = selectedItem, let urls = fileActionURLs(for: item) else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  private func fileActionURLs(for item: Clip) -> [URL]? {
    if item.kind == .file {
      let urls = FilePayload.urls(from: item.payload)
      return !urls.isEmpty && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : nil
    }
    guard [.image, .pdf, .audio, .video].contains(item.kind), let url = cacheService.temporaryReadableURL(for: item) else { return nil }
    return [url]
  }

  func deleteSelected() {
    let selectedItems = selectedItemsInSelectionOrder()
    guard !selectedItems.isEmpty else { return }

    purgePendingDeletionUndo()
    let originalVisibleCount = visibleItems.count
    let firstDeletedVisibleIndex = selectedItems.compactMap { item in visibleItems.firstIndex { $0.id == item.id } }.min() ?? selectedIndex

    guard let removals = store.remove(selectedItems.map(\.id), purgeManagedCache: false) else {
      statusMessage = store.savingUnavailableMessage
      return
    }

    pendingDeletionUndo = removals

    if visibleItems.isEmpty {
      selectedIndex = 0
      selectedItemID = nil
      selectionAnchorItemID = nil
      selectedItemIDs = []
    } else {
      let remainingVisibleCount = originalVisibleCount - removals.count
      let nextIndex = max(0, min(visibleItems.count - 1, min(firstDeletedVisibleIndex, remainingVisibleCount)))
      setIndexBasedSelection(at: nextIndex)
    }

    let noun = removals.count == 1 ? "clip" : "clips"
    statusMessage = "Deleted \(removals.count) \(noun)"
  }

  func clearHistory(since cutoff: Date) {
    purgePendingDeletionUndo()
    let ids = items.filter { $0.createdAt >= cutoff && !$0.isPinned && PinboardNames.normalizedName($0.collectionName) == nil }.map(\.id)
    guard !ids.isEmpty else {
      finishClearHistory(removedCount: 0)
      return
    }
    isDeferringLocalStoreRecompute = true
    let removed = store.remove(ids)
    isDeferringLocalStoreRecompute = false
    guard let removed else {
      statusMessage = store.savingUnavailableMessage
      return
    }
    recomputeVisibleItems()
    finishClearHistory(removedCount: removed.count)
  }

  func undoLastDelete() {
    guard !pendingDeletionUndo.isEmpty else {
      statusMessage = "Nothing to undo"
      return
    }

    let removals = pendingDeletionUndo
    guard store.restore(removals) else {
      statusMessage = store.savingUnavailableMessage
      return
    }
    pendingDeletionUndo = []

    let restoredIDs = removals.sorted(by: { $0.index < $1.index }).map(\.item.id)
    let visibleRestoredIDs = restoredIDs.filter { visibleIndexByID[$0] != nil }
    if let firstRestoredID = visibleRestoredIDs.first, let restoredIndex = visibleIndexByID[firstRestoredID] {
      setActiveSelection(visibleItems[restoredIndex], at: restoredIndex, selectedIDs: visibleRestoredIDs, anchorID: firstRestoredID)
    }

    let noun = removals.count == 1 ? "clip" : "clips"
    statusMessage = "Restored \(removals.count) \(noun)"
  }

  func togglePinSelected() {
    guard let item = selectedItem else { return }
    guard store.togglePin(item.id) else {
      statusMessage = store.savingUnavailableMessage
      return
    }
    statusMessage = item.isPinned ? "Unpinned clip" : "Pinned clip"
  }

  func assignSelected(to collectionName: String?) { assign(items: selectedItemsInSelectionOrder(), to: collectionName) }

  func assignItem(withID id: UUID, to collectionName: String?) {
    guard let item = itemByID[id] else { return }
    selectedItemID = selectedItem?.id
    assign(items: [item], to: collectionName)
  }

  func ignoreSelectedSourceApp() {
    guard let item = selectedItem else { return }
    guard let rule = sourceIgnoreRule(for: item) else {
      statusMessage = "Source app unavailable"
      return
    }

    let existing = settings.ignoredApps.map { $0.clipboardTrimmed.lowercased() }
    guard !existing.contains(rule.value.lowercased()) else {
      statusMessage = "\(rule.displayName) is already ignored"
      return
    }

    settings.ignoredApps.append(rule.value)
    statusMessage = "Ignored \(rule.displayName) for future captures"
  }

  func ignoreSelectedKind() {
    guard let item = selectedItem else { return }
    guard !settings.ignoredItemKindsRaw.contains(item.kind.rawValue) else {
      statusMessage = "\(item.kind.statusName) items are already ignored"
      return
    }

    settings.ignoredItemKindsRaw.append(item.kind.rawValue)
    if settings.ignoredItemKindsRaw.contains(item.kind.rawValue) {
      statusMessage = "Ignored \(item.kind.statusName) items for future captures"
    } else {
      statusMessage = "At least one content type must stay enabled."
    }
  }

  func selectSortMode(_ mode: ShelfFilter) { applyShelfAction(.sort(mode)) }

  func selectCollection(named name: String) { applyShelfAction(.collection(name)) }

  func selectAdjacentCollection(delta: Int) {
    guard delta != 0 else { return }
    let names = collectionNames
    guard !names.isEmpty else {
      statusMessage = "No collections"
      return
    }

    let targetIndex: Int
    if let selectedCollectionName,
      let currentIndex = names.firstIndex(where: { $0.caseInsensitiveCompare(selectedCollectionName) == .orderedSame })
    {
      targetIndex = (currentIndex + delta + names.count) % names.count
    } else {
      targetIndex = delta > 0 ? 0 : names.count - 1
    }

    let targetName = names[targetIndex]
    selectCollection(named: targetName)
    statusMessage = "Selected \(targetName)"
  }

  func createCollection(named name: String, colorHex: String? = nil, icon: String? = nil, selectAfterCreate: Bool = true) {
    isApplyingLocalCollectionMutation = true
    let createdName = settings.ensureCollection(named: name, colorHex: colorHex, icon: icon)
    isApplyingLocalCollectionMutation = false
    collectionNamesCache = nil
    guard let normalizedName = createdName else { return }
    statusMessage = "Created \(normalizedName)"
    if selectAfterCreate { selectCollection(named: normalizedName) } else { publish(.collections) }
  }

  func collectionColorHex(named name: String) -> String? { settings.collectionColorHex(forCollectionNamed: name) }

  func collectionIcon(named name: String) -> String? { settings.collectionIcon(forCollectionNamed: name) }

  func exportCollection(named name: String, to url: URL, completion: @escaping (Result<ArchiveSummary, Error>) -> Void) {
    dataCoordinator.perform({ [store] in Result { try store.exportCollection(named: name, to: url) } }) { [weak self] result in
      if case .success(let summary) = result, let normalizedName = PinboardNames.normalizedName(name) {
        let noun = summary.itemCount == 1 ? "clip" : "clips"
        self?.statusMessage = "Exported \(normalizedName) Pinboard with \(summary.itemCount) \(noun)"
      }
      completion(result)
    }
  }

  func reportCollectionExportFailure(_ error: Error) { statusMessage = "Export failed: \(error.localizedDescription)" }

  func updateCollection(named currentName: String, to newName: String, colorHex: String? = nil, icon: String? = nil) {
    guard let normalizedCurrentName = PinboardNames.normalizedName(currentName) else { return }

    guard let proposedName = PinboardNames.normalizedName(newName) else { return }
    let normalizedNewName =
      settings.customCollectionNames.first {
        $0.caseInsensitiveCompare(proposedName) == .orderedSame && $0.caseInsensitiveCompare(normalizedCurrentName) != .orderedSame
      } ?? proposedName
    let selectionChanged = selectedCollectionName?.caseInsensitiveCompare(normalizedCurrentName) == .orderedSame
    let ids = items.filter { $0.collectionName?.caseInsensitiveCompare(normalizedCurrentName) == .orderedSame }.map(\.id)
    guard
      mutateCollection(
        save: { store.setCollection(ids, name: normalizedNewName) },
        metadata: { settings.updateCollection(named: normalizedCurrentName, to: normalizedNewName, colorHex: colorHex, icon: icon) },
        selection: selectionChanged ? .collection(normalizedNewName) : nil)
    else { return }
    statusMessage = "Updated \(normalizedNewName)"
  }

  func deleteCollection(named name: String) {
    guard let normalizedName = PinboardNames.normalizedName(name) else { return }
    let matchingIDs = items.filter { $0.collectionName?.caseInsensitiveCompare(normalizedName) == .orderedSame }.map(\.id)
    let selectionChanged = selectedCollectionName?.caseInsensitiveCompare(normalizedName) == .orderedSame
    guard
      mutateCollection(
        save: { matchingIDs.isEmpty || store.remove(matchingIDs) != nil }, metadata: { settings.deleteCollection(named: normalizedName) },
        selection: selectionChanged ? .collection(nil) : nil)
    else { return }
    statusMessage = "Deleted \(normalizedName)"
  }

  /// Store publication is deferred until the matching metadata and destination
  /// are settled. A failed write leaves both metadata and selection untouched.
  private func mutateCollection(save: () -> Bool, metadata: () -> Void, selection: ShelfState.Action?) -> Bool {
    isDeferringLocalStoreRecompute = true
    guard save() else {
      isDeferringLocalStoreRecompute = false
      statusMessage = store.savingUnavailableMessage
      return false
    }
    isApplyingLocalCollectionMutation = true
    metadata()
    isApplyingLocalCollectionMutation = false
    collectionNamesCache = nil
    if let selection { applyShelfAction(selection) }
    isDeferringLocalStoreRecompute = false
    publish(.collections)
    recomputeVisibleItems()
    return true
  }

  func showSelectedInClipboard() {
    guard canShowSelectedInClipboard, let item = selectedItem else { return }
    selectedItemID = item.id
    applyShelfAction(.showAll)

    if let index = visibleIndexByID[item.id] {
      selectedIndex = index
      selectedItemID = item.id
    }
    statusMessage = "Showing in Clipboard"
  }

  func recomputeVisibleItems() {
    isRecomputingVisibleItems = true
    defer {
      isRecomputingVisibleItems = false
      hiddenCaptureIDs.removeAll { itemByID[$0] == nil || visibleIndexByID[$0] != nil }
      publish(.items)
    }
    let previousSelection = selectedItemID
    let previousSelectedIDs = selectedItemIDs
    let query = searchEngine.normalized(searchText)
    var result = cachedVisibleItems(query: query, sortMode: sortMode, collectionName: selectedCollectionName)

    if let contentFilter { result = result.filter { contentFilter.includes($0) } }
    if settings.sortByUsage {
      result.sort {
        if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    }

    visibleItems = result

    if let selectedID = previousSelection, let index = visibleIndexByID[selectedID] {
      selectedIndex = index
    } else if selectedIndex >= visibleItems.count {
      selectedIndex = max(0, visibleItems.count - 1)
    } else if selectedIndex < 0 {
      selectedIndex = 0
    }

    if visibleItems.isEmpty { selectedIndex = 0 }

    selectedItemID = selectedItem?.id
    let visibleSelectedIDs = previousSelectedIDs.filter { visibleIndexByID[$0] != nil }
    if previousSelection == nil {
      selectedItemIDs = selectedItemID.map { [$0] } ?? []
    } else if !visibleSelectedIDs.isEmpty {
      selectedItemIDs = visibleSelectedIDs
    } else if let selectedItemID {
      selectedItemIDs = [selectedItemID]
    } else {
      selectedItemIDs = []
    }
    if let selectionAnchorItemID, visibleIndexByID[selectionAnchorItemID] == nil { self.selectionAnchorItemID = selectedItemID }
  }

  private func setActiveSelection(_ item: Clip, at index: Int, selectedIDs: [UUID], anchorID: UUID?) {
    selectedItemID = item.id
    selectionAnchorItemID = anchorID
    selectedItemIDs = uniqueIDs(selectedIDs)
    if selectedIndex == index { publish(.selection) } else { selectedIndex = index }
  }

  private func setIndexBasedSelection(at index: Int) {
    guard index >= 0 && index < visibleItems.count else { return }
    let item = visibleItems[index]
    selectedItemID = nil
    selectionAnchorItemID = item.id
    selectedItemIDs = [item.id]
    if selectedIndex != index { selectedIndex = index }
  }

  private func uniqueIDs(_ ids: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return ids.filter { seen.insert($0).inserted }
  }

  private func rebuildItemIndexes() {
    itemByID = items.reduce(into: [:]) { index, item in if index[item.id] == nil { index[item.id] = item } }
  }

  private func selectedItemsInSelectionOrder() -> [Clip] {
    let items = selectedItemIDs.compactMap { visibleIndexByID[$0].map { visibleItems[$0] } }
    return items.isEmpty ? selectedItem.map { [$0] } ?? [] : items
  }

  private func plainTextPackage(for items: [Clip]) -> (text: String, items: [Clip])? {
    let pairs = items.compactMap { item -> (Clip, String)? in
      guard let text = pasteService.plainText(for: item)?.clipboardTrimmed, !text.isEmpty else { return nil }
      return (item, text)
    }
    guard !pairs.isEmpty else { return nil }
    return (pairs.map(\.1).joined(separator: "\n\n"), pairs.map(\.0))
  }

  private func performSelectedTransfer(_ intent: TransferIntent, asPlainText: Bool = false, forceGroup: Bool = false) {
    let items = selectedItemsInSelectionOrder()
    let isGroup = forceGroup || items.count > 1

    if asPlainText && isGroup {
      guard let package = plainTextPackage(for: items) else {
        statusMessage = "Selection has no text to \(intent == .copy ? "copy" : "paste")"
        return
      }
      completeTransfer(transfer(.text(package.text), intent), items: package.items, context: .selected)
      return
    }

    guard let item = items.first else { return }
    let content: PasteActionService.Content = asPlainText ? .plain(item) : (items.count == 1 ? .clip(item) : .clips(items))
    let result = transfer(content, intent)
    completeTransfer(result, items: items, context: isGroup ? .selected : .single)
  }

  private func transfer(_ content: PasteActionService.Content, _ intent: TransferIntent) -> PasteActionService.TransferResult {
    pasteService.transfer(content, intent, targetApp: intent == .paste ? targetApplicationProvider() : nil)
  }

  private func completeTransfer(_ result: PasteActionService.TransferResult, items: [Clip], context: TransferContext) {
    if case .failed(let message) = result {
      statusMessage = message
      if case .single = context { settings.setStatus(.paste, message) }
      return
    }

    if result.isPaste { willPasteToTarget() }

    store.markUsed(items.map(\.id))

    selectedItemID = items.first?.id
    statusMessage = result.message(selectedCount: context == .selected ? items.count : nil)
    settings.setStatus(.paste, statusMessage)
  }

  private func purgePendingDeletionUndo() {
    guard !pendingDeletionUndo.isEmpty else { return }
    store.purgeManagedCacheReferences(for: pendingDeletionUndo)
    pendingDeletionUndo = []
  }

  private func finishClearHistory(removedCount: Int) {
    guard removedCount > 0 else {
      statusMessage = "No clips to clear"
      return
    }
    let noun = removedCount == 1 ? "clip" : "clips"
    statusMessage = "Cleared \(removedCount) \(noun)"
  }

  private func indexedItemsMatchingSearch(_ query: String) -> [IndexedClipboardItem] {
    if let searchMatchCache, searchMatchCache.query == query { return searchMatchCache.indexedItems }

    let allIndexedItems = items.enumerated().map { IndexedClipboardItem(offset: $0.offset, item: $0.element) }
    let parsedQuery = searchEngine.parse(query)
    let matchingItems =
      parsedQuery.isEmpty
      ? allIndexedItems
      : allIndexedItems.filter { searchEngine.matches($0.item, query: parsedQuery, includeImageText: settings.includeImageTextInSearch) }

    searchMatchCache = SearchMatchCacheEntry(query: query, indexedItems: matchingItems)
    return matchingItems
  }

  private func cachedVisibleItems(query: String, sortMode: ShelfFilter, collectionName: String?) -> [Clip] {
    let collectionNameKey = PinboardNames.normalizedName(collectionName)?.lowercased()
    let key = VisibleItemsCacheKey(query: query, sortMode: sortMode.rawValue, collectionNameKey: collectionNameKey)
    if let cached = visibleItemsCache[key] { return cached }

    let computed = filterAndSortVisibleItems(indexedItemsMatchingSearch(query), sortMode: sortMode, collectionName: collectionName)
    if visibleItemsCache.count > 24 { visibleItemsCache.removeAll(keepingCapacity: true) }
    visibleItemsCache[key] = computed
    return computed
  }

  private func filterAndSortVisibleItems(_ indexedItems: [IndexedClipboardItem], sortMode: ShelfFilter, collectionName: String?) -> [Clip] {
    let collection = PinboardNames.normalizedName(collectionName)
    var filtered = indexedItems.filter { entry in
      if let collection { return entry.item.collectionName?.caseInsensitiveCompare(collection) == .orderedSame }
      return sortMode.includes(entry.item)
    }
    let byUsage = collection == nil && sortMode == .mostUsed
    let byCreation = collection != nil || sortMode == .mostRecent || sortMode == .pinned
    filtered.sort { lhs, rhs in
      if byUsage, lhs.item.useCount != rhs.item.useCount { return lhs.item.useCount > rhs.item.useCount }
      if lhs.item.lastUsedAt != rhs.item.lastUsedAt { return lhs.item.lastUsedAt > rhs.item.lastUsedAt }
      if byCreation, lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt > rhs.item.createdAt }
      return lhs.offset < rhs.offset
    }
    return filtered.map(\.item)
  }

  private func assign(items: [Clip], to collectionName: String?) {
    guard !items.isEmpty else { return }
    let normalizedName = PinboardNames.normalizedName(collectionName)
    isDeferringLocalStoreRecompute = true
    let saved = store.setCollection(items.map(\.id), name: normalizedName)
    isDeferringLocalStoreRecompute = false
    guard saved else {
      statusMessage = store.savingUnavailableMessage
      return
    }
    if let normalizedName {
      isApplyingLocalCollectionMutation = true
      settings.ensureCollection(named: normalizedName)
      isApplyingLocalCollectionMutation = false
    }
    recomputeVisibleItems()
    publish(.collections)
    if let normalizedName {
      statusMessage = items.count == 1 ? "Added to \(normalizedName)" : "Added \(items.count) clips to \(normalizedName)"
    } else {
      statusMessage = items.count == 1 ? "Removed from collection" : "Removed \(items.count) clips from collection"
    }
  }

  private func sourceIgnoreRule(for item: Clip) -> (value: String, displayName: String)? {
    if let bundleID = item.sourceAppBundleId?.clipboardTrimmed, !bundleID.isEmpty {
      let sourceApp = item.sourceApp?.clipboardTrimmed
      let display = sourceApp?.isEmpty == false ? sourceApp ?? bundleID : bundleID
      return (bundleID, display)
    }

    if let sourceApp = item.sourceApp?.clipboardTrimmed, !sourceApp.isEmpty { return (sourceApp, sourceApp) }

    return nil
  }

  private func thumbnailRequestKey(for item: Clip) -> ThumbnailRequestKey? {
    let source: String?
    switch item.kind {
    case .url, .image: source = item.thumbnailPath
    case .pdf, .file, .video: source = item.payload
    case .text, .unknown, .audio, .richText, .color, .code: return nil
    }
    return ThumbnailRequestKey(itemID: item.id, kindRawValue: item.kind.rawValue, source: source)
  }

  private func finishThumbnailRequest(_ requestKey: ThumbnailRequestKey, thumbnail: NSImage?) {
    thumbnailRequestLock.lock()
    let completions = thumbnailCompletionsByRequest.removeValue(forKey: requestKey) ?? []
    thumbnailRequestLock.unlock()
    guard !completions.isEmpty else { return }

    DispatchQueue.main.async { for completion in completions { completion(thumbnail) } }
  }

  private func publish(_ change: Change) { notifyMain { self.onChange?(change) } }

  private func notifyMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }
}
