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

  /// Prepare once before clearing the destination. Drag labels are separate
  /// from copy fallbacks so a media copy retains its original clipboard types.
  private enum Representation {
    case objects([NSPasteboardWriting], copyText: String?)
    case files([URL])
    case data(Data, NSPasteboard.PasteboardType, copyText: String?, dragText: String?)
    case text(String)
    case link(String, title: String?)

    var writers: [NSPasteboardWriting] {
      switch self {
      case .objects(let objects, _): return objects
      case .files(let urls): return urls.map { $0.standardizedFileURL as NSURL }
      case .text(let text): return [Self.item(text: text)]
      case .data(let data, let type, let copyText, let dragText):
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let text = dragText ?? copyText { item.setString(text, forType: .string) }
        return [item]
      case .link(let address, let title):
        let item = Self.item(text: address)
        item.setString(address, forType: .URL)
        if let title { item.setString(title, forType: Self.urlNameType) }
        return [item]
      }
    }

    func write(to board: NSPasteboard) -> Bool {
      switch self {
      case .objects(let objects, let text):
        let written = board.writeObjects(objects)
        if written, let text { board.setString(text, forType: .string) }
        return written
      case .files(let urls):
        let written = board.writeObjects(urls.map { $0 as NSURL })
        if written { board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
        return written
      case .data(let data, let type, let text, _):
        let written = board.setData(data, forType: type)
        if let text { board.setString(text, forType: .string) }
        return written
      case .text(let text): return board.setString(text, forType: .string)
      case .link(let address, let title):
        let written = board.setString(address, forType: .string)
        board.setString(address, forType: .URL)
        if let url = URL(string: address) { _ = board.writeObjects([url as NSURL]) }
        if let title { board.setString(title, forType: Self.urlNameType) }
        return written
      }
    }

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    private static func item(text: String?) -> NSPasteboardItem {
      let item = NSPasteboardItem()
      if let text { item.setString(text, forType: .string) }
      return item
    }
  }

  private func representation(for item: ClipboardItem) -> Representation? {
    switch item.kind {
    case .image:
      guard let path = item.imagePath, let image = cacheService.image(for: path) else { return nil }
      return .objects([image], copyText: nil)
    case .pdf, .audio, .video:
      guard let data = cacheService.data(for: item.payload) else { return nil }
      let type: NSPasteboard.PasteboardType =
        item.kind == .pdf ? .pdf : (item.kind == .audio ? .sound : VideoPayload.pasteboardType(forPath: item.payload))
      return .data(data, type, copyText: nil, dragText: dragLabel(for: item))
    case .color:
      guard let color = ColorPayload.color(from: item.payload) else { return nil }
      return .objects([color], copyText: ColorPayload.displayHex(from: item.payload))
    case .richText:
      if let data = cacheService.data(for: item.payload) {
        let text = richTextPlainString(from: data) ?? item.displayText.clipboardTrimmed
        return .data(data, .rtf, copyText: text.isEmpty ? nil : text, dragText: nil)
      }
      let text = richTextFallbackPlainString(for: item)
      return text.isEmpty ? nil : .text(text)
    case .file:
      let urls = FilePayload.urls(from: item.payload)
      guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
      return .files(urls)
    case .url:
      guard !item.payload.isEmpty else { return nil }
      return .link(item.payload, title: urlTitleForPasteboard(item.displayText, payload: item.payload))
    case .text, .code, .unknown: return item.payload.isEmpty ? nil : .text(item.payload)
    }
  }

  func pasteboardWriters(for item: ClipboardItem) -> [NSPasteboardWriting] { representation(for: item)?.writers ?? [] }

  @discardableResult func writeToPasteboard(_ item: ClipboardItem) -> Bool {
    guard let representation = representation(for: item) else { return false }
    return write { representation.write(to: $0) }
  }

  private func write(_ operation: (NSPasteboard) -> Bool) -> Bool {
    pasteboard.clearContents()
    let written = operation(pasteboard)
    if written { ClipboardSelfWriteTracker.mark(changeCount: pasteboard.changeCount, pasteboard: pasteboard) }
    return written
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

    return write { $0.writeObjects(writers) }
  }

  func plainText(for item: ClipboardItem) -> String? {
    switch item.kind {
    case .text, .code, .unknown, .url, .file: return nonEmptyPlainText(item.payload) ?? nonEmptyPlainText(item.displayText)
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
    return write { $0.setString(text, forType: .string) }
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

  private func dragLabel(for item: ClipboardItem) -> String {
    let display = item.displayText.clipboardTrimmed
    if !display.isEmpty { return display }
    return item.kind.displayName.capitalized
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
