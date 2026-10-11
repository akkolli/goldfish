import AppKit
import Foundation

enum ClipboardSelectionMode {
  case replace
  case toggle
  case range
  case hover
  case activate
}
struct ClipboardCollectionCountSummary {
  fileprivate let sortModeCounts: [Int: Int]
  fileprivate let collectionCounts: [String: Int]

  func count(for sortMode: ClipboardSortMode) -> Int { sortModeCounts[sortMode.rawValue] ?? 0 }

  func count(named name: String) -> Int {
    guard let normalizedName = ClipboardCollectionDefaults.normalizedName(name) else { return 0 }
    return collectionCounts[normalizedName.lowercased()] ?? 0
  }
}

final class ClipboardPanelViewModel {
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
    let item: ClipboardItem
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

  private enum TransferIntent {
    case copy
    case paste
  }

  private enum TransferContext {
    case single
    case selected
  }

  private(set) var visibleItemsRevision: UInt = 0
  private(set) var visibleItems: [ClipboardItem] = [] {
    didSet {
      visibleItemsRevision &+= 1
      var nextItemByID: [UUID: ClipboardItem] = [:]
      nextItemByID.reserveCapacity(visibleItems.count)
      var nextIndexByID: [UUID: Int] = [:]
      nextIndexByID.reserveCapacity(visibleItems.count)
      for (index, item) in visibleItems.enumerated() {
        if nextItemByID[item.id] == nil { nextItemByID[item.id] = item }
        if nextIndexByID[item.id] == nil { nextIndexByID[item.id] = index }
      }
      visibleItemByID = nextItemByID
      visibleIndexByID = nextIndexByID
      guard !isRecomputingVisibleItems else { return }
      publish(.items)
    }
  }
  private var shelfState: ClipboardShelfState
  var searchText: String {
    get { shelfState.query }
    set { applyShelfAction(.search(newValue)) }
  }
  var sortMode: ClipboardSortMode {
    get { shelfState.sortMode }
    set { applyShelfAction(.sort(newValue)) }
  }
  var selectedCollectionName: String? { shelfState.collectionName }

