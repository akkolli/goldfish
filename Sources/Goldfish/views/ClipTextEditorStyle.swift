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

/// Attached editors share ownership and completion. Their positioning policies
/// stay explicit because the text composer trails its action while pinboards
/// lead their destination button and can flip above it on short displays.
class AttachedEditorController: NSObject {
  enum Position { case text, pinboard }
  let window: ClipEditorPanel
  var isPresented: Bool { window.isVisible }
  private let position: Position
  private let onFinish: () -> Void
  private weak var parentWindow: NSWindow?
  private weak var anchorView: NSView?
  private var isFinished = false

  init(window: ClipEditorPanel, position: Position, onFinish: @escaping () -> Void) {
    self.window = window
    self.position = position
    self.onFinish = onFinish
    super.init()
  }

  func prepareForPresentation(relativeTo parent: NSWindow) {}

  func show(relativeTo parent: NSWindow, anchoredTo anchor: NSView?) {
    parentWindow = parent
    anchorView = anchor
    prepareForPresentation(relativeTo: parent)
    positionNearAnchor()
    window.attachToShelf(parent)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(window.initialFirstResponder)
  }

  func suspend() { if isPresented { window.detachFromShelf() } }

  func positionNearAnchor() {
    guard let parent = parentWindow else { return }
    let screen = parent.screen?.visibleFrame ?? parent.frame
    let source = anchorView.map { parent.convertToScreen($0.convert($0.bounds, to: nil)) }
    let left = max(parent.frame.minX + 8, screen.minX + 8)
    let right = max(left, min(parent.frame.maxX - window.frame.width - 8, screen.maxX - window.frame.width - 8))
    let x: CGFloat
    let y: CGFloat
    switch position {
    case .text:
      let fallback = parent.convertPoint(toScreen: NSPoint(x: parent.frame.width - 24, y: parent.frame.height - 52))
      x = (source?.maxX ?? fallback.x) - window.frame.width + 14
      y = max(screen.minY + 8, min((source?.minY ?? fallback.y) - window.frame.height - 6, screen.maxY - window.frame.height - 8))
    case .pinboard:
      x = (source?.minX ?? parent.frame.minX) - 8
      let below = (source?.minY ?? parent.frame.maxY) - window.frame.height - 6
      y = below >= screen.minY + 8 ? below : min((source?.maxY ?? parent.frame.maxY) + 6, screen.maxY - window.frame.height - 8)
    }
    window.setFrameOrigin(NSPoint(x: max(left, min(x, right)), y: y))
  }

  @objc func dismiss() {
    guard !isFinished else { return }
    isFinished = true
    window.detachFromShelf()
    onFinish()
  }
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
    tint.pinEdges(to: self)
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
      tint.layer?.backgroundColor = ShelfStyle.shelfTint.cgColor
      layer?.borderColor = ShelfStyle.shelfBorder.cgColor
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
