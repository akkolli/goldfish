import AppKit

class ClipEditorPanel: NSPanel {
  convenience init(title: String, size: NSSize) {
    self.init(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    self.title = title
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A document-style editor with an empty-state prompt at the text insertion origin.
/// The prompt is painted, so it never intercepts editing or becomes saved content.
final class ClipEditorTextView: NSTextView {
  override var string: String { didSet { needsDisplay = true } }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty else { return }
    let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
    ("Write or paste text…" as NSString).draw(
      at: origin, withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor])
  }
}

/// Match the shelf's material and tint while keeping text fully opaque.
final class ClipEditorSheetSurface: NSVisualEffectView {
  private let tint = NSView()
  private var displayOptionsObserver: NSObjectProtocol?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .sidebar
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 16
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    tint.wantsLayer = true
    tint.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tint)
    NSLayoutConstraint.activate([
      tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor),
      tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    refreshAppearance()
    displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refreshAppearance() }
  }

  required init?(coder: NSCoder) { nil }

  deinit { if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) } }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  private func refreshAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tint.layer?.backgroundColor = ClipboardShelfStyle.shelfTint.cgColor
      layer?.borderColor = ClipboardShelfStyle.shelfBorder.cgColor
    }
  }
}

extension NSWindow {
  /// All attached shelf surfaces share privacy, space membership, and ownership.
  func attachToShelf(_ parent: NSWindow, levelOffset: Int = 1, behavior: CollectionBehavior? = nil) {
    level = Level(rawValue: parent.level.rawValue + levelOffset)
    collectionBehavior = behavior ?? parent.collectionBehavior
    sharingType = parent.sharingType
    parent.addChildWindow(self, ordered: .above)
  }

  func detachFromShelf() {
    parent?.removeChildWindow(self)
    orderOut(nil)
  }
}
