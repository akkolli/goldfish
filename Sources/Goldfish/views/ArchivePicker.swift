import AppKit
import UniformTypeIdentifiers

enum ArchivePicker {
  static func configure(_ panel: NSSavePanel) {
    if let type = UTType(filenameExtension: HistoryArchive.fileExtension, conformingTo: .data) { panel.allowedContentTypes = [type] }
    panel.isExtensionHidden = false
  }

  static func suggestedName(_ fileName: String) -> String {
    let suffix = "." + HistoryArchive.fileExtension
    return fileName.hasSuffix(suffix) ? String(fileName.dropLast(suffix.count)) : fileName
  }
}
