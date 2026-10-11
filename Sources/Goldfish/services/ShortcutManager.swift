import AppKit
import Carbon

final class ShortcutManager {
  enum RegistrationStatus: Equatable {
    case registered
    case unsupportedShortcut(String)
    case conflict(String)
    case registrationFailed(String)

    var message: String {
      switch self {
      case .registered: return ""
      case .unsupportedShortcut(let shortcut): return "Unsupported shortcut: \(shortcut)"
      case .conflict(let shortcut): return "Shortcut is already in use: \(shortcut)"
      case .registrationFailed(let message): return "Shortcut registration failed: \(message)"
      }
    }
  }

  private enum HotKeyID: UInt32 { case openPanel = 1 }

  private let onOpenClipboardPanel: () -> Void
  private let onStatusChange: (RegistrationStatus) -> Void

  private var openBinding: ShortcutBinding
  private var openHotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  init(
    onOpenClipboardPanel: @escaping () -> Void, onStatusChange: @escaping (RegistrationStatus) -> Void = { _ in },
    openShortcut: ShortcutBinding
  ) {
    self.onOpenClipboardPanel = onOpenClipboardPanel
    self.onStatusChange = onStatusChange
    self.openBinding = openShortcut
  }

  deinit { stop() }

  @discardableResult func start() -> RegistrationStatus {
    stop()

    if let status = Self.validationFailure(for: openBinding) {
      onStatusChange(status)
      return status
    }

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
        manager.handle(event: event)
        return noErr
      }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

    guard installStatus == noErr else {
      let status = RegistrationStatus.registrationFailed(osStatusMessage(installStatus))
      onStatusChange(status)
      return status
    }

    let openStatus = register(binding: openBinding, id: .openPanel, target: &openHotKey)
    guard openStatus == .registered else {
      stop()
      onStatusChange(openStatus)
      return openStatus
    }

    onStatusChange(.registered)
    return .registered
  }

  @discardableResult func reconfigure(openShortcut: ShortcutBinding) -> RegistrationStatus {
    openBinding = openShortcut
    return start()
  }

  func stop() {
    if let openHotKey { UnregisterEventHotKey(openHotKey) }
    if let eventHandler { RemoveEventHandler(eventHandler) }

    openHotKey = nil
    eventHandler = nil
  }

  private func register(binding: ShortcutBinding, id: HotKeyID, target: inout EventHotKeyRef?) -> RegistrationStatus {
    guard let keyCode = Self.virtualKeyCode(for: binding.key) else { return .unsupportedShortcut(binding.displayText) }

    let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id.rawValue)
    let status = RegisterEventHotKey(
      UInt32(keyCode), Self.carbonModifiers(for: binding.modifierFlags), hotKeyID, GetApplicationEventTarget(), 0, &target)

    if status == noErr { return .registered }

    if status == eventHotKeyExistsErr { return .conflict(binding.displayText) }

    return .registrationFailed(osStatusMessage(status))
  }

  static func validationFailure(for binding: ShortcutBinding) -> RegistrationStatus? {
    guard Self.virtualKeyCode(for: binding.key) != nil else { return .unsupportedShortcut(binding.displayText) }
    let required = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.control.rawValue
    return binding.modifierFlags & required == 0 ? .unsupportedShortcut(binding.displayText) : nil
  }

  private func handle(event: EventRef?) {
    guard let event else { return }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
      &hotKeyID)

    guard status == noErr, hotKeyID.signature == Self.hotKeySignature else { return }

    switch HotKeyID(rawValue: hotKeyID.id) {
    case .openPanel: onOpenClipboardPanel()
    case nil: break
    }
  }

  static func virtualKeyCode(for key: String) -> UInt16? {
    guard key.utf8.count == 1 else { return nil }
    return Self.keyCodes[key.lowercased()].map(UInt16.init)
  }

  private static let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
    "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
    "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
    "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus,
    "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
  ]

  static func carbonModifiers(for modifierFlags: UInt) -> UInt32 {
    var carbonFlags: UInt32 = 0
    if modifierFlags & NSEvent.ModifierFlags.command.rawValue != 0 { carbonFlags |= UInt32(cmdKey) }
    if modifierFlags & NSEvent.ModifierFlags.option.rawValue != 0 { carbonFlags |= UInt32(optionKey) }
    if modifierFlags & NSEvent.ModifierFlags.control.rawValue != 0 { carbonFlags |= UInt32(controlKey) }
    if modifierFlags & NSEvent.ModifierFlags.shift.rawValue != 0 { carbonFlags |= UInt32(shiftKey) }
    return carbonFlags
  }

  private static let hotKeySignature: OSType = 0x436C_7042

  private func osStatusMessage(_ status: OSStatus) -> String { "OSStatus \(status)" }
}
