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

/// Resolve the window's shortcut precedence once; responders still own their
/// editing and navigation behavior. A nil searchText means cards own focus.
enum ShelfKeyAction: Equatable {
  case command(ClipCommand)
  case paste(index: Int, plain: Bool)
  case destination(ShelfFilter)
  case navigate(ShelfNavigation)
  case settings, cancel

  private static let quickPasteKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
  private static let collectionShortcuts: [UInt16: ShelfFilter] = [
    18: .mostRecent, 19: .mostUsed, 20: .text, 21: .links, 23: .images, 22: .files, 26: .pinned, 28: .audio, 25: .colors, 29: .code,
  ]

  static func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags, settingsShortcut: ShortcutBinding, searchText: String?) -> Self? {
    let flags = modifiers.intersection(.deviceIndependentFlagsMask)
    if let searchText, code == 49, flags.isEmpty, searchText.clipboardTrimmed.isEmpty { return .command(.preview) }
    if let index = quickPasteKeyCodes[code], flags == .command || flags == [.command, .shift] {
      return .paste(index: index, plain: flags.contains(.shift))
    }
    if flags == [.command, .option], let mode = collectionShortcuts[code] { return .destination(mode) }
    if ShortcutManager.virtualKeyCode(for: settingsShortcut.key) == code,
      flags == NSEvent.ModifierFlags(rawValue: settingsShortcut.modifierFlags).intersection(.deviceIndependentFlagsMask)
    {
      return .settings
    }
    if flags == .command, let command = ClipCommand.commandKeys[code] {
      if searchText != nil, [.copy, .undoDelete, .adjacentCollection(-1), .adjacentCollection(1)].contains(command) { return nil }
      return .command(command)
    }
    if flags == .shift, code == 36 { return .command(.pastePlainText) }
    if flags == [.command, .shift] {
      if code == 45 { return .command(.createCollection) }
      if code == 9 { return .command(.pastePlainText) }
    }
    guard searchText == nil else { return nil }
    if flags == .command {
      if code == 0 { return .navigate(.all) }
      if code == 126 || code == 125 { return .navigate(.endpoint(last: code == 125, extend: false)) }
    } else if flags.isEmpty || flags == .shift, let navigation = ShelfNavigation.key(code, extend: flags == .shift) {
      return .navigate(navigation)
    }
    // Preserve native fallback handling after modified shortcuts have had priority.
    switch code {
    case 53: return .cancel
    case 49: return .command(.preview)
    case 36: return .command(.paste)
    case 51, 117: return .command(.delete)
    default: return nil
    }
  }
}
