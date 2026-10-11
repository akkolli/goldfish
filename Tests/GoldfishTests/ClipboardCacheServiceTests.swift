import AppKit
import CryptoKit
import XCTest
@testable import Goldfish

final class ClipboardCacheServiceTests: IsolatedTestCase {

  override func tearDown() {
    try? FileManager.default.removeItem(at: temporaryPreviewRoot())
    super.tearDown()
  }

  func testPurgeRemovesOnlyThumbnailsOverByteLimit() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let first = try XCTUnwrap(cacheService.cacheImage(makeImage(color: .systemRed), id: UUID()))
    let second = try XCTUnwrap(cacheService.cacheImage(makeImage(color: .systemBlue), id: UUID()))

    XCTAssertTrue(FileManager.default.fileExists(atPath: first.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.thumb))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.thumb))

    cacheService.purgeIfNeeded(maxBytes: 1)
    cacheService.flushForTesting()

    XCTAssertEqual(try imageCacheFileURLs(in: baseURL).count, 2)
    XCTAssertTrue(try thumbnailCacheFileURLs(in: baseURL).isEmpty)
    XCTAssertNotNil(cacheService.image(for: first.full))
    XCTAssertNotNil(cacheService.image(for: second.full))
  }

  func testClearCacheRemovesOnlyImageCacheFiles() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let image = try XCTUnwrap(cacheService.cacheImage(makeImage(color: .systemGreen), id: UUID()))
    let pdfPath = try XCTUnwrap(cacheService.cachePDF(Data("%PDF-1.4\n%%EOF".utf8), id: UUID()))
    let pdfItem = pdfItem(path: pdfPath)
    let previewURL = try XCTUnwrap(cacheService.temporaryReadableURL(for: pdfItem))

    XCTAssertTrue(FileManager.default.fileExists(atPath: image.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.thumb))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdfPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))

    cacheService.clearCache()
    cacheService.flushForTesting()

    XCTAssertEqual(try imageCacheFileURLs(in: baseURL).count, 1)
    XCTAssertTrue(try thumbnailCacheFileURLs(in: baseURL).isEmpty)
    XCTAssertNotNil(cacheService.image(for: image.full))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdfPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
  }

  func testClearCacheRemovesLegacyThumbnailWithoutDeletingLegacyFullImage() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let imageDirectory = baseURL.appendingPathComponent("images", isDirectory: true)
    let fullURL = imageDirectory.appendingPathComponent("legacy.png")
    let thumbURL = imageDirectory.appendingPathComponent("thumb-legacy.png")
    let imageData = try XCTUnwrap(makeImage(color: .systemBrown).pngData())
    try imageData.write(to: fullURL)
    try imageData.write(to: thumbURL)

    cacheService.clearCache()
    cacheService.flushForTesting()

    XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path))
  }

  func testImageCacheFilesAreEncryptedAndLoadable() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let image = makeImage(color: .systemPurple)

    let paths = try XCTUnwrap(cacheService.cacheImage(image, id: UUID()))
    let rawFull = try Data(contentsOf: URL(fileURLWithPath: paths.full))
    let rawThumb = try Data(contentsOf: URL(fileURLWithPath: paths.thumb))

    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawFull))
    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawThumb))
    XCTAssertNil(NSImage(data: rawFull))
    XCTAssertNotNil(cacheService.image(for: paths.full))
    XCTAssertNotNil(cacheService.image(for: paths.thumb))
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: paths.full)), 0o600)
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: paths.thumb)), 0o600)
  }

  func testPreviewThumbnailUsesExistingFilePreview() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let imageURL = baseURL.appendingPathComponent("Copied Image.png")
    let imageData = try XCTUnwrap(makeImage(color: .systemOrange).pngData())
    try imageData.write(to: imageURL)

    let item = fileItem(path: imageURL.path)

    XCTAssertNotNil(cacheService.previewThumbnail(for: item))
  }

  func testPreviewThumbnailUsesManagedPDFPreviewFallback() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let pdfData = try makePDFData()
    let path = try XCTUnwrap(cacheService.cachePDF(pdfData, id: UUID()))

    XCTAssertNotNil(cacheService.previewThumbnail(for: pdfItem(path: path)))
  }

  func testPreviewThumbnailUsesDecryptedVideoTemporaryCopyAndCachesResult() throws {
    let baseURL = try makeTempDirectory()
    let videoData = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])
    var providerURLs: [URL] = []
    let cacheService = ClipboardCacheService(
      baseURL: baseURL,
      encryptionService: testEncryption(byte: 7),
      videoThumbnailProvider: { url in
        providerURLs.append(url)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(try? Data(contentsOf: url), videoData)
        return self.makeImage(color: .systemIndigo)
      }
    )
    let path = try XCTUnwrap(cacheService.cacheVideo(videoData, id: UUID(), fileExtension: "mp4"))
    let item = videoItem(path: path)

    let thumbnail = cacheService.previewThumbnail(for: item)
    let cachedThumbnail = cacheService.previewThumbnail(for: item)

    XCTAssertNotNil(thumbnail)
    XCTAssertNotNil(cachedThumbnail)
    XCTAssertEqual(providerURLs.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(providerURLs.first).path))
  }

  func testPDFCacheFilesAreEncryptedAndReadable() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let pdfData = Data("%PDF-1.4\nclipbored\n%%EOF".utf8)

    let path = try XCTUnwrap(cacheService.cachePDF(pdfData, id: UUID()))
    let rawPDF = try Data(contentsOf: URL(fileURLWithPath: path))

    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawPDF))
    XCTAssertNotEqual(rawPDF, pdfData)
    XCTAssertEqual(cacheService.data(for: path), pdfData)
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: path)), 0o600)
  }

  func testAudioCacheFilesAreEncryptedAndReadable() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let audioData = Data([0, 1, 2, 3, 5, 8, 13])

    let path = try XCTUnwrap(cacheService.cacheAudio(audioData, id: UUID()))
    let rawAudio = try Data(contentsOf: URL(fileURLWithPath: path))

    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawAudio))
    XCTAssertNotEqual(rawAudio, audioData)
    XCTAssertEqual(cacheService.data(for: path), audioData)
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: path)), 0o600)
  }

  func testVideoCacheFilesAreEncryptedAndReadable() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let videoData = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])

    let path = try XCTUnwrap(cacheService.cacheVideo(videoData, id: UUID(), fileExtension: "mp4"))
    let rawVideo = try Data(contentsOf: URL(fileURLWithPath: path))

    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawVideo))
    XCTAssertNotEqual(rawVideo, videoData)
    XCTAssertEqual(cacheService.data(for: path), videoData)
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: path)), 0o600)
  }

  func testRichTextCacheFilesAreEncryptedAndReadable() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let rtfData = Data("{\\rtf1\\ansi Goldfish}".utf8)

    let path = try XCTUnwrap(cacheService.cacheRichText(rtfData, id: UUID()))
    let rawRTF = try Data(contentsOf: URL(fileURLWithPath: path))

    XCTAssertTrue(ClipboardEncryptionService.isProtected(rawRTF))
    XCTAssertNotEqual(rawRTF, rtfData)
    XCTAssertEqual(cacheService.data(for: path), rtfData)
    XCTAssertEqual(try testPermissions(URL(fileURLWithPath: path)), 0o600)
  }

  func testLegacyManagedSidecarIsEncryptedAfterRead() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let attachmentDirectory = baseURL.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
    let url = attachmentDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    let pdfData = Data("%PDF-1.4\nlegacy\n%%EOF".utf8)
    try pdfData.write(to: url)

    XCTAssertEqual(cacheService.data(for: url.path), pdfData)

    let migrated = try Data(contentsOf: url)
    XCTAssertTrue(ClipboardEncryptionService.isProtected(migrated))
    XCTAssertFalse(String(decoding: migrated, as: UTF8.self).contains("legacy"))
  }

  func testTemporaryReadableURLWritesPrivateCopyAndCleanupRemovesIt() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let pdfData = Data("%PDF-1.4\ntemporary preview\n%%EOF".utf8)
    let path = try XCTUnwrap(cacheService.cachePDF(pdfData, id: UUID()))

    let previewURL = try XCTUnwrap(cacheService.temporaryReadableURL(for: pdfItem(path: path)))

    XCTAssertEqual(try Data(contentsOf: previewURL), pdfData)
    XCTAssertEqual(try testPermissions(previewURL.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try testPermissions(previewURL), 0o600)

    cacheService.clearTemporaryPreviews(wait: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
  }

  func testTemporaryReadableURLWorksForAudio() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let audioData = Data([9, 8, 7, 6])
    let path = try XCTUnwrap(cacheService.cacheAudio(audioData, id: UUID()))

    let previewURL = try XCTUnwrap(cacheService.temporaryReadableURL(for: audioItem(path: path)))

    XCTAssertEqual(try Data(contentsOf: previewURL), audioData)
    XCTAssertEqual(previewURL.pathExtension, "sound")
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryReadableURLWorksForVideo() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let videoData = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])
    let path = try XCTUnwrap(cacheService.cacheVideo(videoData, id: UUID(), fileExtension: "mp4"))

    let previewURL = try XCTUnwrap(cacheService.temporaryReadableURL(for: videoItem(path: path)))

    XCTAssertEqual(try Data(contentsOf: previewURL), videoData)
    XCTAssertEqual(previewURL.pathExtension, "mp4")
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryReadableURLWorksForRichText() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let rtfData = Data("{\\rtf1\\ansi Temporary Rich Text}".utf8)
    let path = try XCTUnwrap(cacheService.cacheRichText(rtfData, id: UUID()))

    let previewURL = try XCTUnwrap(cacheService.temporaryReadableURL(for: richTextItem(path: path)))

    XCTAssertEqual(try Data(contentsOf: previewURL), rtfData)
    XCTAssertEqual(previewURL.pathExtension, "rtf")
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryPreviewURLWritesTextFile() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let item = textItem("Quick Look text")

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: item))

    XCTAssertEqual(previewURL.pathExtension, "txt")
    XCTAssertEqual(try String(contentsOf: previewURL), "Quick Look text")
    XCTAssertEqual(try testPermissions(previewURL.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryPreviewURLWritesWebLocationFile() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let item = urlItem("https://example.com/releases")

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: item))
    let data = try Data(contentsOf: previewURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String]
    )

    XCTAssertEqual(previewURL.pathExtension, "webloc")
    XCTAssertEqual(plist["URL"], "https://example.com/releases")
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryPreviewURLReturnsExistingFileURL() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let fileURL = baseURL.appendingPathComponent("report.txt")
    try Data("Report".utf8).write(to: fileURL)

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: fileItem(path: fileURL.path)))

    XCTAssertEqual(previewURL.standardizedFileURL, fileURL.standardizedFileURL)
  }

  private func imageCacheFileURLs(in baseURL: URL) throws -> [URL] {
    let imageDirectory = baseURL.appendingPathComponent("images", isDirectory: true)
    return try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
  }

  private func thumbnailCacheFileURLs(in baseURL: URL) throws -> [URL] {
    let directory = baseURL.appendingPathComponent("thumbnails", isDirectory: true)
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
  }

  private func textItem(_ text: String) -> ClipboardItem {
    testItem(payload: text, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)
  }

  private func urlItem(_ url: String) -> ClipboardItem {
    testItem(kind: .url, payload: url, payloadHash: "hash", createdAt: Date(), lastUsedAt: Date(), useCount: 0)
  }

  private func pdfItem(path: String) -> ClipboardItem {
    testItem(
      kind: .pdf, displayText: "PDF", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
  }

  private func fileItem(path: String) -> ClipboardItem {
    testItem(
      kind: .file, displayText: "File", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
  }

  private func audioItem(path: String) -> ClipboardItem {
    testItem(
      kind: .audio, displayText: "Audio", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
  }

  private func videoItem(path: String) -> ClipboardItem {
    testItem(
      kind: .video, displayText: "Video", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
  }

  private func richTextItem(path: String) -> ClipboardItem {
    testItem(
      kind: .richText, displayText: "Rich Text", payload: path, payloadHash: "hash", createdAt: Date(),
      lastUsedAt: Date(), useCount: 0)
  }

  private func temporaryPreviewRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(AppConfiguration.appName, isDirectory: true)
  }

  private func makeImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 64, height: 40)
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
  }

  private func makePDFData() throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw NSError(domain: "GoldfishTests", code: 1)
    }
    var box = CGRect(x: 0, y: 0, width: 160, height: 120)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      throw NSError(domain: "GoldfishTests", code: 2)
    }

    context.beginPDFPage(nil)
    context.setFillColor(NSColor.systemOrange.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fillEllipse(in: CGRect(x: 45, y: 30, width: 70, height: 60))
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

}
