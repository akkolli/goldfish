import Foundation

/// Shelf filtering changes as one value. Legacy sort raw values stay compatible
/// with saved preferences; views do not coordinate partial filter transitions.
struct ShelfState: Equatable {
  enum Action {
    case search(String)
    case sort(ShelfFilter)
    case collection(String?)
    case content(ShelfFilter?)
    case reset, showAll
  }
  var query = ""
  var sortMode: ShelfFilter
  var collectionName: String?
  var contentFilter: ShelfFilter?

  mutating func apply(_ action: Action) {
    switch action {
    case .search(let query): self.query = query
    case .sort(let mode):
      sortMode = mode
      collectionName = nil
    case .collection(let name): collectionName = PinboardNames.normalizedName(name)
    case .content(let filter): contentFilter = filter
    case .reset, .showAll:
      sortMode = .mostRecent
      collectionName = nil
      contentFilter = nil
      if case .showAll = action { query = "" }
    }
  }
}
