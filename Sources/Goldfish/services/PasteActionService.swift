import AppKit
import Foundation

final class PasteActionService {
  private let pasteboard: NSPasteboard
  private let cacheService: ClipboardCacheService
  private let accessibilityPermissionProvider: () -> Bool
  private let targetActivator: (NSRunningApplication) -> Bool
  private let keyboardPasteScheduler: (@escaping () -> Void) -> Void
  private let feedback: (ClipboardSound) -> Void
  private let frontmostPID: () -> pid_t?
  private let keyboardPastePoster: () -> Bool

  init(
    pasteboard: NSPasteboard = .general, cacheService: ClipboardCacheService = ClipboardCacheService(),
    accessibilityPermissionProvider: @escaping () -> Bool = { AccessibilityPermissionService.isTrusted },
    targetActivator: @escaping (NSRunningApplication) -> Bool = PasteActionService.activateForAutomaticPaste,
    keyboardPasteScheduler: @escaping (@escaping () -> Void) -> Void = { action in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { action() }
    }, feedback: @escaping (ClipboardSound) -> Void = { _ in },
    frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
    keyboardPastePoster: @escaping () -> Bool = PasteActionService.pasteViaKeyboard
  ) {
    self.pasteboard = pasteboard
    self.cacheService = cacheService
    self.accessibilityPermissionProvider = accessibilityPermissionProvider
    self.targetActivator = targetActivator
    self.keyboardPasteScheduler = keyboardPasteScheduler
    self.feedback = feedback
    self.frontmostPID = frontmostPID
    self.keyboardPastePoster = keyboardPastePoster
  }

  enum PasteActionResult: Equatable {
    case pasted
    case pastedPlainText
    case copied
    case copiedPlainText
    case copiedNeedsPermission
    case copiedPlainTextNeedsPermission
    case failed(String)

    var message: String {
      switch self {
      case .pasted: return "Pasted"
      case .pastedPlainText: return "Pasted Plain Text"
      case .copied: return "Copied"
      case .copiedPlainText: return "Copied Plain Text"
      case .copiedNeedsPermission: return "Copied. Grant Accessibility access to paste automatically."
      case .copiedPlainTextNeedsPermission: return "Copied Plain Text. Grant Accessibility access to paste automatically."
      case .failed(let message): return message
      }
    }
  }

  func paste(_ item: ClipboardItem, targetApp: NSRunningApplication?) -> PasteActionResult {
    guard writeToPasteboard(item) else { return .failed("Could not write item to clipboard.") }

    return reportCopyFeedback(completePaste(targetApp: targetApp))
  }

  func paste(_ items: [ClipboardItem], targetApp: NSRunningApplication?) -> PasteActionResult {
    guard writeToPasteboard(items) else { return .failed("Could not write items to clipboard.") }

    return reportCopyFeedback(completePaste(targetApp: targetApp))
  }

  private func completePaste(targetApp: NSRunningApplication?, asPlainText: Bool = false) -> PasteActionResult {
    guard let targetApp, !targetApp.isTerminated else { return asPlainText ? .copiedPlainText : .copied }

    guard accessibilityPermissionProvider() else { return asPlainText ? .copiedPlainTextNeedsPermission : .copiedNeedsPermission }

    guard targetActivator(targetApp) else { return asPlainText ? .copiedPlainText : .copied }

    schedulePaste(into: targetApp)
    return asPlainText ? .pastedPlainText : .pasted
  }

  func pastePlainText(_ item: ClipboardItem, targetApp: NSRunningApplication?) -> PasteActionResult {
    guard let text = plainText(for: item), writePlainTextToPasteboard(text) else {
      return .failed("Could not write plain text to clipboard.")
    }

    return reportCopyFeedback(completePaste(targetApp: targetApp, asPlainText: true))
  }

  func pastePlainText(_ value: String, targetApp: NSRunningApplication?) -> PasteActionResult {
    guard writePlainTextToPasteboard(value) else { return .failed("Could not write plain text to clipboard.") }

    return reportCopyFeedback(completePaste(targetApp: targetApp, asPlainText: true))
  }

  @discardableResult func copy(_ item: ClipboardItem) -> PasteActionResult {
    reportCopyFeedback(writeToPasteboard(item) ? .copied : .failed("Could not write item to clipboard."))
  }

  @discardableResult func copy(_ items: [ClipboardItem]) -> PasteActionResult {
    reportCopyFeedback(writeToPasteboard(items) ? .copied : .failed("Could not write items to clipboard."))
  }

  @discardableResult func copyPlainText(_ item: ClipboardItem) -> PasteActionResult {
    reportCopyFeedback(writePlainTextToPasteboard(item) ? .copiedPlainText : .failed("Could not write plain text to clipboard."))
  }

  @discardableResult func copyPlainText(_ value: String) -> PasteActionResult {
    reportCopyFeedback(writePlainTextToPasteboard(value) ? .copiedPlainText : .failed("Could not write plain text to clipboard."))
  }

