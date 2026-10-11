import XCTest
@testable import Goldfish

final class ClipboardTextStatisticsTests: XCTestCase {
  func testCountsSpacesAndLineBreaks() throws {
    let counts = try XCTUnwrap(ClipboardTextStatistics(item: item("one  two\n\nthree\t")))
    XCTAssertEqual(counts.characters, 16)
    let whitespace = try XCTUnwrap(ClipboardTextStatistics(item: item(" \t\n")))
    XCTAssertEqual(whitespace.characters, 3)
    let empty = try XCTUnwrap(ClipboardTextStatistics(item: item("")))
    XCTAssertEqual(empty.characters, 0)
  }

  func testCountsUserPerceivedCharacters() throws {
    let counts = try XCTUnwrap(ClipboardTextStatistics(item: item("👩🏽‍💻 cafe\u{301}!")))
    XCTAssertEqual(counts.characters, 7, "A combined emoji and an accented letter each count as one character")
  }

  func testCountsFullClipInsteadOfPreviewOrCustomTitle() throws {
    var clip = item(String(repeating: "hello ", count: 500))
    clip.customTitle = "A custom title"
    let counts = try XCTUnwrap(ClipboardTextStatistics(item: clip))
    XCTAssertEqual(counts.characters, 3000)
    XCTAssertLessThan(ClipboardItemCardContentFormatter().cardText(for: clip).count, counts.characters)
  }

  func testRichTextCountsVisibleTextAndMediaDoesNotCountStoragePaths() throws {
    var richText = item("/cache/attachment.rtf", kind: .richText)
    richText.displayText = "Hello world"
    let counts = try XCTUnwrap(ClipboardTextStatistics(item: richText))
    XCTAssertEqual(counts.characters, 11)
    for kind: ClipboardItemKind in [.image, .file, .pdf, .audio, .video, .color, .url] {
      XCTAssertNil(ClipboardTextStatistics(item: item("/cache/attachment", kind: kind)))
    }
    XCTAssertNil(ClipboardTextStatistics(item: item("https://example.com")))
  }

  func testSingularLabelsAndCodeCounts() throws {
    let singular = try XCTUnwrap(ClipboardTextStatistics(item: item("a")))
    XCTAssertEqual(singular.formattedCount, "1")
    XCTAssertEqual(singular.accessibilityDescription, "1 character")
    let code = try XCTUnwrap(ClipboardTextStatistics(item: item("let x = 1", kind: .code)))
    XCTAssertEqual(code.characters, 9)
    XCTAssertEqual(code.accessibilityDescription, "9 characters")
  }

  private func item(_ text: String, kind: ClipboardItemKind = .text) -> ClipboardItem {
    testItem(
      kind: kind, payload: text, payloadHash: UUID().uuidString, createdAt: Date(), lastUsedAt: Date(),
      useCount: 0, sourceApp: "Notes")
  }
}
