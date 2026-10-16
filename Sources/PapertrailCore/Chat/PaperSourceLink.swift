import Foundation

/// App-internal links from chat and review text to a location in the paper's PDF.
public enum PaperSourceLink: Equatable, Sendable {
  /// 1-based PDF page, matching the `PDF PAGE` markers in the extracted paper text.
  case page(Int)
  /// Evidence identifier from the selected review.
  case evidence(String)

  public static let pageScheme = "papertrail-page"
  public static let evidenceScheme = "papertrail-evidence"

  public init?(url: URL) {
    guard let scheme = url.scheme?.lowercased() else { return nil }
    let value =
      String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding ?? ""
    switch scheme {
    case Self.pageScheme:
      guard let page = Int(value), page > 0 else { return nil }
      self = .page(page)
    case Self.evidenceScheme where !value.isEmpty:
      self = .evidence(value)
    default:
      return nil
    }
  }

  public var url: URL {
    switch self {
    case .page(let page):
      return URL(string: "\(Self.pageScheme):\(page)")!
    case .evidence(let id):
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
      return URL(string: "\(Self.evidenceScheme):\(encoded)")!
    }
  }

  // Matches bracketed citations that name a page, e.g. [p. 4], [pp. 4–5], [Sec. 3.2, p. 7].
  private static let citationPattern = try! NSRegularExpression(
    pattern: #"(?<![\\!])\[([^\[\]\n]*?\bpp?\.\s?(\d+)[^\[\]\n]*)\](?!\()"#)

  /// Turns page citations into Markdown links to the first cited PDF page.
  /// Presentation only: persisted message text is never rewritten.
  public static func linkingPageCitations(in markdown: String) -> String {
    let source = markdown as NSString
    var result = markdown
    let matches = citationPattern.matches(
      in: markdown, range: NSRange(location: 0, length: source.length))
    // Replace from the end so earlier ranges stay valid.
    for match in matches.reversed() {
      guard let page = Int(source.substring(with: match.range(at: 2))),
        let range = Range(match.range, in: result)
      else { continue }
      let label = source.substring(with: match.range(at: 1))
      // Brackets stay literal outside the link; `\[` would start display math.
      result.replaceSubrange(range, with: "[[\(label)](\(PaperSourceLink.page(page).url.absoluteString))]")
    }
    return result
  }
}

/// A verified excerpt from a rendered review, located by its 1-based PDF page.
public struct ReviewEvidenceAnchor: Equatable, Sendable {
  public let id: String
  public let pageIndex: Int
  public let excerpt: String

  public init(id: String, pageIndex: Int, excerpt: String) {
    self.id = id
    self.pageIndex = pageIndex
    self.excerpt = excerpt
  }

  // Mirrors ReviewHTMLRenderer.evidenceSection, which renders every stored review.
  private static let evidencePattern = try! NSRegularExpression(
    pattern:
      #"<details id="evidence-([^"]+)"><summary>\[[^<]*?\] p\.(\d+)[^<]*</summary><div class="note"><blockquote[^>]*>([\s\S]*?)</blockquote>"#
  )

  public static func anchors(inReviewHTML html: String) -> [ReviewEvidenceAnchor] {
    let source = html as NSString
    return evidencePattern.matches(in: html, range: NSRange(location: 0, length: source.length))
      .compactMap { match in
        guard let page = Int(source.substring(with: match.range(at: 2))) else { return nil }
        return ReviewEvidenceAnchor(
          id: unescape(source.substring(with: match.range(at: 1))), pageIndex: page,
          excerpt: unescape(source.substring(with: match.range(at: 3))))
      }
  }

  private static func unescape(_ value: String) -> String {
    value.replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}
