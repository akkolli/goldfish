import AppKit

/// One immutable geometry plan for both shelf layouts. Compact neighbors share
/// equal-height rows, keeping reading order and viewport lookup monotonic.
struct CardArrangement {
  struct Entry {
    let frame: NSRect
    let layout: CardLayout
    let row: Int
  }

  let entries: [Entry]
  let rows: [Range<Int>]
  let size: NSSize
  let horizontal: Bool

  init(items: [Clip], base: CardLayout, spacing: CGFloat, horizontal: Bool = false) {
    self.horizontal = horizontal
    if horizontal {
      entries = items.indices.map { index in
        Entry(
          frame: NSRect(x: CGFloat(index) * (base.width + spacing), y: 0, width: base.width, height: base.height), layout: base, row: index)
      }
      rows = items.indices.map { $0..<($0 + 1) }
      size = NSSize(width: entries.last?.frame.maxX ?? 0, height: base.height)
      return
    }
    let tileWidth = floor((base.width - spacing) / 2)
    let canPair = tileWidth >= ceil(180 * base.textScale)
    let tileBase = base.withWidth(tileWidth)
    let tileLayouts = canPair ? items.map { tileBase.fittingVerticalContent(of: $0) } : []
    func fitsTile(_ index: Int) -> Bool {
      guard canPair else { return false }
      switch items[index].presentationKind {
      case .code: return false
      case .text, .richText, .unknown:
        // Keep paragraphs wide; pairing should save space without hiding text.
        return tileLayouts[index].bodyHeight <= ceil(110 * base.textScale)
      default: return true
      }
    }

    func sharesRow(_ first: Int, _ second: Int) -> Bool {
      guard fitsTile(first), fitsTile(second) else { return false }
      // A shared row should look intentional. Pair similarly proportioned
      // cards and let strongly mismatched content use its natural full width.
      let difference = abs(tileLayouts[first].height - tileLayouts[second].height)
      return difference <= ceil(36 * base.textScale)
    }

    var result: [Entry] = []
    var rowRanges: [Range<Int>] = []
    var y: CGFloat = 0
    var index = 0
    while index < items.count {
      let paired = index + 1 < items.count && sharesRow(index, index + 1)
      let count = paired ? 2 : 1
      let layouts = paired ? [tileLayouts[index], tileLayouts[index + 1]] : [base.fittingVerticalContent(of: items[index])]
      let rowHeight = layouts.map(\.height).max() ?? 0
      for (column, layout) in layouts.enumerated() {
        let fitted = layout.withHeight(rowHeight)
        result.append(
          Entry(
            frame: NSRect(x: CGFloat(column) * (tileWidth + spacing), y: y, width: fitted.width, height: rowHeight), layout: fitted,
            row: rowRanges.count))
      }
      rowRanges.append(index..<(index + count))
      index += count
      y += rowHeight + spacing
    }
    entries = result
    rows = rowRanges
    size = NSSize(width: base.width, height: max(0, y - spacing))
  }

  var height: CGFloat { size.height }

  /// First index after a monotonic prefix; pairs deliberately share both edges.
  private func partitionIndex(_ predicate: (NSRect) -> Bool) -> Int {
    var lower = 0
    var upper = entries.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if predicate(entries[middle].frame) { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }

  func visibleRange(in bounds: NSRect, inset: CGFloat, prefetch: Int) -> Range<Int> {
    guard !entries.isEmpty else { return 0..<0 }
    let start = max(0, (horizontal ? bounds.minX : bounds.minY) - inset)
    let end = max(start, (horizontal ? bounds.maxX : bounds.maxY) - inset)
    let first = min(partitionIndex { (horizontal ? $0.maxX : $0.maxY) < start }, entries.count - 1)
    let last = max(0, partitionIndex { (horizontal ? $0.minX : $0.minY) <= end } - 1)
    let lower = max(0, first - prefetch)
    return lower..<max(lower, min(entries.count, last + prefetch + 1))
  }

  func distance(from first: Int, to second: Int) -> Int {
    guard !horizontal, entries.indices.contains(first), entries.indices.contains(second) else { return abs(first - second) }
    let a = entries[first]
    let b = entries[second]
    let sharesColumn = a.frame.minX < b.frame.maxX && b.frame.minX < a.frame.maxX
    return abs(a.row - b.row) + (sharesColumn ? 0 : 1)
  }

  func verticalNeighbor(of index: Int, direction: Int, preferredX: CGFloat? = nil) -> Int {
    guard entries.indices.contains(index) else { return index }
    let targetRow = entries[index].row + direction
    guard rows.indices.contains(targetRow) else { return index }
    let x = preferredX ?? entries[index].frame.midX
    return rows[targetRow].min { abs(entries[$0].frame.midX - x) < abs(entries[$1].frame.midX - x) } ?? index
  }
}
