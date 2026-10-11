import AppKit
import Vision

enum ImageTextExtractor {
  static func recognizedText(in image: NSImage) -> String? {
    let boundedImage = image.resized(to: CGSize(width: AppConfig.maxFullImagePixelSize, height: AppConfig.maxFullImagePixelSize))
    guard let cgImage = boundedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.015

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch { return nil }

    let lines = request.results?.compactMap { observation in observation.topCandidates(1).first?.string.clipboardTrimmed } ?? []
    return normalized(lines)
  }

  static func normalizedRecognizedText(_ text: String?) -> String? {
    guard let text else { return nil }
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(AppConfig.maxRecognizedImageTextLength))
  }

  private static func normalized(_ lines: [String]) -> String? {
    normalizedRecognizedText(lines.filter { !$0.isEmpty }.joined(separator: " "))
  }
}
