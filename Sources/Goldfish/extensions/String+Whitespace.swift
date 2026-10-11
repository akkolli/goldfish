extension StringProtocol {
  /// User-visible names have fixed compatibility limits and one whitespace policy.
  func clipboardLabel(limit: Int) -> String? {
    let value = split { $0.isWhitespace }.joined(separator: " ")
    return value.isEmpty ? nil : String(value.prefix(limit))
  }

  var clipboardTrimmed: String {
    var start = startIndex
    var end = endIndex

    while start < end, self[start].isWhitespace { formIndex(after: &start) }
    while end > start {
      let previous = index(before: end)
      if !self[previous].isWhitespace { break }
      end = previous
    }

    return String(self[start..<end])
  }
}