  private func reportCopyFeedback(_ result: PasteActionResult) -> PasteActionResult {
    switch result {
    case .copied, .copiedPlainText, .copiedNeedsPermission, .copiedPlainTextNeedsPermission: feedback(.copy)
    case .pasted, .pastedPlainText, .failed: break
    }
    return result
  }

  func pasteboardWriters(for item: ClipboardItem) -> [NSPasteboardWriting] {
    switch item.kind {
    case .image:
      guard let imagePath = item.imagePath, let image = cacheService.image(for: imagePath) else { return [] }
      return [image]

    case .pdf, .audio, .video:
      guard let data = cacheService.data(for: item.payload) else { return [] }
      let type: NSPasteboard.PasteboardType =
        item.kind == .pdf ? .pdf : (item.kind == .audio ? .sound : VideoPayload.pasteboardType(forPath: item.payload))
      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setData(data, forType: type)
      pasteboardItem.setString(dragLabel(for: item), forType: .string)
      return [pasteboardItem]

    case .color:
      guard let color = ColorPayload.color(from: item.payload) else { return [] }
      return [color]

    case .richText:
      if let data = cacheService.data(for: item.payload) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .rtf)
        let text = richTextPlainString(from: data) ?? item.displayText.clipboardTrimmed
        if !text.isEmpty { pasteboardItem.setString(text, forType: .string) }
        return [pasteboardItem]
      }

      let fallbackText = richTextFallbackPlainString(for: item)
      return fallbackText.isEmpty ? [] : [stringPasteboardItem(fallbackText)]

