import AppKit
import UniformTypeIdentifiers

enum ArchivePicker {
  static func panel(exporting: Bool, collection: String? = nil) -> NSSavePanel {
    let panel: NSSavePanel = exporting ? NSSavePanel() : NSOpenPanel()
    panel.title = collection.map { "Export \($0) Pinboard" } ?? (exporting ? "Export Goldfish Archive" : "Import Goldfish Archive")
    if let picker = panel as? NSOpenPanel {
      picker.canChooseFiles = true
      picker.canChooseDirectories = false
      picker.allowsMultipleSelection = false
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd-HHmm"
      let board =
        collection.map {
          let safe = $0.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
          return (safe.isEmpty ? "Pinboard" : safe) + "-"
        } ?? ""
      panel.nameFieldStringValue = "Goldfish-\(board)\(formatter.string(from: Date()))"
    }
    configure(panel)
    return panel
  }

  static func configure(_ panel: NSSavePanel) {
    if let type = UTType(filenameExtension: HistoryArchive.fileExtension, conformingTo: .data) { panel.allowedContentTypes = [type] }
    panel.isExtensionHidden = false
  }

}
