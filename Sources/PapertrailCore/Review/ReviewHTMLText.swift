import Foundation

/// Converts an app-rendered, sanitized review page into plain text for a chat bootstrap. The
/// input is Papertrail's own `ReviewHTMLRenderer` output, so a small tag stripper is enough and
/// avoids WebKit/AppKit HTML parsing off the main thread.
public enum ReviewHTMLText {
  public static let maximumTextBytes = 512 * 1_024

  public static func plainText(_ html: String) -> String {
    var text = html
    for pattern in [
      #"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<script\b.*?</script>"#,
      #"(?s)<!--.*?-->"#,
    ] {
      text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = text.replacingOccurrences(
      of: #"(?i)<br\s*/?>|</(p|div|li|h[1-6]|section|article|tr|header|footer|ul|ol)>"#,
      with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "- ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: "\t", options: .regularExpression)
    text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    text = decodeEntities(text)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var collapsed: [String] = []
    for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
      collapsed.append(line)
    }
    let result = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.utf8.count > maximumTextBytes else { return result }
    return String(decoding: Data(result.utf8).prefix(maximumTextBytes), as: UTF8.self)
  }

  private static func decodeEntities(_ value: String) -> String {
    var result = ""
    var cursor = value.startIndex
    while let ampersand = value[cursor...].firstIndex(of: "&") {
      result += value[cursor..<ampersand]
      guard let semicolon = value[ampersand...].prefix(12).firstIndex(of: ";") else {
        result += "&"
        cursor = value.index(after: ampersand)
        continue
      }
      let entity = value[value.index(after: ampersand)..<semicolon]
      if let decoded = decode(entity) {
        result += decoded
        cursor = value.index(after: semicolon)
      } else {
        result += "&"
        cursor = value.index(after: ampersand)
      }
    }
    result += value[cursor...]
    return result
  }

  private static func decode(_ entity: Substring) -> String? {
    switch entity {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos": return "'"
    case "nbsp": return " "
    default:
      let scalarValue: UInt32?
      if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
        scalarValue = UInt32(entity.dropFirst(2), radix: 16)
      } else if entity.hasPrefix("#") {
        scalarValue = UInt32(entity.dropFirst())
      } else {
        scalarValue = nil
      }
      return scalarValue.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
  }
}
