import AppKit

final class ClipTextEditorController: NSObject, NSTextViewDelegate {
  private enum Metrics {
    static let compactEditorHeight: CGFloat = 44
    static let maximumEditorHeight: CGFloat = 228
    static let editorHeightStep: CGFloat = 18
    static let chromeHeight: CGFloat = 54
    static let errorHeight: CGFloat = 36
  }

  let window: ClipEditorPanel
  var isPresented: Bool { window.isVisible }
  private let editor: NSTextView
  private weak var parentWindow: NSWindow?
  private weak var anchorView: NSView?
  private var isFinished = false
  private var editorHeightConstraint: NSLayoutConstraint!
  private var editorHeight: CGFloat
  private var isShowingError = false
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let saveButton: ClipboardToolbarIconButton
  private let onSave: (String) -> String?
  private let onFinish: () -> Void

  init(title: String, editor: NSTextView, onSave: @escaping (String) -> String?, onFinish: @escaping () -> Void) {
    self.editor = editor
    editorHeight = Self.preferredEditorHeight(for: editor)
    self.onSave = onSave
    self.onFinish = onFinish
    saveButton = ClipboardToolbarIconButton(title: "Save", target: nil, action: nil)
    window = ClipEditorPanel(title: title, size: NSSize(width: 300, height: editorHeight + Metrics.chromeHeight))
    super.init()

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.becomesKeyOnlyIfNeeded = false

    let root = ClipEditorSheetSurface(frame: window.contentView?.bounds ?? .zero)
    window.contentView = root
    let isCreating = title == "New Text Clip"
    let heading = NativeUI.label(
      isCreating ? "New clip" : "Edit clip", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)

    let cancelButton = ClipboardToolbarIconButton(title: "Cancel", target: self, action: #selector(cancel))
    cancelButton.keyEquivalent = "\u{1b}"
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.keyEquivalent = "\r"
    saveButton.keyEquivalentModifierMask = .command
    for (button, symbol, label) in [(cancelButton, "xmark", "Cancel"), (saveButton, "checkmark", "Save")] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
        .init(pointSize: 12, weight: .semibold))
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.bezelStyle = .smallSquare
      button.isBordered = false
      button.configureAppearance(size: 30)
      button.widthAnchor.constraint(equalToConstant: 30).isActive = true
      button.heightAnchor.constraint(equalToConstant: 30).isActive = true
      button.toolTip = label == "Save" ? "Save (Command-Return)" : "Cancel (Escape)"
      button.setAccessibilityLabel(label)
    }

    let divider = NSBox()
    divider.boxType = .separator
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    editor.drawsBackground = false
    editor.font = .systemFont(ofSize: 14)
    editor.textColor = .textColor
    editor.insertionPointColor = .controlAccentColor
    editor.textContainerInset = NSSize(width: 0, height: 4)
    editor.textContainer?.lineFragmentPadding = 0
    scroll.documentView = editor

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .systemRed
    statusLabel.maximumNumberOfLines = 2
    statusLabel.isHidden = true

    for view in [heading, cancelButton, saveButton, divider, scroll, statusLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    editorHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: editorHeight)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      heading.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -16),
      saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      saveButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
      cancelButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor), divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: root.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor, constant: 42),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 48), editorHeightConstraint,
      statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
      statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
      statusLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 30),
    ])

    editor.delegate = self
    editor.setAccessibilityLabel(isCreating ? "New clip text" : "Clip text")
    window.initialFirstResponder = editor
    validate()
  }

  func show(relativeTo parent: NSWindow, anchoredTo anchor: NSView?) {
    parentWindow = parent
    anchorView = anchor
    window.setContentSize(NSSize(width: min(300, parent.frame.width - 20), height: sheetHeight))
    window.contentView?.layoutSubtreeIfNeeded()
    updateEditorHeight()
    positionNearAnchor()
    window.attachToShelf(parent)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
  }

  func suspend() {
    guard isPresented else { return }
    window.detachFromShelf()
  }

  private func positionNearAnchor() {
    guard let parentWindow else { return }
    let parent = parentWindow.frame
    let screen = parentWindow.screen?.visibleFrame ?? parent
    let buttonRect = anchorView?.convert(anchorView?.bounds ?? .zero, to: nil)
    let anchorPoint = parentWindow.convertPoint(
      toScreen: NSPoint(x: buttonRect?.maxX ?? parentWindow.frame.width - 24, y: buttonRect?.minY ?? parentWindow.frame.height - 52))
    let width = window.frame.width
    let height = window.frame.height
    let left = max(parent.minX + 8, screen.minX + 8)
    let right = min(parent.maxX - width - 8, screen.maxX - width - 8)
    let x = max(left, min(anchorPoint.x - width + 14, max(left, right)))
    let y = max(screen.minY + 8, min(anchorPoint.y - height - 6, screen.maxY - height - 8))
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  func textDidChange(_ notification: Notification) {
    editor.needsDisplay = true
    updateEditorHeight()
    validate()
  }

  private static func preferredEditorHeight(for editor: NSTextView) -> CGFloat {
    guard let container = editor.textContainer, let layout = editor.layoutManager else { return Metrics.compactEditorHeight }
    layout.ensureLayout(for: container)
    let contentHeight = layout.usedRect(for: container).height + editor.textContainerInset.height * 2
    let steppedHeight = ceil(contentHeight / Metrics.editorHeightStep) * Metrics.editorHeightStep
    return min(Metrics.maximumEditorHeight, max(Metrics.compactEditorHeight, steppedHeight))
  }

  private func updateEditorHeight() {
    let preferredHeight = Self.preferredEditorHeight(for: editor)
    guard abs(preferredHeight - editorHeight) > 0.5 else { return }
    editorHeight = preferredHeight
    editorHeightConstraint.constant = preferredHeight
    updateSheetHeight()
  }

  private var sheetHeight: CGFloat { editorHeight + Metrics.chromeHeight + (isShowingError ? Metrics.errorHeight : 0) }

  private func updateSheetHeight() {
    let size = window.contentRect(forFrameRect: window.frame).size
    guard abs(size.height - sheetHeight) > 0.5 else { return }
    window.setContentSize(NSSize(width: size.width, height: sheetHeight))
    positionNearAnchor()
  }

  private func validate() {
    saveButton.isEnabled = !editor.string.clipboardTrimmed.isEmpty
    saveButton.contentTintColor = saveButton.isEnabled ? ClipboardShelfStyle.brandAccent : .tertiaryLabelColor
    saveButton.needsDisplay = true
    statusLabel.isHidden = true
    statusLabel.stringValue = ""
    isShowingError = false
    updateSheetHeight()
  }

  @objc private func save() {
    guard saveButton.isEnabled else { return }
    if let error = onSave(editor.string) {
      isShowingError = true
      statusLabel.textColor = .systemRed
      statusLabel.stringValue = error
      statusLabel.isHidden = false
      updateSheetHeight()
      NSAccessibility.post(
        element: window, notification: .announcementRequested,
        userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    } else {
      cancel()
    }
  }

  @objc private func cancel() { dismiss() }

  func dismiss() {
    guard !isFinished else { return }
    isFinished = true
    window.detachFromShelf()
    onFinish()
  }
}
