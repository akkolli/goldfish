import AppKit
import CryptoKit
import XCTest

@testable import Goldfish

final class PasteActionServiceTests: ClipboardTestCase {

  func testTransferSoundsFollowSuccessfulCopyResultsIncludingFallbacks() throws {
    var cues: [ClipboardSound] = []
    let service = PasteActionService(
      pasteboard: pasteboard, cacheService: makeNoOpCacheService(), accessibilityPermissionProvider: { false },
      feedback: { cues.append($0) })
    let item = makeTextItem("A soft copy cue")
    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(service.copy([item, item]), .copied)
    XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
    XCTAssertEqual(service.copyPlainText("Plain text"), .copiedPlainText)
    XCTAssertEqual(service.paste(item, targetApp: nil), .copied)
    XCTAssertEqual(service.paste([item], targetApp: nil), .copied)
    XCTAssertEqual(service.pastePlainText(item, targetApp: nil), .copiedPlainText)
    XCTAssertEqual(service.pastePlainText("Text", targetApp: nil), .copiedPlainText)
    let target = try makeRunningTargetApp()
    XCTAssertEqual(service.paste(item, targetApp: target), .copiedNeedsPermission)
    XCTAssertEqual(service.pastePlainText(item, targetApp: target), .copiedPlainTextNeedsPermission)
    XCTAssertEqual(cues, Array(repeating: .copy, count: 10))
    _ = service.copy(makeTextItem(""))
    _ = service.copy([])
    _ = service.copyPlainText(" ")
    _ = service.paste(makeTextItem(""), targetApp: target)
    XCTAssertEqual(cues.count, 10, "Failed writes must be silent")
  }

  func testPasteSoundWaitsForDeliveryAndIsSilentIfTheTargetOrClipboardChanges() throws {
    let target = try makeRunningTargetApp()
    var foreground: pid_t? = target.processIdentifier
    var scheduled: (() -> Void)?
    var posts = 0
    var postSucceeds = true
    var cues: [ClipboardSound] = []
    let service = PasteActionService(
      pasteboard: pasteboard, cacheService: makeNoOpCacheService(), accessibilityPermissionProvider: { true },
      targetActivator: { _ in true }, keyboardPasteScheduler: { scheduled = $0 }, feedback: { cues.append($0) },
      frontmostPID: { foreground },
      keyboardPastePoster: {
        posts += 1
        return postSucceeds
      })
    let item = makeTextItem("Paste timing")
    XCTAssertEqual(service.paste(item, targetApp: target), .pasted)
    XCTAssertTrue(cues.isEmpty, "Scheduling and writing the pasteboard are not a completed paste")
    scheduled?()
    XCTAssertEqual(cues, [.paste])
    XCTAssertEqual(posts, 1)
    _ = service.pastePlainText(item, targetApp: target)
    scheduled?()
    XCTAssertEqual(cues, [.paste, .paste])
    _ = service.paste(item, targetApp: target)
    foreground = nil
    scheduled?()
    XCTAssertEqual(posts, 2)
    foreground = target.processIdentifier
    _ = service.paste(item, targetApp: target)
    pasteboard.clearContents()
    scheduled?()
    XCTAssertEqual(posts, 2)
    _ = service.paste(item, targetApp: target)
    postSucceeds = false
    scheduled?()
    XCTAssertEqual(cues, [.paste, .paste])
  }

  func testCopyMultipleItemsPreservesOriginalPasteboardRepresentations() throws {
    let service = makeService()
    let link = testItem(
      kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(),
      useCount: 0)
    let text = makeTextItem("Batch note")

    XCTAssertEqual(service.copy([link, text]), .copied)
    let pasteboardItems = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(pasteboardItems.count, 2)
    XCTAssertEqual(pasteboardItems[0].string(forType: .URL), "https://apple.com")
    XCTAssertEqual(pasteboardItems[0].string(forType: NSPasteboard.PasteboardType(rawValue: "public.url-name")), "Apple")
    XCTAssertEqual(pasteboardItems[1].string(forType: .string), "Batch note")
  }

