import AppKit

enum ClipboardWrites {
  private static let queue = DispatchQueue(label: "clipboard.self-write-tracker")
  private static var changeCounts: [String: [Int]] = [:]

  static func mark(changeCount: Int, pasteboard: NSPasteboard = .general) {
    queue.sync {
      let key = pasteboard.name.rawValue
      changeCounts[key] = Array(((changeCounts[key] ?? []) + [changeCount]).suffix(16))
    }
  }

  static func consume(changeCount: Int, pasteboard: NSPasteboard = .general) -> Bool {
    queue.sync {
      let key = pasteboard.name.rawValue
      guard let index = changeCounts[key]?.firstIndex(of: changeCount) else { return false }
      changeCounts[key]?.remove(at: index)
      if changeCounts[key]?.isEmpty == true { changeCounts.removeValue(forKey: key) }
      return true
    }
  }
}
