import AppKit
import QuickLookUI

/// Previews belong to the shelf. They borrow keyboard focus without changing
/// the application that will receive a paste, and close with their owner.
class ClipboardAuxiliaryWindowController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onResignKey: (() -> Void)?
  private weak var shelfWindow: NSWindow?

  override init(window: NSWindow?) {
    super.init(window: window)
    window?.delegate = self
    window?.isReleasedWhenClosed = false
    window?.collectionBehavior = ClipboardPanelController.panelCollectionBehavior
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func present(relativeTo parent: NSWindow?) {
    guard let window else { return }
    if let previous = shelfWindow, previous !== parent { previous.removeChildWindow(window) }
    shelfWindow = parent
    if let parent {
      window.setFrame(LinkPreviewWindowController.previewFrame(relativeTo: parent), display: false)
      window.attachToShelf(parent, levelOffset: 0, behavior: ClipboardPanelController.panelCollectionBehavior)
    }
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    if let window { shelfWindow?.removeChildWindow(window) }
    shelfWindow = nil
    onClose?()
  }

  func windowDidResignKey(_ notification: Notification) { onResignKey?() }
}

final class ClipboardPreviewPanel: NSPanel {
  var closesWithSpace = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) { performClose(sender) }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if (event.keyCode == 53 && modifiers.isEmpty) || (event.keyCode == 13 && modifiers == .command)
      || (closesWithSpace && event.keyCode == 49 && modifiers.isEmpty && !((firstResponder as? NSTextView)?.isEditable ?? false))
    {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

final class ClipboardPreviewWindowController: ClipboardAuxiliaryWindowController {
  private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) {
      previewItemURL = url
      previewItemTitle = title
    }
  }

  init(url: URL, title: String) {
    let panel = ClipboardPreviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.title = title
    panel.minSize = NSSize(width: 440, height: 320)
    panel.hidesOnDeactivate = false
    panel.closesWithSpace = true
    panel.level = .floating
    panel.isFloatingPanel = true
    super.init(window: panel)
    if let preview = QLPreviewView(frame: panel.contentView?.bounds ?? .zero, style: .normal) {
      preview.autoresizingMask = [.width, .height]
      preview.shouldCloseWithWindow = true
      preview.autostarts = false
      preview.previewItem = PreviewItem(url: url, title: title)
      panel.contentView = preview
    }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
