import Foundation

enum PinboardIcon {
  static let choices: [(symbol: String, label: String)] = [
    ("circle.fill", "Dot"), ("square.grid.2x2.fill", "Grid"), ("star.fill", "Star"), ("heart.fill", "Heart"), ("briefcase.fill", "Work"),
    ("book.closed.fill", "Book"), ("bolt.fill", "Bolt"), ("leaf.fill", "Leaf"),
  ]

  static let defaultSymbol = "circle.fill"

  static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    return choices.first { $0.symbol == value }?.symbol
  }
}