    case .file:
      let urls = FilePayload.urls(from: item.payload)
      guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return [] }
      return urls.map { $0.standardizedFileURL as NSURL }

    case .url:
      guard !item.payload.isEmpty else { return [] }
      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setString(item.payload, forType: .string)
      pasteboardItem.setString(item.payload, forType: .URL)
      if let title = urlTitleForPasteboard(item.displayText, payload: item.payload) {
        pasteboardItem.setString(title, forType: NSPasteboard.PasteboardType(rawValue: "public.url-name"))
      }
      return [pasteboardItem]

    case .text, .code, .unknown:
      guard !item.payload.isEmpty else { return [] }
      return [stringPasteboardItem(item.payload)]
    }
  }

  @discardableResult func writeToPasteboard(_ item: ClipboardItem) -> Bool {
    let board = pasteboard
    let didWrite: Bool
    switch item.kind {
    case .image:
      guard let imagePath = item.imagePath, let image = cacheService.image(for: imagePath) else { return false }
      board.clearContents()
      didWrite = board.writeObjects([image])
    case .pdf:
      guard let data = cacheService.data(for: item.payload) else { return false }
      board.clearContents()
      didWrite = board.setData(data, forType: .pdf)
    case .audio:
      guard let data = cacheService.data(for: item.payload) else { return false }
      board.clearContents()
      didWrite = board.setData(data, forType: .sound)
    case .video:
      guard let data = cacheService.data(for: item.payload) else { return false }
      board.clearContents()
      didWrite = board.setData(data, forType: VideoPayload.pasteboardType(forPath: item.payload))
    case .color:
      guard let color = ColorPayload.color(from: item.payload) else { return false }
      board.clearContents()
      didWrite = board.writeObjects([color])
      if didWrite { board.setString(ColorPayload.displayHex(from: item.payload), forType: .string) }
    case .richText:
      if let data = cacheService.data(for: item.payload) {
        board.clearContents()
        let text = richTextPlainString(from: data) ?? item.displayText.clipboardTrimmed
        let wroteRTF = board.setData(data, forType: .rtf)
        if !text.isEmpty { _ = board.setString(text, forType: .string) }
        didWrite = wroteRTF
      } else {
        let fallbackText = richTextFallbackPlainString(for: item)
        guard !fallbackText.isEmpty else { return false }
        board.clearContents()
        didWrite = board.setString(fallbackText, forType: .string)
      }
    case .file:
      let urls = FilePayload.urls(from: item.payload)
      guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return false }
      board.clearContents()
      didWrite = board.writeObjects(urls.map { $0 as NSURL })
      if didWrite { board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
    case .url:
      guard !item.payload.isEmpty else { return false }
      board.clearContents()
      didWrite = writeURL(item.payload, title: item.displayText, to: board)
    case .text, .code, .unknown:
      guard !item.payload.isEmpty else { return false }
      board.clearContents()
      didWrite = board.setString(item.payload, forType: .string)
    }

    if didWrite { ClipboardSelfWriteTracker.mark(changeCount: board.changeCount, pasteboard: board) }
    return didWrite
  }

  @discardableResult func writeToPasteboard(_ items: [ClipboardItem]) -> Bool {
    guard !items.isEmpty else { return false }
    var writers: [NSPasteboardWriting] = []
    for item in items {
      let itemWriters = pasteboardWriters(for: item)
      guard !itemWriters.isEmpty else { return false }
      writers.append(contentsOf: itemWriters)
    }
    guard !writers.isEmpty else { return false }

    let board = pasteboard
    board.clearContents()
    let didWrite = board.writeObjects(writers)
    if didWrite { ClipboardSelfWriteTracker.mark(changeCount: board.changeCount, pasteboard: board) }
    return didWrite
  }

  func plainText(for item: ClipboardItem) -> String? {
    switch item.kind {
    case .text, .code, .unknown: return nonEmptyPlainText(item.payload) ?? nonEmptyPlainText(item.displayText)
    case .url, .file: return nonEmptyPlainText(item.payload) ?? nonEmptyPlainText(item.displayText)
    case .richText:
      if let data = cacheService.data(for: item.payload), let text = richTextPlainString(from: data) { return text }
      return nonEmptyPlainText(richTextFallbackPlainString(for: item))
    case .image: return nonEmptyPlainText(item.ocrText) ?? nonEmptyPlainText(item.displayText)
    case .pdf, .audio, .video: return nonEmptyPlainText(item.displayText)
    case .color: return nonEmptyPlainText(ColorPayload.displayHex(from: item.payload)) ?? nonEmptyPlainText(item.displayText)
    }
  }

  @discardableResult func writePlainTextToPasteboard(_ item: ClipboardItem) -> Bool {
    guard let text = plainText(for: item) else { return false }
    return writePlainTextToPasteboard(text)
  }

  @discardableResult private func writePlainTextToPasteboard(_ text: String) -> Bool {
    guard !text.clipboardTrimmed.isEmpty else { return false }
    let board = pasteboard
    board.clearContents()
    let didWrite = board.setString(text, forType: .string)
    if didWrite { ClipboardSelfWriteTracker.mark(changeCount: board.changeCount, pasteboard: board) }
    return didWrite
  }

  private func schedulePaste(into targetApp: NSRunningApplication) {
    let changeCount = pasteboard.changeCount
    keyboardPasteScheduler { [weak self] in
      guard let self, !targetApp.isTerminated,
        Self.shouldDeliverPaste(
          targetPID: targetApp.processIdentifier, frontmostPID: self.frontmostPID(), expectedChangeCount: changeCount,
          actualChangeCount: self.pasteboard.changeCount)
      else { return }
      if self.keyboardPastePoster() { self.feedback(.paste) }
    }
  }

  static func shouldDeliverPaste(targetPID: pid_t, frontmostPID: pid_t?, expectedChangeCount: Int, actualChangeCount: Int) -> Bool {
    targetPID == frontmostPID && expectedChangeCount == actualChangeCount
  }

  private func stringPasteboardItem(_ value: String) -> NSPasteboardItem {
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(value, forType: .string)
    return pasteboardItem
  }

  private func dragLabel(for item: ClipboardItem) -> String {
    let display = item.displayText.clipboardTrimmed
    if !display.isEmpty { return display }
    return item.kind.displayName.capitalized
  }

  private func writeURL(_ payload: String, title: String?, to board: NSPasteboard) -> Bool {
    guard !payload.isEmpty else { return false }
    let wroteString = board.setString(payload, forType: .string)
    board.setString(payload, forType: .URL)
    if let url = URL(string: payload) { _ = board.writeObjects([url as NSURL]) }
    if let title = urlTitleForPasteboard(title, payload: payload) {
      board.setString(title, forType: NSPasteboard.PasteboardType(rawValue: "public.url-name"))
    }
    return wroteString
  }

  private func urlTitleForPasteboard(_ title: String?, payload: String) -> String? {
    guard let title else { return nil }
    let normalized = title.split { $0.isWhitespace }.joined(separator: " ").clipboardTrimmed
    guard !normalized.isEmpty, normalized != payload else { return nil }
    guard !normalized.contains("://") else { return nil }
    return normalized
  }

  private func nonEmptyPlainText(_ value: String?) -> String? {
    guard let value, !value.clipboardTrimmed.isEmpty else { return nil }
    return value
  }

  private func richTextPlainString(from data: Data) -> String? {
    guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
    let text = attributed.string.clipboardTrimmed
    return text.isEmpty ? nil : text
  }

  private func richTextFallbackPlainString(for item: ClipboardItem) -> String {
    let payload = item.payload.clipboardTrimmed
    if looksLikeRichTextCachePath(payload) { return item.displayText.clipboardTrimmed }
    if !payload.isEmpty { return payload }
    return item.displayText.clipboardTrimmed
  }

  private func looksLikeRichTextCachePath(_ payload: String) -> Bool {
    let url = URL(fileURLWithPath: payload)
    return payload.contains("/") && url.pathExtension.lowercased() == "rtf"
  }

  private static func activateForAutomaticPaste(_ targetApp: NSRunningApplication) -> Bool {
    if #available(macOS 14, *) { return targetApp.activate() } else { return targetApp.activate(options: [.activateIgnoringOtherApps]) }
  }

  static func pasteViaKeyboard() -> Bool {
    let keyCode: UInt16 = 9
    guard let srcDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
      let srcUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    else { return false }

    srcDown.flags = .maskCommand
    srcDown.post(tap: .cghidEventTap)
    srcUp.flags = .maskCommand
    srcUp.post(tap: .cghidEventTap)
    return true
  }
}
