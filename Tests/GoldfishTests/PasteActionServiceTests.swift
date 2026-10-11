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
      kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
    let text = makeTextItem("Batch note")

    XCTAssertEqual(service.copy([link, text]), .copied)
    let pasteboardItems = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(pasteboardItems.count, 2)
    XCTAssertEqual(pasteboardItems[0].string(forType: .URL), "https://apple.com")
    XCTAssertEqual(pasteboardItems[0].string(forType: NSPasteboard.PasteboardType(rawValue: "public.url-name")), "Apple")
    XCTAssertEqual(pasteboardItems[1].string(forType: .string), "Batch note")
  }

  func testCopyMultipleItemsDoesNotClearPasteboardWhenAnyItemIsUnwritable() {
    let service = makeService()
    let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent("clipbored-missing-\(UUID().uuidString)").path
    let missingFile = testItem(
      kind: .file, displayText: "Missing file", payload: missingPath, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
    pasteboard.clearContents()
    pasteboard.setString("keep me", forType: .string)

    XCTAssertEqual(service.copy([makeTextItem("Writable"), missingFile]), .failed("Could not write items to clipboard."))
    XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
  }

  func testCopyWritesColorToPasteboardWithHexFallback() throws {
    let service = makeService()
    let item = testItem(
      kind: .color, payload: "#0A84FF", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(),
      useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    let restored = try XCTUnwrap(NSColor(from: pasteboard))
    XCTAssertEqual(ColorPayload.hexString(from: restored), "#0A84FF")
    XCTAssertEqual(pasteboard.string(forType: .string), "#0A84FF")
    XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
    XCTAssertEqual(pasteboard.string(forType: .string), "#0A84FF")
  }

  func testAutomaticPasteActivatesTargetAndSchedulesKeyboardPasteWhenPermissionGranted() throws {
    var activatedProcessID: pid_t?
    let targetApp = try makeRunningTargetApp()
    var didScheduleKeyboardPaste = false
    let service = makeService(
      accessibilityPermissionProvider: { true },
      targetActivator: { app in
        activatedProcessID = app.processIdentifier
        return true
      }, keyboardPasteScheduler: { _ in didScheduleKeyboardPaste = true })

    XCTAssertEqual(service.paste(makeTextItem("Paste into target"), targetApp: targetApp), .pasted)
    XCTAssertEqual(activatedProcessID, targetApp.processIdentifier)
    XCTAssertTrue(didScheduleKeyboardPaste)
    XCTAssertEqual(pasteboard.string(forType: .string), "Paste into target")
  }

  func testAutomaticPlainTextPasteActivatesTargetAndSchedulesKeyboardPasteWhenPermissionGranted() throws {
    var activatedProcessID: pid_t?
    let targetApp = try makeRunningTargetApp()
    var didScheduleKeyboardPaste = false
    let service = makeService(
      accessibilityPermissionProvider: { true },
      targetActivator: { app in
        activatedProcessID = app.processIdentifier
        return true
      }, keyboardPasteScheduler: { _ in didScheduleKeyboardPaste = true })
    let item = testItem(
      kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.pastePlainText(item, targetApp: targetApp), .pastedPlainText)
    XCTAssertEqual(activatedProcessID, targetApp.processIdentifier)
    XCTAssertTrue(didScheduleKeyboardPaste)
    XCTAssertEqual(pasteboard.string(forType: .string), "https://apple.com")
    XCTAssertNil(pasteboard.string(forType: .URL))
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

  func testCopyMissingFileDoesNotClearExistingPasteboard() {
    let service = makeService()
    let board = pasteboard
    board.clearContents()
    XCTAssertTrue(board.setString("keep me", forType: .string))

    let item = testItem(
      kind: .file, displayText: "Missing file", payload: "/tmp/clipbored-missing-\(UUID().uuidString)",
      payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .failed("Could not write item to clipboard."))
    XCTAssertEqual(board.string(forType: .string), "keep me")
  }

  func testCopyEmptyTextDoesNotClearExistingPasteboard() {
    let service = makeService()
    let board = pasteboard
    board.clearContents()
    XCTAssertTrue(board.setString("keep me", forType: .string))

    let item = testItem(payload: "", payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .failed("Could not write item to clipboard."))
    XCTAssertEqual(board.string(forType: .string), "keep me")
  }

  func testCopyWritesURLType() {
    let service = makeService()
    let item = testItem(
      kind: .url, displayText: "Apple", payload: "https://apple.com", payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.string(forType: .string), "https://apple.com")
    XCTAssertEqual(pasteboard.string(forType: .URL), "https://apple.com")
    XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(rawValue: "public.url-name")), "Apple")
  }

  func testCopyWritesRichTextRTFAndPlainStringFallback() throws {
    let directory = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: directory, encryptionService: testEncryption(byte: 7))
    let attributed = NSAttributedString(string: "Styled clipboard text", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
    let rtfData = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
    let path = try XCTUnwrap(cacheService.cacheRichText(rtfData, id: UUID()))
    let service = PasteActionService(pasteboard: pasteboard, cacheService: cacheService)
    let item = testItem(
      kind: .richText, displayText: attributed.string, payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.data(forType: .rtf), rtfData)
    XCTAssertEqual(pasteboard.string(forType: .string), attributed.string)
  }

  func testCopyPlainTextStripsRichTextFormatting() throws {
    let directory = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: directory, encryptionService: testEncryption(byte: 7))
    let attributed = NSAttributedString(string: "Styled clipboard text", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
    let rtfData = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
    let path = try XCTUnwrap(cacheService.cacheRichText(rtfData, id: UUID()))
    let service = PasteActionService(pasteboard: pasteboard, cacheService: cacheService)
    let item = testItem(
      kind: .richText, displayText: attributed.string, payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
    XCTAssertEqual(pasteboard.string(forType: .string), attributed.string)
    XCTAssertNil(pasteboard.data(forType: .rtf))
  }

  func testCopyWritesMultipleFileReferences() throws {
    let firstURL = try makeTempFile(contents: "first file")
    let secondURL = try makeTempFile(contents: "second file")
    let payload = FilePayload.payload(from: [firstURL, secondURL])
    let service = makeService()
    let item = testItem(
      kind: .file, displayText: "2 files", payload: payload, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    XCTAssertEqual(objects?.map(\.standardizedFileURL), [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    XCTAssertEqual(pasteboard.string(forType: .string), payload)
  }

  func testCopyWritesPDFData() throws {
    let pdfData = Data("%PDF-1.4\nclipbored\n%%EOF".utf8)
    let fileURL = try makeTempFile(contents: pdfData)
    let service = makeService()
    let item = testItem(
      kind: .pdf, displayText: "PDF", payload: fileURL.path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.data(forType: .pdf), pdfData)
  }

  func testCopyWritesAudioData() throws {
    let directory = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: directory, encryptionService: testEncryption(byte: 7))
    let audioData = Data([1, 3, 5, 7, 9])
    let path = try XCTUnwrap(cacheService.cacheAudio(audioData, id: UUID()))
    let service = PasteActionService(pasteboard: pasteboard, cacheService: cacheService)
    let item = testItem(
      kind: .audio, displayText: "Audio", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.data(forType: .sound), audioData)
  }

  func testCopyWritesVideoData() throws {
    let directory = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: directory, encryptionService: testEncryption(byte: 7))
    let videoData = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])
    let path = try XCTUnwrap(cacheService.cacheVideo(videoData, id: UUID(), fileExtension: "mp4"))
    let service = PasteActionService(pasteboard: pasteboard, cacheService: cacheService)
    let item = testItem(
      kind: .video, displayText: "Video", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.data(forType: VideoPayload.pasteboardTypes[0]), videoData)
    XCTAssertEqual(service.copyPlainText(item), .copiedPlainText)
    XCTAssertEqual(pasteboard.string(forType: .string), "Video")
  }

  func testCopyWritesEncryptedPDFData() throws {
    let directory = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: directory, encryptionService: testEncryption(byte: 7))
    let pdfData = Data("%PDF-1.4\nencrypted clipbored\n%%EOF".utf8)
    let path = try XCTUnwrap(cacheService.cachePDF(pdfData, id: UUID()))
    let service = PasteActionService(pasteboard: pasteboard, cacheService: cacheService)
    let item = testItem(
      kind: .pdf, displayText: "PDF", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)

    XCTAssertTrue(ClipboardEncryptionService.isProtected(try Data(contentsOf: URL(fileURLWithPath: path))))
    XCTAssertEqual(service.copy(item), .copied)
    XCTAssertEqual(pasteboard.data(forType: .pdf), pdfData)
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
