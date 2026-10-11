import AppKit
import Foundation

enum VideoPayload {
  private enum TypeIdentifier {
    static let mpeg4Movie = "public.mpeg-4"
    static let quickTimeMovie = "com.apple.quicktime-movie"
    static let movie = "public.movie"
    static let video = "public.video"
  }

  static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType(rawValue: TypeIdentifier.mpeg4Movie), NSPasteboard.PasteboardType(rawValue: TypeIdentifier.quickTimeMovie),
    NSPasteboard.PasteboardType(rawValue: TypeIdentifier.movie), NSPasteboard.PasteboardType(rawValue: TypeIdentifier.video),
    NSPasteboard.PasteboardType(rawValue: "com.apple.m4v-video"),
  ]

  static func data(from pasteboard: NSPasteboard) -> (data: Data, type: NSPasteboard.PasteboardType)? {
    for type in pasteboardTypes { if let data = pasteboard.data(forType: type), !data.isEmpty { return (data, type) } }
    return nil
  }

  static func fileExtension(for type: NSPasteboard.PasteboardType) -> String {
    switch type.rawValue {
    case TypeIdentifier.mpeg4Movie: return "mp4"
    case TypeIdentifier.quickTimeMovie, TypeIdentifier.movie, TypeIdentifier.video: return "mov"
    case "com.apple.m4v-video": return "m4v"
    default: return "mov"
    }
  }

  static func pasteboardType(forPath path: String) -> NSPasteboard.PasteboardType {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "mp4": return NSPasteboard.PasteboardType(rawValue: TypeIdentifier.mpeg4Movie)
    case "m4v": return NSPasteboard.PasteboardType(rawValue: "com.apple.m4v-video")
    case "mov", "qt": return NSPasteboard.PasteboardType(rawValue: TypeIdentifier.quickTimeMovie)
    default: return NSPasteboard.PasteboardType(rawValue: TypeIdentifier.movie)
    }
  }

  static func displayTitle(byteCount: Int) -> String {
    "Video (\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)))"
  }

  static func fileExtension(from path: String) -> String {
    let value = URL(fileURLWithPath: path).pathExtension.clipboardTrimmed
    return value.isEmpty ? "mov" : value.lowercased()
  }
}
