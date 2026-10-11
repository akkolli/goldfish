import Foundation

enum CodeSnippetPayload {
  static func isLikelyCode(_ value: String) -> Bool {
    let text = value.clipboardTrimmed
    guard text.count >= 12 else { return false }
    if text.hasPrefix("```") { return true }
    if languageLabel(from: text) != "Code" { return true }

    let lines = text.components(separatedBy: .newlines)
    let nonEmptyLines = lines.map(\.clipboardTrimmed).filter { !$0.isEmpty }
    guard !nonEmptyLines.isEmpty else { return false }

    var score = 0
    if nonEmptyLines.count >= 2 && lines.contains(where: { $0.hasPrefix(" ") || $0.hasPrefix("\t") }) { score += 2 }
    if text.contains("{") && text.contains("}") { score += 2 }
    if text.contains(";") { score += 1 }
    if text.contains("=>") || text.contains("->") || text.contains("==") || text.contains("!=") || text.contains("&&")
      || text.contains("||")
    {
      score += 1
    }
    if nonEmptyLines.filter({ $0.hasSuffix("{") || $0.hasSuffix("}") || $0.hasSuffix(";") }).count >= 2 { score += 2 }
    if containsCodeKeyword(text) { score += 2 }
    if containsAssignment(text) { score += 1 }

    return score >= 4
  }

  static func languageLabel(from value: String) -> String {
    let text = value.clipboardTrimmed
    let lower = text.lowercased()
    if isJSON(text) { return "JSON" }
    if lower.contains("<html") || lower.contains("</") && lower.contains(">") { return "HTML" }
    if lower.contains("#include") { return "C/C++" }
    if lower.contains("func ") || lower.contains("let ") || lower.contains("var ") && lower.contains("->") { return "Swift" }
    if lower.contains("function ") || lower.contains("const ") || lower.contains("let ") && lower.contains("=>") { return "JavaScript" }
    if lower.contains("def ") || lower.contains("import ") && lower.contains(":") { return "Python" }
    if lower.range(of: #"\b(select|insert|update|delete|create)\b[\s\S]+\b(from|into|table|set)\b"#, options: .regularExpression) != nil {
      return "SQL"
    }
    if lower.range(of: #"^\s*(git|npm|yarn|pnpm|curl|ssh|docker|kubectl|brew|swift|python|node)\b"#, options: .regularExpression) != nil {
      return "Shell"
    }
    if lower.contains("{") && lower.contains(":") && lower.contains(";") { return "CSS" }
    return "Code"
  }

  static func title(from value: String) -> String {
    let language = languageLabel(from: value)
    guard language != "Code" else { return "Code Snippet" }
    return "\(language) Snippet"
  }

  private static func containsCodeKeyword(_ value: String) -> Bool {
    value.range(
      of:
        #"\b(import|func|function|class|struct|enum|interface|return|guard|if|else|for|while|switch|case|try|catch|throw|async|await|public|private|static|const|let|var|def)\b"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func containsAssignment(_ value: String) -> Bool {
    value.range(of: #"\b[A-Za-z_][A-Za-z0-9_]*\s*(=|:=)\s*[^=\n]"#, options: .regularExpression) != nil
  }

  private static func isJSON(_ value: String) -> Bool {
    guard let data = value.data(using: .utf8) else { return false }
    let trimmed = value.clipboardTrimmed
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }
}