  func testUnwritableSingleAndBatchCopiesPreserveTheClipboard() {
    let missing = testItem(
      kind: .file, displayText: "Missing file", payload: "/tmp/clipbored-missing-\(UUID())", payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
    let batchMissing = testItem(
      kind: .file, displayText: "Missing file",
      payload: FileManager.default.temporaryDirectory.appendingPathComponent("clipbored-missing-\(UUID())").path, payloadHash: "hash",
      createdAt: Date(), lastUsedAt: Date(), useCount: 0)
    let cases: [(items: [ClipboardItem], batch: Bool, error: String)] = [
      ([makeTextItem("Writable"), batchMissing], true, "Could not write items to clipboard."),
      ([missing], false, "Could not write item to clipboard."), ([makeTextItem("")], false, "Could not write item to clipboard."),
    ]
    for entry in cases {
      let service = makeService()
      pasteboard.clearContents()
      XCTAssertTrue(pasteboard.setString("keep me", forType: .string))
      XCTAssertEqual(entry.batch ? service.copy(entry.items) : service.copy(entry.items[0]), .failed(entry.error))
      XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }
  }

  func testCopyWritesColorToPasteboardWithHexFallback() throws {
    let service = makeService()
    let item = testItem(kind: .color, payload: "#0A84FF", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    let restored = try XCTUnwrap(NSColor(from: pasteboard))
    XCTAssertEqual(ColorPayload.hexString(from: restored), "#0A84FF")
    XCTAssertEqual(pasteboard.string(forType: .string), "#0A84FF")
    XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
    XCTAssertEqual(pasteboard.string(forType: .string), "#0A84FF")
  }

  func testAutomaticOriginalAndPlainTextPasteActivateTheTargetAndScheduleDelivery() throws {
    let target = try makeRunningTargetApp()
    for plainText in [false, true] {
      var activated: pid_t?
      var scheduled = false
      let service = makeService(
        accessibilityPermissionProvider: { true },
        targetActivator: {
          activated = $0.processIdentifier
          return true
        }, keyboardPasteScheduler: { _ in scheduled = true })
      let item =
        plainText
        ? testItem(
          kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(),
          useCount: 0) : makeTextItem("Paste into target")
      let result = plainText ? service.pastePlainText(item, targetApp: target) : service.paste(item, targetApp: target)
      XCTAssertEqual(result, plainText ? .pastedPlainText : .pasted)
      XCTAssertEqual(activated, target.processIdentifier)
      XCTAssertTrue(scheduled)
      XCTAssertEqual(pasteboard.string(forType: .string), item.payload)
      if plainText { XCTAssertNil(pasteboard.string(forType: .URL)) }
    }
  }

  func testAutomaticPasteDoesNotPostShortcutWhenTargetActivationFails() throws {
    var didAttemptActivation = false
    let targetApp = try makeRunningTargetApp()
    let service = makeService(
      accessibilityPermissionProvider: { true },
      targetActivator: { _ in
        didAttemptActivation = true
        return false
      }, keyboardPasteScheduler: { _ in XCTFail("Keyboard paste should not be scheduled when target activation fails") })

    XCTAssertEqual(service.paste(makeTextItem("Activation failed"), targetApp: targetApp), .copied)
    XCTAssertTrue(didAttemptActivation)
    XCTAssertEqual(pasteboard.string(forType: .string), "Activation failed")
  }

  func testCopyWritesURLType() {
    let service = makeService()
    let item = testItem(
      kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(),
      useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.string(forType: .string), "https://apple.com")
    XCTAssertEqual(pasteboard.string(forType: .URL), "https://apple.com")
    XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(rawValue: "public.url-name")), "Apple")
  }

