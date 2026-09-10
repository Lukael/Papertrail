import Foundation

public struct ReviewSanitizationReport: Codable, Equatable, Sendable {
  public let removedConstructs: [String]
  public let preservedConfirmedExternalLinks: [String]
  public let csp: String
}

public struct SanitizedReview: Equatable, Sendable {
  public let html: String
  public let report: ReviewSanitizationReport
}

public struct ReviewResourceSanitizer: Sendable {
  public static let contentSecurityPolicy =
    "default-src 'none'; img-src 'none'; style-src 'self' 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'; media-src 'none'"

  public init() {}

  public func sanitize(_ source: String) throws -> SanitizedReview {
    var html = source
    var removed: Set<String> = []
    var preserved: Set<String> = []

    for tag in [
      "script", "iframe", "frame", "form", "button", "object", "embed", "applet", "audio",
      "video", "canvas", "svg", "img", "image",
    ] {
      let before = html
      html = try replace(
        #"(?is)<\#(tag)\b[^>]*>.*?</\#(tag)\s*>"#, in: html, with: "")
      if html != before { removed.insert("tag:\(tag)") }
    }
    for tag in [
      "base", "meta", "link", "input", "source", "track", "script", "iframe", "frame", "form",
      "button", "object", "embed", "applet", "audio", "video", "canvas", "svg", "img",
      "image",
    ] {
      let before = html
      html = try replace(#"(?is)<\#(tag)\b[^>]*?/?>"#, in: html, with: "")
      if html != before { removed.insert("tag:\(tag)") }
    }

    let forbiddenAttributes = [
      #"(?is)\s+on[a-z0-9_-]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
      #"(?is)\s+(?:srcset|poster|background|action|formaction|ping|download|target)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
    ]
    for pattern in forbiddenAttributes {
      let before = html
      html = try replace(pattern, in: html, with: "")
      if html != before { removed.insert("active-attribute") }
    }

    html = try rewriteAttribute("href", in: html) { value in
      if value.hasPrefix("#") || isSafeLocalResource(value, requiredPrefix: nil) { return value }
      if isApprovedExternalLink(value) {
        preserved.insert(value)
        return value
      }
      removed.insert("unsafe-href")
      return nil
    }
    html = try annotateApprovedExternalLinks(html)

    let styleBlocks = try matches(#"(?is)<style\b[^>]*>(.*?)</style\s*>"#, in: html)
    for block in styleBlocks {
      var cleaned = block
      for pattern in [
        #"(?is)@import\s+[^;]+;?"#,
        #"(?is)@font-face\s*\{.*?\}"#,
        #"(?is)url\s*\([^)]+\)"#,
        #"(?is)expression\s*\([^)]*\)"#,
        #"(?is)-moz-binding\s*:[^;]+;?"#,
      ] {
        let before = cleaned
        cleaned = try replace(pattern, in: cleaned, with: "")
        if cleaned != before { removed.insert("unsafe-css") }
      }
      html = html.replacingOccurrences(of: block, with: cleaned)
    }
    let beforeInlineStyle = html
    html = try replace(
      #"(?is)\s+style\s*=\s*("[^"]*(?:url\s*\(|expression\s*\(|@import)[^"]*"|'[^']*(?:url\s*\(|expression\s*\(|@import)[^']*')"#,
      in: html, with: "")
    if html != beforeInlineStyle { removed.insert("unsafe-inline-css") }

    let csp = Self.contentSecurityPolicy
    let cspTag =
      #"<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\#(escapeAttribute(csp))">"#
    if let headRange = html.range(of: #"(?i)<head\b[^>]*>"#, options: .regularExpression) {
      html.insert(contentsOf: "\n  \(cspTag)", at: headRange.upperBound)
    } else {
      html = "<!doctype html><html><head>\(cspTag)</head><body>\(html)</body></html>"
      removed.insert("missing-document-shell-repaired")
    }
    return SanitizedReview(
      html: html,
      report: ReviewSanitizationReport(
        removedConstructs: removed.sorted(),
        preservedConfirmedExternalLinks: preserved.sorted(), csp: csp))
  }

  private func rewriteAttribute(
    _ name: String, in source: String, transform: (String) -> String?
  ) throws -> String {
    let pattern = #"(?is)\s+\#(name)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = source as NSString
    var result = source
    for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
      let valueRange = [2, 3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }
      guard let valueRange else { continue }
      let value = ns.substring(with: valueRange)
      let replacement = transform(value).map { " \(name)=\"\(escapeAttribute($0))\"" } ?? ""
      if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
    }
    return result
  }

  private func annotateApprovedExternalLinks(_ source: String) throws -> String {
    try replace(
      #"(?is)<a\b((?:(?!data-external-confirmation)[^>])*)href="(https://(?:doi\.org/|imec-publications\.be/)[^"]+)"([^>]*)>"#,
      in: source, with: #"<a$1href="$2" data-external-confirmation="required"$3>"#)
  }

  private func isSafeLocalResource(_ value: String, requiredPrefix: String?) -> Bool {
    let decoded = value.removingPercentEncoding ?? value
    guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("\\"),
      !decoded.contains(".."), !decoded.contains(":"), !decoded.contains("\\"),
      !decoded.contains("\u{0000}")
    else { return false }
    if let requiredPrefix { return decoded.hasPrefix(requiredPrefix) }
    return !decoded.contains("/")
  }

  private func isApprovedExternalLink(_ value: String) -> Bool {
    value.range(
      of: #"^https://(?:doi\.org/|imec-publications\.be/)"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func replace(
    _ pattern: String, in source: String, with replacement: String
  ) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.stringByReplacingMatches(
      in: source, range: NSRange(source.startIndex..., in: source), withTemplate: replacement)
  }

  private func matches(_ pattern: String, in source: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
      guard let range = Range($0.range(at: 1), in: source) else { return nil }
      return String(source[range])
    }
  }

  private func escapeAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
  }
}
