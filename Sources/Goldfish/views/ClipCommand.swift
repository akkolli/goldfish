import AppKit

/// Keyboard shortcuts, context menus, and VoiceOver use the same action path.
/// Navigation/hover remain separate because they do not act on clipboard data.
enum ClipCommand: Equatable {
  case paste, copy, pastePlainText, copyPlainText, pasteSelectionText, copySelectionText
  case showInClipboard, rename, editText, rotateImage, extractImageText, preview, togglePin, open, reveal
  case createCollection, ignoreSourceApp, ignoreKind, delete, undoDelete
  case assignToCollection(String?)
  case close, focusSearch, newText, toggleCapturePause
  case adjacentCollection(Int)

  /// One command-key catalog for the shelf and cards. The card responder keeps
  /// its narrower scope; panel-level commands still belong to the window monitor.
  static let commandKeys: [UInt16: ClipCommand] = [
    13: .close, 8: .copy, 3: .focusSearch, 14: .editText, 45: .newText, 35: .togglePin, 31: .open, 5: .showInClipboard, 16: .preview,
    15: .rename, 17: .toggleCapturePause, 6: .undoDelete, 123: .adjacentCollection(-1), 124: .adjacentCollection(1),
  ]

  static func cardKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags, canEdit: Bool, canOpen: Bool) -> ClipCommand? {
    if modifiers == .command {
      guard let command = commandKeys[code] else { return nil }
      switch command {
      case .copy, .showInClipboard, .undoDelete, .rename, .preview: return command
      case .editText: return canEdit ? command : nil
      case .open: return canOpen ? command : nil
      default: return nil
      }
    }
    if modifiers == [.command, .shift] { return [9, 36, 76].contains(code) ? .pastePlainText : nil }
    if modifiers == .shift { return [36, 76].contains(code) ? .pastePlainText : nil }
    // The native card's unmodified command handling also accepts other modifier
    // combinations; those must not take the exact Command/Shift branches above.
    switch code {
    case 36, 76: return .paste
    case 49: return .preview
    case 51, 117: return .delete
    default: return nil
    }
  }

  /// Card actions preserve a multi-selection only when they operate on the group.
  var selectionMode: ClipSelection? {
    switch self {
    case .undoDelete, .rename, .editText, .showInClipboard: return nil
    case .paste, .copy, .pastePlainText, .copyPlainText, .pasteSelectionText, .copySelectionText, .assignToCollection, .createCollection,
      .delete:
      return .activate
    default: return .replace
    }
  }
}

/// Navigation is independent of clipboard actions and pointer selection.
enum ShelfNavigation: Equatable {
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
