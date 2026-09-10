import Foundation

public enum FilenameSanitizer {
  public static func safeStem(for title: String, maximumUTF8Bytes: Int = 80) -> String {
    let normalized = title.precomposedStringWithCanonicalMapping
    var output = ""
    var pendingSeparator = false
    for scalar in normalized.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if pendingSeparator && !output.isEmpty { output.append("-") }
        pendingSeparator = false
        let candidate = output + String(scalar).lowercased()
        if candidate.utf8.count > maximumUTF8Bytes { break }
        output = candidate
      } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || scalar == "-" || scalar == "_"
      {
        pendingSeparator = true
      }
    }
    let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))
    return trimmed.isEmpty ? "untitled-paper" : trimmed
  }

  public static func collisionProofPDFName(title: String, paperID: UUID) -> String {
    "\(safeStem(for: title))--\(paperID.uuidString.lowercased()).pdf"
  }

  public static func displayTitle(_ candidate: String) -> String? {
    let normalized = candidate.precomposedStringWithCanonicalMapping
      .unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" || $0 == "\n" }
      .map(String.init).joined()
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(240))
  }
}
