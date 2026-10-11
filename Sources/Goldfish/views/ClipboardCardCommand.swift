import Foundation

/// Keyboard shortcuts, context menus, and VoiceOver use the same action path.
/// Navigation/hover remain separate because they do not act on clipboard data.
enum ClipboardCardCommand: Equatable {
  case paste
  case copy
  case pastePlainText
  case copyPlainText
  case pasteSelectionText
  case copySelectionText
  case showInClipboard
  case rename
  case editText
  case rotateImage
  case extractImageText
  case preview
  case togglePin
  case open
  case reveal
  case createCollection
  case ignoreSourceApp
  case ignoreKind
  case delete
  case undoDelete
  case assignToCollection(String?)
  case close
  case focusSearch
  case newText
  case adjacentCollection(Int)
  case toggleCapturePause

  /// Card actions preserve a multi-selection only when they operate on the group.
  var selectionMode: ClipboardSelectionMode? {
    switch self {
    case .undoDelete, .rename, .editText, .showInClipboard: return nil
    case .paste, .copy, .pastePlainText, .copyPlainText, .pasteSelectionText, .copySelectionText,
      .assignToCollection, .createCollection, .delete: return .activate
    default: return .replace
    }
  }
}

/// Navigation is independent of clipboard actions and pointer selection.
enum ClipboardCardNavigation: Equatable {
  case move(Int, extend: Bool)
  case page(Int, extend: Bool)
  case vertical(Int, extend: Bool)
  case endpoint(last: Bool, extend: Bool)
  case all

  static func key(_ code: UInt16, extend: Bool) -> Self? {
    switch code {
    case 115: return .endpoint(last: false, extend: extend)
    case 119: return .endpoint(last: true, extend: extend)
    case 116: return .page(-1, extend: extend)
    case 121: return .page(1, extend: extend)
    case 123: return .move(-1, extend: extend)
    case 124: return .move(1, extend: extend)
    default: return nil
    }
  }
}
