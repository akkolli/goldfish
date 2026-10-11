import AppKit
import CryptoKit
import XCTest
@testable import Goldfish

/// Defaults describe an ordinary new text clip; scenarios supply only their differences.
func testItem(
  id: UUID = UUID(), kind: ClipboardItemKind = .text, displayText: String? = nil,
  payload: String, payloadHash: String? = nil, createdAt: Date = Date(), lastUsedAt: Date? = nil,
  useCount: Int = 1, sourceApp: String? = nil, imagePath: String? = nil, thumbnailPath: String? = nil,
  isPinned: Bool = false, sourceAppBundleId: String? = nil, ocrText: String? = nil,
  collectionName: String? = nil, customTitle: String? = nil, sourceDeviceName: String? = ClipboardItem.localDeviceName
) -> ClipboardItem {
  ClipboardItem(
    id: id, kind: kind, displayText: displayText ?? payload, payload: payload, payloadHash: payloadHash ?? payload,
    createdAt: createdAt, lastUsedAt: lastUsedAt ?? createdAt, useCount: useCount, sourceApp: sourceApp,
    imagePath: imagePath, thumbnailPath: thumbnailPath, isPinned: isPinned, sourceAppBundleId: sourceAppBundleId,
    ocrText: ocrText, collectionName: collectionName, customTitle: customTitle, sourceDeviceName: sourceDeviceName)
}

func testImage(color: NSColor, size: NSSize = NSSize(width: 24, height: 24)) -> NSImage {
  let image = NSImage(size: size)
  image.lockFocus()
  color.setFill()
  NSRect(origin: .zero, size: size).fill()
  image.unlockFocus()
  return image
}

func testEncryption(byte: UInt8? = nil) -> ClipboardEncryptionService {
  ClipboardEncryptionService(keyProvider: { byte.map { SymmetricKey(data: Data(repeating: $0, count: 32)) } })
}

func testPermissions(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try XCTUnwrap(attributes[.posixPermissions] as? Int, file: file, line: line) & 0o777
}