  private func applyShelfAction(_ action: ClipboardShelfState.Action) {
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
  var contentFilter: ClipboardSortMode? {
    get { shelfState.contentFilter }
    set { applyShelfAction(.content(newValue)) }
  }
  var sortByUsage: Bool {
    get { settings.sortByUsage }
    set { settings.sortByUsage = newValue }
  }
  var largerShelfText: Bool { settings.largerShelfText }
  var shelfLayout: ClipboardShelfLayout { settings.shelfLayout }
  var shelfWidth: ClipboardShelfWidth { settings.shelfWidth }
  var usesCardShelf: Bool { shelfLayout == .cards }
  var isCapturePaused: Bool { settings.pauseCapture }
  var canUndoDeletion: Bool { !pendingDeletionUndo.isEmpty }
  var sourceAppNames: [String] { Array(Set(items.compactMap(\.sourceApp))).sorted() }
  private var hiddenCaptureIDs: [UUID] = []
  var hiddenCaptureCount: Int { hiddenCaptureIDs.count }
  var hasActiveFilters: Bool {
    !searchText.clipboardTrimmed.isEmpty || contentFilter != nil || (sortMode != .mostRecent && sortMode != .mostUsed)
      || selectedCollectionName != nil
  }

  /// Called after a clipboard capture has reached the store, independently of
  /// action feedback so background copies cannot replace Undo or paste results.
  func didCaptureItem(_ item: ClipboardItem) {
    guard itemByID[item.id] != nil else { return }
    guard visibleItemByID[item.id] == nil else { return }
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

  private var items: [ClipboardItem] = [] {
    didSet {
      rebuildItemIndexes()
      collectionNamesCache = nil
      visibleItemsCache.removeAll(keepingCapacity: true)
      collectionCountCache = nil
      searchMatchCache = nil
      searchEngine.pruneDocuments(validIDs: itemIDSet)
    }
  }
  private let store: ClipboardStore
  private let settings: SettingsModel
  private let cacheService: ClipboardCacheService
  private let dataCoordinator: ClipboardDataCoordinator
  private let pasteService: PasteActionService
  private let imageTextExtractor: (NSImage) -> String?
  private let thumbnailLoader: (ClipboardItem) -> NSImage?
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
  private var pendingDeletionUndo: [ClipboardStoreRemoval] = []
  private var contentTypeCountCache: (revision: UInt, counts: [ClipboardSortMode: Int])?
  private var collectionCountCache: (query: String, summary: ClipboardCollectionCountSummary)?
  private var collectionNamesCache: [String]?
  private var visibleItemsCache: [VisibleItemsCacheKey: [ClipboardItem]] = [:]
  private var searchMatchCache: SearchMatchCacheEntry?
  private let searchEngine = ClipboardPanelSearchEngine()
  private var itemByID: [UUID: ClipboardItem] = [:]
  private var itemIDSet: Set<UUID> = []
  private var visibleItemByID: [UUID: ClipboardItem] = [:]
  private var visibleIndexByID: [UUID: Int] = [:]
  private var selectedItemIDSet: Set<UUID> = []
  deinit { purgePendingDeletionUndo() }

  var targetApplicationProvider: () -> NSRunningApplication? = { nil }
  var willPasteToTarget: () -> Void = {}

  init(
    pasteboard: NSPasteboard = .general, store: ClipboardStore, settings: SettingsModel, cacheService: ClipboardCacheService,
    dataCoordinator: ClipboardDataCoordinator = ClipboardDataCoordinator(),
    imageTextExtractor: @escaping (NSImage) -> String? = ImageTextExtractor.recognizedText(in:),
    thumbnailLoader: ((ClipboardItem) -> NSImage?)? = nil, transferFeedback: @escaping (ClipboardSound) -> Void = { _ in }
  ) {
    self.dataCoordinator = dataCoordinator
    self.store = store
    self.settings = settings
    self.cacheService = cacheService
    self.shelfState = ClipboardShelfState(sortMode: settings.defaultSortMode)
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

  var selectedItem: ClipboardItem? {
    guard selectedIndex >= 0, selectedIndex < visibleItems.count else { return nil }
    return visibleItems[selectedIndex]
  }

  var selectedItemCount: Int {
    let visibleSelectionCount = selectedItemIDs.reduce(into: 0) { count, id in if visibleItemByID[id] != nil { count += 1 } }
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
    for item in items {
      if let name = ClipboardCollectionDefaults.normalizedName(item.collectionName) { assignedNamesByKey[name.lowercased()] = name }
    }
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

  func collectionCount(for sortMode: ClipboardSortMode) -> Int { collectionCountSummary().count(for: sortMode) }

  func collectionCount(named name: String) -> Int { collectionCountSummary().count(named: name) }

  func contentTypeCountsInCurrentScope() -> [ClipboardSortMode: Int] {
    if let cache = contentTypeCountCache, cache.revision == visibleItemsRevision { return cache.counts }
    let query = searchEngine.normalized(searchText)
    let scoped = cachedVisibleItems(query: query, sortMode: sortMode, collectionName: selectedCollectionName)
    var counts: [ClipboardSortMode: Int] = [.mostRecent: scoped.count]
    for type in ClipboardSortMode.allCases { counts[type] = scoped.filter { type.includes($0) }.count }
    contentTypeCountCache = (visibleItemsRevision, counts)
    return counts
  }

  func collectionCountSummary() -> ClipboardCollectionCountSummary {
    let query = searchEngine.normalized(searchText)
    if let collectionCountCache, collectionCountCache.query == query { return collectionCountCache.summary }

    var sortModeCounts = Dictionary(uniqueKeysWithValues: ClipboardSortMode.allCases.map { ($0.rawValue, 0) })
    var collectionCounts: [String: Int] = [:]

    for indexedItem in indexedItemsMatchingSearch(query) {
      let item = indexedItem.item
      for mode in ClipboardSortMode.allCases where mode.includes(item) { sortModeCounts[mode.rawValue, default: 0] += 1 }
      if let collectionName = ClipboardCollectionDefaults.normalizedName(item.collectionName) {
        collectionCounts[collectionName.lowercased(), default: 0] += 1
      }
    }

    let summary = ClipboardCollectionCountSummary(sortModeCounts: sortModeCounts, collectionCounts: collectionCounts)
    collectionCountCache = (query, summary)
    return summary
  }

  var captureStatusMessage: String { settings.captureStatusMessage }

  /// Loads preview media away from the main thread and coalesces matching in-flight requests.
  /// The completion is always delivered asynchronously on the main queue.
  func loadThumbnail(for item: ClipboardItem, completion: @escaping (NSImage?) -> Void) {
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

  func selectItem(at index: Int, mode: ClipboardSelectionMode = .replace) {
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
  @discardableResult func performCommand(_ command: ClipboardCardCommand) -> Bool {
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
    let normalizedTitle = ClipboardItem.normalizedCustomTitle(title)
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
    let item = ClipboardItem(
      id: UUID(), kind: CodeSnippetPayload.isLikelyCode(display) ? .code : .text, displayText: display, payload: text,
      payloadHash: store.hashString(text), createdAt: now, lastUsedAt: now, useCount: 0, sourceApp: AppConfiguration.appName,
      imagePath: nil, thumbnailPath: nil, sourceAppBundleId: Bundle.main.bundleIdentifier, collectionName: collection)
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
    guard let item = selectedItem, item.kind == .image else { return }
    let imagePath = item.imagePath ?? item.payload
    selectedItemID = item.id
    mediaActionQueue.addOperation { [weak self] in
      guard let self else { return }
      let message: String
      let storageID = UUID()
      if let data = self.cacheService.data(for: imagePath), let image = NSImage(data: data), let rotated = image.rotatedClockwise(),
        let fullData = rotated.pngData(), let thumbnailData = rotated.resized(to: CGSize(width: 320, height: 320)).pngData(),
        let fullPath = self.cacheService.cacheImageSidecarData(fullData, id: storageID),
        let thumbnailPath = self.cacheService.cacheImageSidecarData(thumbnailData, id: storageID, fileNamePrefix: "thumb")
      {
        let didUpdate = DispatchQueue.main.sync {
          self.store.updateImage(item.id, imagePath: fullPath, thumbnailPath: thumbnailPath, payloadHash: self.store.hashData(fullData))
        }
        if !didUpdate { self.cacheService.removeManagedFiles([fullPath, thumbnailPath]) }
        message = didUpdate ? "Rotated image" : "Could not save rotated image"
      } else {
        message = "Could not rotate image"
      }
      self.finishMediaAction(message: message, completion: completion)
    }
  }

  func extractTextFromSelectedImage(completion: (() -> Void)? = nil) {
    guard let item = selectedItem, item.kind == .image else { return }
    let imagePath = item.imagePath ?? item.payload
    selectedItemID = item.id
    mediaActionQueue.addOperation { [weak self] in
      guard let self else { return }
      let message: String
      if let data = self.cacheService.data(for: imagePath), let image = NSImage(data: data) {
        if let text = ImageTextExtractor.normalizedRecognizedText(self.imageTextExtractor(image)) {
          message =
            DispatchQueue.main.sync { self.store.updateImageText(item.id, ocrText: text) }
            ? "Extracted text from image" : "Could not save image text"
        } else {
          message = "No text found in image"
        }
      } else {
        message = "Could not read image"
      }
      self.finishMediaAction(message: message, completion: completion)
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

  internal func previewURL(for item: ClipboardItem) -> URL? { cacheService.temporaryPreviewURL(for: item) }

  internal func linkPreviewRequest(for item: ClipboardItem) -> LinkPreviewRequest? {
    guard let url = item.linkURL else { return nil }

    let title = ClipboardItemCardContentFormatter().titleText(for: item)
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

  private func fileActionURLs(for item: ClipboardItem) -> [URL]? {
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
    let ids = items.filter {
      $0.createdAt >= cutoff && !$0.isPinned && ClipboardCollectionDefaults.normalizedName($0.collectionName) == nil
    }.map(\.id)
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
      statusMessage = "\(Self.statusKindName(item.kind)) items are already ignored"
      return
    }

    settings.ignoredItemKindsRaw.append(item.kind.rawValue)
    if settings.ignoredItemKindsRaw.contains(item.kind.rawValue) {
      statusMessage = "Ignored \(Self.statusKindName(item.kind)) items for future captures"
    } else {
      statusMessage = "At least one content type must stay enabled."
    }
  }

  func selectSortMode(_ mode: ClipboardSortMode) { applyShelfAction(.sort(mode)) }

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

  func exportCollection(named name: String, to url: URL, completion: @escaping (Result<ClipboardArchiveSummary, Error>) -> Void) {
    dataCoordinator.perform({ [store] in Result { try store.exportCollection(named: name, to: url) } }) { [weak self] result in
      if case .success(let summary) = result, let normalizedName = ClipboardCollectionDefaults.normalizedName(name) {
        let noun = summary.itemCount == 1 ? "clip" : "clips"
        self?.statusMessage = "Exported \(normalizedName) Pinboard with \(summary.itemCount) \(noun)"
      }
      completion(result)
    }
  }

  func reportCollectionExportFailure(_ error: Error) { statusMessage = "Export failed: \(error.localizedDescription)" }

  func updateCollection(named currentName: String, to newName: String, colorHex: String? = nil, icon: String? = nil) {
    guard let normalizedCurrentName = ClipboardCollectionDefaults.normalizedName(currentName) else { return }

    guard let proposedName = ClipboardCollectionDefaults.normalizedName(newName) else { return }
    let normalizedNewName =
      settings.customCollectionNames.first {
        $0.caseInsensitiveCompare(proposedName) == .orderedSame && $0.caseInsensitiveCompare(normalizedCurrentName) != .orderedSame
      } ?? proposedName
    let selectionChanged = selectedCollectionName?.caseInsensitiveCompare(normalizedCurrentName) == .orderedSame
    isDeferringLocalStoreRecompute = true
    let ids = items.filter { $0.collectionName?.caseInsensitiveCompare(normalizedCurrentName) == .orderedSame }.map(\.id)
    guard store.setCollection(ids, name: normalizedNewName) else {
      isDeferringLocalStoreRecompute = false
      statusMessage = store.savingUnavailableMessage
      return
    }
    isApplyingLocalCollectionMutation = true
    settings.updateCollection(named: normalizedCurrentName, to: normalizedNewName, colorHex: colorHex, icon: icon)
    isApplyingLocalCollectionMutation = false
    collectionNamesCache = nil
    if selectionChanged { applyShelfAction(.collection(normalizedNewName)) }
    isDeferringLocalStoreRecompute = false
    publish(.collections)
    recomputeVisibleItems()
    statusMessage = "Updated \(normalizedNewName)"
  }

  func deleteCollection(named name: String) {
    guard let normalizedName = ClipboardCollectionDefaults.normalizedName(name) else { return }
    let matchingIDs = items.filter { $0.collectionName?.caseInsensitiveCompare(normalizedName) == .orderedSame }.map(\.id)
    let selectionChanged = selectedCollectionName?.caseInsensitiveCompare(normalizedName) == .orderedSame
    isDeferringLocalStoreRecompute = true
    if !matchingIDs.isEmpty, store.remove(matchingIDs) == nil {
      isDeferringLocalStoreRecompute = false
      statusMessage = store.savingUnavailableMessage
      return
    }
    isApplyingLocalCollectionMutation = true
    settings.deleteCollection(named: normalizedName)
    isApplyingLocalCollectionMutation = false
    collectionNamesCache = nil
    if selectionChanged { applyShelfAction(.collection(nil)) }
    isDeferringLocalStoreRecompute = false
    publish(.collections)
    recomputeVisibleItems()
    statusMessage = "Deleted \(normalizedName)"
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
      hiddenCaptureIDs.removeAll { itemByID[$0] == nil || visibleItemByID[$0] != nil }
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

  private func setActiveSelection(_ item: ClipboardItem, at index: Int, selectedIDs: [UUID], anchorID: UUID?) {
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
    itemIDSet = Set(itemByID.keys)
  }

  private func selectedItemsInSelectionOrder() -> [ClipboardItem] {
    let items = selectedItemIDs.compactMap { visibleItemByID[$0] }
    return items.isEmpty ? selectedItem.map { [$0] } ?? [] : items
  }

  private func plainTextPackage(for items: [ClipboardItem]) -> (text: String, items: [ClipboardItem])? {
    let pairs = items.compactMap { item -> (ClipboardItem, String)? in
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
      completeTransfer(plainTextTransfer(intent, value: package.text), items: package.items, context: .selected)
      return
    }

    guard let item = items.first else { return }
    let result = asPlainText ? plainTextTransfer(intent, item: item) : originalTransfer(intent, items: items)
    completeTransfer(result, items: items, context: isGroup ? .selected : .single)
  }

  private func originalTransfer(_ intent: TransferIntent, items: [ClipboardItem]) -> PasteActionService.PasteActionResult {
    if let item = items.first, items.count == 1 {
      return intent == .copy ? pasteService.copy(item) : pasteService.paste(item, targetApp: targetApplicationProvider())
    }
    return intent == .copy ? pasteService.copy(items) : pasteService.paste(items, targetApp: targetApplicationProvider())
  }

  private func plainTextTransfer(_ intent: TransferIntent, item: ClipboardItem) -> PasteActionService.PasteActionResult {
    intent == .copy ? pasteService.copyPlainText(item) : pasteService.pastePlainText(item, targetApp: targetApplicationProvider())
  }

  private func plainTextTransfer(_ intent: TransferIntent, value: String) -> PasteActionService.PasteActionResult {
    intent == .copy ? pasteService.copyPlainText(value) : pasteService.pastePlainText(value, targetApp: targetApplicationProvider())
  }

  private func completeTransfer(_ result: PasteActionService.PasteActionResult, items: [ClipboardItem], context: TransferContext) {
    if case .failed(let message) = result {
      statusMessage = message
      if case .single = context { settings.setPasteStatus(message: message) }
      return
    }

    if case .pasted = result { willPasteToTarget() } else if case .pastedPlainText = result { willPasteToTarget() }

    store.markUsed(items.map(\.id))

    selectedItemID = items.first?.id
    statusMessage = transferStatus(result, count: items.count, context: context)
    settings.setPasteStatus(message: statusMessage)
  }

  private func transferStatus(_ result: PasteActionService.PasteActionResult, count: Int, context: TransferContext) -> String {
    let noun = count == 1 ? "clip" : "clips"
    switch (context, result) {
    case (.single, _): return result.message
    case (.selected, .pasted): return "Pasted \(count) selected \(noun)"
    case (.selected, .copied): return "Copied \(count) selected \(noun)"
    case (.selected, .copiedNeedsPermission): return "Copied \(count) selected \(noun). Grant Accessibility access to paste automatically."
    case (.selected, .pastedPlainText): return "Pasted \(count) selected \(noun) as Text"
    case (.selected, .copiedPlainText): return "Copied \(count) selected \(noun) as Text"
    case (.selected, .copiedPlainTextNeedsPermission):
      return "Copied \(count) selected \(noun) as Text. Grant Accessibility access to paste automatically."
    default: return result.message
    }
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

  private func cachedVisibleItems(query: String, sortMode: ClipboardSortMode, collectionName: String?) -> [ClipboardItem] {
    let collectionNameKey = ClipboardCollectionDefaults.normalizedName(collectionName)?.lowercased()
    let key = VisibleItemsCacheKey(query: query, sortMode: sortMode.rawValue, collectionNameKey: collectionNameKey)
    if let cached = visibleItemsCache[key] { return cached }

    let computed = filterAndSortVisibleItems(indexedItemsMatchingSearch(query), sortMode: sortMode, collectionName: collectionName)
    if visibleItemsCache.count > 24 { visibleItemsCache.removeAll(keepingCapacity: true) }
    visibleItemsCache[key] = computed
    return computed
  }

  private func filterAndSortVisibleItems(_ indexedItems: [IndexedClipboardItem], sortMode: ClipboardSortMode, collectionName: String?)
    -> [ClipboardItem]
  {
    let collection = ClipboardCollectionDefaults.normalizedName(collectionName)
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

  private func assign(items: [ClipboardItem], to collectionName: String?) {
    guard !items.isEmpty else { return }
    let normalizedName = ClipboardCollectionDefaults.normalizedName(collectionName)
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

  private func sourceIgnoreRule(for item: ClipboardItem) -> (value: String, displayName: String)? {
    if let bundleID = item.sourceAppBundleId?.clipboardTrimmed, !bundleID.isEmpty {
      let sourceApp = item.sourceApp?.clipboardTrimmed
      let display = sourceApp?.isEmpty == false ? sourceApp ?? bundleID : bundleID
      return (bundleID, display)
    }

    if let sourceApp = item.sourceApp?.clipboardTrimmed, !sourceApp.isEmpty { return (sourceApp, sourceApp) }

    return nil
  }

  private func thumbnailRequestKey(for item: ClipboardItem) -> ThumbnailRequestKey? {
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

  private static func statusKindName(_ kind: ClipboardItemKind) -> String {
    let name = kind.displayName
    return name == name.uppercased() ? name : name.capitalized
  }

  private func publish(_ change: Change) { notifyMain { self.onChange?(change) } }

  private func notifyMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }
}
