import Foundation

public enum ReviewQualityLabel: String, Codable, Equatable, Sendable {
  case generatedStructureChecked = "Generated · structure checked"
  case generatedStructureFailed = "Generated · structure failed"
  case qualityVerified = "Quality verified"
}

public struct ReviewValidationFinding: Codable, Equatable, Sendable {
  public let code: String
  public let detail: String
}

public struct ReviewValidationReport: Codable, Equatable, Sendable {
  public let status: String
  public let label: String
  public let findings: [ReviewValidationFinding]
  public let checkedLocalResources: [String]
  public let independentSemanticOrVisualVerification: Bool

  public var passed: Bool { status == "passed" }
}

public struct ReviewFootnoteNormalizer: Sendable {
  public init() {}

  public func normalize(_ html: String) throws -> String {
    var normalized = html
    let referenceIDs = Set(try capture(#"(?is)\bid\s*=\s*["']r([0-9]+)["']"#, in: html))
    let footnoteIDs = Set(try capture(#"(?is)\bid\s*=\s*["']fn([0-9]+)["']"#, in: html))

    for number in footnoteIDs.subtracting(referenceIDs).sorted() {
      let pattern = #"(?is)<a\b(?=[^>]*\bhref\s*=\s*["']#fn\#(number)["'])(?![^>]*\bid\s*=)"#
      let regex = try NSRegularExpression(pattern: pattern)
      let searchRange = NSRange(normalized.startIndex..., in: normalized)
      guard let match = regex.firstMatch(in: normalized, range: searchRange),
        let range = Range(match.range, in: normalized)
      else { continue }
      normalized.replaceSubrange(range, with: #"<a id="r\#(number)""#)
    }

    let normalizedReferenceIDs = Set(
      try capture(#"(?is)\bid\s*=\s*["']r([0-9]+)["']"#, in: normalized))
    for number in normalizedReferenceIDs.sorted() {
      let returnPattern = #"(?is)id\s*=\s*["']fn\#(number)["'][\s\S]*?href\s*=\s*["']#r\#(number)["']"#
      if normalized.range(of: returnPattern, options: .regularExpression) != nil { continue }

      let footnoteOpeningPattern =
        #"(?is)<[a-z0-9]+\b(?=[^>]*\bid\s*=\s*["']fn\#(number)["'])[^>]*>"#
      let regex = try NSRegularExpression(pattern: footnoteOpeningPattern)
      let searchRange = NSRange(normalized.startIndex..., in: normalized)
      guard let match = regex.firstMatch(in: normalized, range: searchRange),
        let range = Range(match.range, in: normalized)
      else { continue }
      normalized.insert(
        contentsOf:
          "<a href=\"#r\(number)\" aria-label=\"Return to reference \(number)\">↩</a>",
        at: range.upperBound)
    }
    return normalized
  }

  private func capture(_ pattern: String, in source: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
      guard let range = Range($0.range(at: 1), in: source) else { return nil }
      return String(source[range])
    }
  }
}

public struct ReviewValidator: Sendable {
  public init() {}

  public func validate(reviewDirectory: URL, html: String, fileManager: FileManager = .default)
    throws -> ReviewValidationReport
  {
    var findings: [ReviewValidationFinding] = []
    var checkedResources: Set<String> = []
    func fail(_ code: String, _ detail: String) {
      findings.append(ReviewValidationFinding(code: code, detail: detail))
    }

    if html.range(of: #"(?s)\{\{.*?\}\}"#, options: .regularExpression) != nil {
      fail("placeholder", "Template placeholder remains")
    }
    if !html.contains(ReviewResourceSanitizer.contentSecurityPolicy.replacingOccurrences(of: "'", with: "&#39;"))
      && !html.contains(ReviewResourceSanitizer.contentSecurityPolicy)
    {
      fail("csp", "Required restrictive CSP is absent")
    }
    for pattern in [
      #"(?is)<(?:script|base|iframe|frame|form|input|button|object|embed|applet|audio|video|svg|img|image)\b"#,
      #"(?is)\son[a-z0-9_-]+\s*="#,
      #"(?is)\sbackground\s*="#,
      #"(?is)(?:src|srcset|poster)\s*=\s*["']\s*(?:https?:|file:|//|/|\.\.)"#,
      #"(?is)@import|@font-face|url\s*\(\s*["']?(?:https?:|file:|//|/|\.\.)"#,
      #"(?is)javascript:|data:text/html|data:image/"#,
    ] where html.range(of: pattern, options: .regularExpression) != nil {
      fail("forbidden-construct", pattern)
    }

    let ids = try capture(#"(?is)\bid\s*=\s*["']([^"']+)["']"#, in: html)
    let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    if !duplicates.isEmpty { fail("duplicate-id", duplicates.joined(separator: ",")) }
    let idSet = Set(ids)
    for fragment in try capture(#"(?is)\bhref\s*=\s*["']#([^"']+)["']"#, in: html)
    where !idSet.contains(fragment) {
      fail("broken-fragment", fragment)
    }

    for resource in try capture(
      #"(?is)\b(?:src|href)\s*=\s*["']([^"'#][^"']*)["']"#, in: html)
    {
      if resource.hasPrefix("https://") {
        if !html.contains("href=\"\(resource)\" data-external-confirmation=\"required\"") {
          fail("unconfirmed-external-link", resource)
        }
        continue
      }
      let decoded = resource.removingPercentEncoding ?? resource
      guard !decoded.hasPrefix("/"), !decoded.contains(".."), !decoded.contains(":"),
        !decoded.contains("\\")
      else {
        fail("unsafe-local-path", resource)
        continue
      }
      let target = reviewDirectory.appendingPathComponent(decoded).standardizedFileURL
      let root = reviewDirectory.standardizedFileURL.path + "/"
      guard target.path.hasPrefix(root), fileManager.fileExists(atPath: target.path) else {
        fail("missing-local-resource", resource)
        continue
      }
      if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        fail("symlink-local-resource", resource)
        continue
      }
      checkedResources.insert(resource)
    }

    let references = Set(try capture(#"(?is)\bid\s*=\s*["']r([0-9]+)["']"#, in: html))
    let footnotes = Set(try capture(#"(?is)\bid\s*=\s*["']fn([0-9]+)["']"#, in: html))
    if references != footnotes {
      fail("footnote-pairing", "When present, rN and fnN identifiers must be a one-to-one set")
    }
    for number in references where html.range(
      of: #"(?is)id\s*=\s*["']fn\#(number)["'][\s\S]*?href\s*=\s*["']#r\#(number)["']"#,
      options: .regularExpression) == nil
    {
      fail("footnote-return", "fn\(number) has no return to r\(number)")
    }
    return ReviewValidationReport(
      status: findings.isEmpty ? "passed" : "failed",
      label: findings.isEmpty
        ? ReviewQualityLabel.generatedStructureChecked.rawValue
        : ReviewQualityLabel.generatedStructureFailed.rawValue,
      findings: findings.sorted { ($0.code, $0.detail) < ($1.code, $1.detail) },
      checkedLocalResources: checkedResources.sorted(),
      independentSemanticOrVisualVerification: false)
  }

  private func capture(_ pattern: String, in source: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
      guard let range = Range($0.range(at: 1), in: source) else { return nil }
      return String(source[range])
    }
  }
}