  func testRichTextCopyPreservesFormattingAndPlainTextCopyStripsIt() throws {
    for plainText in [false, true] {
      let cache = ClipboardCacheService(baseURL: try makeTempDirectory(), encryptionService: testEncryption(byte: 7))
      let attributed = NSAttributedString(string: "Styled clipboard text", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
      let rtf = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
      let path = try XCTUnwrap(cache.cacheRichText(rtf, id: UUID()))
      let service = PasteActionService(pasteboard: pasteboard, cacheService: cache)
      let item = testItem(
        kind: .richText, displayText: attributed.string, payload: path, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(),
        useCount: 0)
      XCTAssertEqual(plainText ? service.copyPlainText(item) : service.copy(item), plainText ? .copiedPlainText : .copied)
      XCTAssertEqual(pasteboard.string(forType: .string), attributed.string)
      if plainText { XCTAssertNil(pasteboard.data(forType: .rtf)) } else { XCTAssertEqual(pasteboard.data(forType: .rtf), rtf) }
    }
  }

  func testCopyWritesMultipleFileReferences() throws {
    let firstURL = try makeTempFile(contents: "first file")
    let secondURL = try makeTempFile(contents: "second file")
    let payload = FilePayload.payload(from: [firstURL, secondURL])
    let service = makeService()
    let item = testItem(
      kind: .file, displayText: "2 files", payload: payload, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    XCTAssertEqual(objects?.map(\.standardizedFileURL), [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    XCTAssertEqual(pasteboard.string(forType: .string), payload)
  }

  func testCopyRestoresExternalPDFAndEncryptedMediaRepresentations() throws {
    let cases: [(kind: ClipboardItemKind, title: String, data: Data, type: NSPasteboard.PasteboardType, encrypted: Bool)] = [
      (.pdf, "PDF", Data("%PDF-1.4\nclipbored\n%%EOF".utf8), .pdf, false), (.audio, "Audio", Data([1, 3, 5, 7, 9]), .sound, true),
      (.video, "Video", Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50]), VideoPayload.pasteboardTypes[0], true),
      (.pdf, "PDF", Data("%PDF-1.4\nencrypted clipbored\n%%EOF".utf8), .pdf, true),
    ]
    for entry in cases {
      let cache = ClipboardCacheService(baseURL: try makeTempDirectory(), encryptionService: testEncryption(byte: 7))
      let path: String
      if !entry.encrypted {
        path = try makeTempFile(contents: entry.data).path
      } else {
        switch entry.kind {
        case .pdf: path = try XCTUnwrap(cache.cachePDF(entry.data, id: UUID()))
        case .audio: path = try XCTUnwrap(cache.cacheAudio(entry.data, id: UUID()))
        case .video: path = try XCTUnwrap(cache.cacheVideo(entry.data, id: UUID(), fileExtension: "mp4"))
        default: return XCTFail("Missing media fixture")
        }
      }
      let service = PasteActionService(pasteboard: pasteboard, cacheService: cache)
      let item = testItem(
        kind: entry.kind, displayText: entry.title, payload: path, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)
      if entry.encrypted { XCTAssertTrue(ClipboardEncryptionService.isProtected(try Data(contentsOf: URL(fileURLWithPath: path)))) }
      XCTAssertEqual(service.copy(item), .copied)
      XCTAssertEqual(pasteboard.data(forType: entry.type), entry.data)
      if entry.kind == .video {
        XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
        XCTAssertEqual(pasteboard.string(forType: .string), "Video")
      }
    }
  }

  private func makeService(
    accessibilityPermissionProvider: @escaping () -> Bool = { false },
    targetActivator: @escaping (NSRunningApplication) -> Bool = { _ in false },
    keyboardPasteScheduler: @escaping (@escaping () -> Void) -> Void = { _ in }
  ) -> PasteActionService {
    PasteActionService(
      pasteboard: pasteboard, cacheService: makeNoOpCacheService(), accessibilityPermissionProvider: accessibilityPermissionProvider,
      targetActivator: targetActivator, keyboardPasteScheduler: keyboardPasteScheduler)
  }

  private func makeNoOpCacheService() -> ClipboardCacheService {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboredtests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      tempURLs.append(directory)
      return ClipboardCacheService(baseURL: directory, encryptionService: testEncryption())
    } catch {
      XCTFail("Could not create no-op cache directory: \(error)")
      return ClipboardCacheService(baseURL: FileManager.default.temporaryDirectory, encryptionService: testEncryption())
    }
  }

  private func makeTempFile(contents: String) throws -> URL { try makeTempFile(contents: Data(contents.utf8)) }

  private func makeTextItem(_ value: String) -> ClipboardItem {
    testItem(payload: value, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)
  }

  private func makeRunningTargetApp() throws -> NSRunningApplication {
    try XCTUnwrap(NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.processIdentifier > 0 })
  }

  private func makeTempFile(contents: Data) throws -> URL {
    let directory = try makeTempDirectory()
    let url = directory.appendingPathComponent("payload")
    try contents.write(to: url)
    return url
  }

}
