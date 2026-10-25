import AppKit

extension Notification.Name { static let goldfishShortcutRecordingChanged = Notification.Name("Goldfish.ShortcutRecordingChanged") }

/// Record actual key events, including modifiers, without invoking app menus.
final class ShortcutRecorderButton: NSButton {
  var onRecord: ((ShortcutBinding) -> String?)?
  var binding: ShortcutBinding { didSet { if !isRecording { title = binding.displayText + "  · Change" } } }
  private(set) var isRecording = false

  init(binding: ShortcutBinding, label: String) {
    self.binding = binding
    super.init(frame: .zero)
    title = binding.displayText + "  · Change"
    bezelStyle = .rounded
    font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    target = self
    action = #selector(beginRecording)
    setAccessibilityLabel(label)
    setAccessibilityHelp("Press to record a keyboard shortcut. Press Escape to cancel.")
    widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
    for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus(_:)), name: name, object: nil)
    }
  }
  deinit { NotificationCenter.default.removeObserver(self) }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }

  @objc private func beginRecording() {
    window?.makeFirstResponder(self)
    setRecording(true)
  }
  func cancelRecording() { setRecording(false) }
  @objc private func windowLostFocus(_ notification: Notification) { if notification.object as? NSWindow === window { cancelRecording() } }

  private func setRecording(_ recording: Bool) {
    guard recording != isRecording else { return }
    isRecording = recording
    title = recording ? "Press shortcut…  Esc to cancel" : binding.displayText + "  · Change"
    setAccessibilityValue(recording ? "Recording shortcut" : binding.displayText)
    NotificationCenter.default.post(name: .goldfishShortcutRecordingChanged, object: self, userInfo: ["recording": recording])
  }

  override func resignFirstResponder() -> Bool {
    setRecording(false)
    return super.resignFirstResponder()
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else { return super.performKeyEquivalent(with: event) }
    record(event)
    return true
  }
  override func keyDown(with event: NSEvent) {
    if isRecording {
      record(event)
    } else if event.keyCode == 36 || event.keyCode == 49 {
      beginRecording()
    } else {
      super.keyDown(with: event)
    }
  }

  private func record(_ event: NSEvent) {
    if event.keyCode == 53 {
      setRecording(false)
      return
    }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let candidate = ShortcutBinding(key: (event.charactersIgnoringModifiers ?? "").lowercased(), modifierFlags: flags.rawValue)
    if let message = onRecord?(candidate) {
      title = "Try another shortcut…"
      NSAccessibility.post(
        element: self, notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
      return
    }
    binding = candidate
    setRecording(false)
  }
}
