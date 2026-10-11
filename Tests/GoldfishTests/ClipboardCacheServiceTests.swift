import AppKit
import CryptoKit
import XCTest

@testable import Goldfish

final class ClipboardCacheServiceTests: IsolatedTestCase {

  func testPurgeRemovesOnlyThumbnailsOverByteLimit() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let first = try XCTUnwrap(cacheService.cacheImage(testImage(color: .systemRed, size: NSSize(width: 64, height: 40)), id: UUID()))
    let second = try XCTUnwrap(cacheService.cacheImage(testImage(color: .systemBlue, size: NSSize(width: 64, height: 40)), id: UUID()))

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
    let image = try XCTUnwrap(cacheService.cacheImage(testImage(color: .systemGreen, size: NSSize(width: 64, height: 40)), id: UUID()))
    let pdfPath = try XCTUnwrap(cacheService.cachePDF(Data("%PDF-1.4\n%%EOF".utf8), id: UUID()))
    let pdfItem = testItem(kind: .pdf, payload: pdfPath)
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
    let imageData = try XCTUnwrap(testImage(color: .systemBrown, size: NSSize(width: 64, height: 40)).pngData())
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
    let image = testImage(color: .systemPurple, size: NSSize(width: 64, height: 40))

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
    let imageData = try XCTUnwrap(testImage(color: .systemOrange, size: NSSize(width: 64, height: 40)).pngData())
    try imageData.write(to: imageURL)

    let item = testItem(kind: .file, payload: imageURL.path)

    XCTAssertNotNil(cacheService.previewThumbnail(for: item))
  }

  func testPreviewThumbnailUsesManagedPDFPreviewFallback() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption(byte: 7))
    let pdfData = try makePDFData()
    let path = try XCTUnwrap(cacheService.cachePDF(pdfData, id: UUID()))

    XCTAssertNotNil(cacheService.previewThumbnail(for: testItem(kind: .pdf, payload: path)))
  }

  func testPreviewThumbnailUsesDecryptedVideoTemporaryCopyAndCachesResult() throws {
    let baseURL = try makeTempDirectory()
    let videoData = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])
    var providerURLs: [URL] = []
    let cacheService = ClipboardCacheService(
      baseURL: baseURL, encryptionService: testEncryption(byte: 7),
      videoThumbnailProvider: { url in
        providerURLs.append(url)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(try? Data(contentsOf: url), videoData)
        return testImage(color: .systemIndigo, size: NSSize(width: 64, height: 40))
      })
    let path = try XCTUnwrap(cacheService.cacheVideo(videoData, id: UUID(), fileExtension: "mp4"))
    let item = testItem(kind: .video, payload: path)

    let thumbnail = cacheService.previewThumbnail(for: item)
    let cachedThumbnail = cacheService.previewThumbnail(for: item)

    XCTAssertNotNil(thumbnail)
    XCTAssertNotNil(cachedThumbnail)
    XCTAssertEqual(providerURLs.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(providerURLs.first).path))
  }

  func testManagedAttachmentsAreEncryptedPrivateAndReadable() throws {
    let cases: [(ClipboardItemKind, Data)] = [
      (.pdf, Data("%PDF-1.4\nclipbored\n%%EOF".utf8)), (.audio, Data([0, 1, 2, 3, 5, 8, 13])),
      (.video, Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])), (.richText, Data("{\\rtf1\\ansi Goldfish}".utf8)),
    ]
    for (kind, data) in cases {
      let cache = ClipboardCacheService(baseURL: try makeTempDirectory(), encryptionService: testEncryption(byte: 7))
      let path = try cacheAttachment(data, kind: kind, cache: cache)
      let raw = try Data(contentsOf: URL(fileURLWithPath: path))
      XCTAssertTrue(ClipboardEncryptionService.isProtected(raw), kind.displayName)
      XCTAssertNotEqual(raw, data, kind.displayName)
      XCTAssertEqual(cache.data(for: path), data, kind.displayName)
      XCTAssertEqual(try testPermissions(URL(fileURLWithPath: path)), 0o600, kind.displayName)
    }
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

  func testManagedAttachmentPreviewsPreserveDataExtensionsAndPrivatePermissions() throws {
    let cases: [(ClipboardItemKind, Data, String)] = [
      (.pdf, Data("%PDF-1.4\ntemporary preview\n%%EOF".utf8), "pdf"), (.audio, Data([9, 8, 7, 6]), "sound"),
      (.video, Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50]), "mp4"),
      (.richText, Data("{\\rtf1\\ansi Temporary Rich Text}".utf8), "rtf"),
    ]
    for (kind, data, ext) in cases {
      let cache = ClipboardCacheService(baseURL: try makeTempDirectory(), encryptionService: testEncryption(byte: 7))
      let path = try cacheAttachment(data, kind: kind, cache: cache)
      let preview = try XCTUnwrap(cache.temporaryReadableURL(for: testItem(kind: kind, payload: path)))
      XCTAssertEqual(try Data(contentsOf: preview), data, kind.displayName)
      XCTAssertEqual(preview.pathExtension, ext, kind.displayName)
      XCTAssertEqual(try testPermissions(preview.deletingLastPathComponent()), 0o700, kind.displayName)
      XCTAssertEqual(try testPermissions(preview), 0o600, kind.displayName)
      cache.clearTemporaryPreviews(wait: true)
      XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path), kind.displayName)
    }
  }

  private func cacheAttachment(_ data: Data, kind: ClipboardItemKind, cache: ClipboardCacheService) throws -> String {
    let path: String?
    switch kind {
    case .pdf: path = cache.cachePDF(data, id: UUID())
    case .audio: path = cache.cacheAudio(data, id: UUID())
    case .video: path = cache.cacheVideo(data, id: UUID(), fileExtension: "mp4")
    case .richText: path = cache.cacheRichText(data, id: UUID())
    default:
      XCTFail("Unhandled attachment scenario")
      path = nil
    }
    return try XCTUnwrap(path)
  }

  func testTemporaryPreviewURLWritesTextFile() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let item = testItem(payload: "Quick Look text", useCount: 0)

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: item))

    XCTAssertEqual(previewURL.pathExtension, "txt")
    XCTAssertEqual(try String(contentsOf: previewURL), "Quick Look text")
    XCTAssertEqual(try testPermissions(previewURL.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryPreviewURLWritesWebLocationFile() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let item = testItem(kind: .url, payload: "https://example.com/releases", useCount: 0)

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: item))
    let data = try Data(contentsOf: previewURL)
    let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String])

    XCTAssertEqual(previewURL.pathExtension, "webloc")
    XCTAssertEqual(plist["URL"], "https://example.com/releases")
    XCTAssertEqual(try testPermissions(previewURL), 0o600)
  }

  func testTemporaryPreviewURLReturnsExistingFileURL() throws {
    let baseURL = try makeTempDirectory()
    let cacheService = ClipboardCacheService(baseURL: baseURL, encryptionService: testEncryption())
    let fileURL = baseURL.appendingPathComponent("report.txt")
    try Data("Report".utf8).write(to: fileURL)

    let previewURL = try XCTUnwrap(cacheService.temporaryPreviewURL(for: testItem(kind: .file, payload: fileURL.path)))

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

  private func makePDFData() throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw NSError(domain: "GoldfishTests", code: 1) }
    var box = CGRect(x: 0, y: 0, width: 160, height: 120)
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw NSError(domain: "GoldfishTests", code: 2) }

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
