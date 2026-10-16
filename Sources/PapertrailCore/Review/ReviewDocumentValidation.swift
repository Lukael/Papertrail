import Foundation

public enum ReviewDocumentDecodingError: Error, Equatable, Sendable {
  case documentTooLarge(actual: Int, maximum: Int)
  case invalidUTF8
  case invalidJSON
  case wrongType(path: String, expected: String)
  case unexpectedKeys(path: String, keys: [String])
  case missingKeys(path: String, keys: [String])
  case invalidTaggedUnion(path: String)
  case unsupportedSchemaVersion(Int)
  case codableFailure(String)
}

public struct ReviewDocumentDecoder: Sendable {
  public static let maximumDocumentBytes = 512 * 1024

  public init() {}

  public func decode(_ data: Data) throws -> ReviewDocumentV2 {
    guard data.count <= Self.maximumDocumentBytes else {
      throw ReviewDocumentDecodingError.documentTooLarge(
        actual: data.count, maximum: Self.maximumDocumentBytes)
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw ReviewDocumentDecodingError.invalidUTF8
    }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ReviewDocumentDecodingError.invalidJSON
    }
    try StrictReviewJSONShape.validateRoot(object)

    do {
      let document = try JSONDecoder().decode(ReviewDocumentV2.self, from: data)
      guard document.schemaVersion == 2 else {
        throw ReviewDocumentDecodingError.unsupportedSchemaVersion(document.schemaVersion)
      }
      return document
    } catch let error as ReviewDocumentDecodingError {
      throw error
    } catch {
      throw ReviewDocumentDecodingError.codableFailure(String(describing: error))
    }
  }
}

extension ReviewDocumentDecoder {
  /// Whether returned JSON is a whole document rather than a correction patch.
  public static func isWholeDocument(_ data: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] != nil
  }

  public func decodePatch(_ data: Data) throws -> ReviewDocumentPatch {
    guard data.count <= Self.maximumDocumentBytes else {
      throw ReviewDocumentDecodingError.documentTooLarge(
        actual: data.count, maximum: Self.maximumDocumentBytes)
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ReviewDocumentDecodingError.invalidJSON
    }
    try StrictReviewJSONShape.validatePatch(object)
    do {
      return try JSONDecoder().decode(ReviewDocumentPatch.self, from: data)
    } catch {
      throw ReviewDocumentDecodingError.codableFailure(String(describing: error))
    }
  }
}

public struct StructuredReviewValidationFinding: Codable, Equatable, Sendable {
  public let code: String
  public let path: String
  public let message: String

  public init(code: String, path: String, message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}

public struct StructuredReviewValidationReport: Codable, Equatable, Sendable {
  public let validatorVersion: Int
  public let findings: [StructuredReviewValidationFinding]

  public var passed: Bool { findings.isEmpty }

  public init(validatorVersion: Int, findings: [StructuredReviewValidationFinding]) {
    self.validatorVersion = validatorVersion
    self.findings = findings
  }
}

public struct ReviewDocumentValidationError: Error, Equatable, Sendable {
  public let report: StructuredReviewValidationReport

  public init(report: StructuredReviewValidationReport) { self.report = report }
}

public struct ReviewDocumentValidator: Sendable {
  public static let validatorVersion = 1

  public init() {}

  public func validate(
    _ document: ReviewDocumentV2, pageTexts: [String],
    conversationMessageIDs: Set<String>? = nil
  ) -> StructuredReviewValidationReport {
    var collector = FindingCollector()
    collector.require(document.schemaVersion == 2, "schema-version", "schemaVersion", "Schema version must be 2")
    collector.prose(document.title, at: "title", maximumBytes: 1024)
    collector.require(!document.slides.isEmpty, "slides-empty", "slides", "At least one slide is required")
    collector.maximum(document.slides.count, 40, at: "slides")
    collector.maximum(document.evidence.count, 256, at: "evidence")

    var claims: [ClaimRecord] = []
    for (index, slide) in document.slides.enumerated() {
      let path = "slides[\(index)]"
      collector.identifier(slide.id, at: "\(path).id")
      collector.prose(slide.title, at: "\(path).title", maximumBytes: 1024)
      collector.prose(slide.script, at: "\(path).script")
      collector.require(!slide.points.isEmpty, "points-empty", "\(path).points", "A slide needs at least one point")
      collector.maximum(slide.points.count, 8, at: "\(path).points")
      collector.maximum(slide.figures.count, 6, at: "\(path).figures")
      collector.maximum(slide.equations.count, 4, at: "\(path).equations")
      collector.maximum(slide.qa.count, 6, at: "\(path).qa")
      for (qaIndex, item) in slide.qa.enumerated() {
        collector.prose(item.question, at: "\(path).qa[\(qaIndex)].question")
        collector.prose(item.answer, at: "\(path).qa[\(qaIndex)].answer")
      }
      claims += slide.points.enumerated().map {
        ClaimRecord(
          $0.element, path: "\(path).points[\($0.offset)]", evidenceRequired: slide.kind == .paper)
      }
      claims += slide.figures.enumerated().map { offset, figure in
        ClaimRecord(
          id: figure.id, path: "\(path).figures[\(offset)]", evidenceIDs: figure.evidenceIDs,
          prose: [("label", figure.label), ("description", figure.description)],
          evidenceRequired: true)
      }
      for (offset, equation) in slide.equations.enumerated() {
        let equationPath = "\(path).equations[\(offset)]"
        collector.latex(equation.latex, at: "\(equationPath).latex", maximumBytes: 2048)
        collector.maximum(equation.variables.count, 16, at: "\(equationPath).variables")
        for (variableIndex, variable) in equation.variables.enumerated() {
          let variablePath = "\(equationPath).variables[\(variableIndex)]"
          collector.latex(variable.symbol, at: "\(variablePath).symbol", maximumBytes: 256)
          collector.prose(variable.meaning, at: "\(variablePath).meaning")
        }
        claims.append(
          ClaimRecord(
            id: equation.id, path: equationPath, evidenceIDs: equation.evidenceIDs,
            prose: [("label", equation.label), ("meaning", equation.meaning)],
            evidenceRequired: true))
      }
    }
    collector.unique(document.slides.map(\.id), namespace: "slide")
    collector.require(
      document.slides.contains { $0.kind == .paper }, "paper-slide-required", "slides",
      "At least one paper slide is required")

    let discussion = document.discussion ?? []
    collector.maximum(discussion.count, 64, at: "discussion")
    for (index, note) in discussion.enumerated() {
      let path = "discussion[\(index)]"
      collector.prose(note.text, at: "\(path).text")
      collector.maximum(note.messageIDs.count, 32, at: "\(path).messageIDs")
      collector.require(
        !note.messageIDs.isEmpty, "message-reference-required", "\(path).messageIDs",
        "A discussion note must reference at least one conversation message")
      collector.uniqueReferences(note.messageIDs, at: "\(path).messageIDs")
      for messageID in note.messageIDs {
        collector.require(
          Self.isCanonicalLowercaseUUID(messageID), "invalid-message-id",
          "\(path).messageIDs", "Message ID must be a canonical lowercase UUID")
        if let conversationMessageIDs {
          collector.require(
            conversationMessageIDs.contains(messageID), "unknown-message",
            "\(path).messageIDs", "Unknown conversation message ID: \(messageID)")
        }
      }
    }

    for record in claims {
      collector.identifier(record.id, at: "\(record.path).id")
      collector.maximum(record.evidenceIDs.count, 16, at: "\(record.path).evidenceIDs")
      collector.uniqueReferences(record.evidenceIDs, at: "\(record.path).evidenceIDs")
      collector.require(
        !record.evidenceRequired || !record.evidenceIDs.isEmpty,
        "evidence-required", "\(record.path).evidenceIDs", "This claim requires evidence")
      for (field, value) in record.prose { collector.prose(value, at: "\(record.path).\(field)") }
    }

    let claimIDs = claims.map(\.id)
    collector.unique(claimIDs, namespace: "claim")
    let evidenceIDs = document.evidence.map(\.id)
    collector.unique(evidenceIDs, namespace: "evidence")
    let claimIDSet = Set(claimIDs)
    let evidenceIDSet = Set(evidenceIDs)
    let claimsByID = claims.reduce(into: [String: ClaimRecord]()) { result, record in
      if result[record.id] == nil { result[record.id] = record }
    }
    let evidenceByID = document.evidence.reduce(into: [String: ReviewEvidence]()) { result, item in
      if result[item.id] == nil { result[item.id] = item }
    }

    for record in claims {
      for evidenceID in record.evidenceIDs {
        collector.require(evidenceIDSet.contains(evidenceID), "unknown-evidence", "\(record.path).evidenceIDs", "Unknown evidence ID: \(evidenceID)")
        if let evidence = evidenceByID[evidenceID] {
          collector.require(evidence.supports.contains(record.id), "reference-mismatch", "evidence[\(evidenceID)].supports", "Evidence does not support claim \(record.id)")
        }
      }
    }

    for (index, evidence) in document.evidence.enumerated() {
      let path = "evidence[\(index)]"
      collector.identifier(evidence.id, at: "\(path).id")
      collector.prose(evidence.exactExcerpt, at: "\(path).exactExcerpt", maximumBytes: 4096)
      if let locator = evidence.printedLocator {
        collector.prose(locator, at: "\(path).printedLocator", maximumBytes: 256)
      }
      collector.maximum(evidence.supports.count, 16, at: "\(path).supports")
      collector.uniqueReferences(evidence.supports, at: "\(path).supports")
      collector.require((1...pageTexts.count).contains(evidence.pageIndex), "page-out-of-range", "\(path).pageIndex", "Page index is outside extracted text")
      for claimID in evidence.supports {
        collector.require(claimIDSet.contains(claimID), "unknown-claim", "\(path).supports", "Unknown claim ID: \(claimID)")
        if let claim = claimsByID[claimID] {
          collector.require(claim.evidenceIDs.contains(evidence.id), "reference-mismatch", "\(path).supports", "Claim does not reference evidence \(evidence.id)")
        }
      }
      if (1...pageTexts.count).contains(evidence.pageIndex) {
        let excerpt = Self.normalizeEvidenceText(evidence.exactExcerpt)
        let page = Self.normalizeEvidenceText(pageTexts[evidence.pageIndex - 1])
        collector.require(!excerpt.isEmpty && page.contains(excerpt), "excerpt-not-found", "\(path).exactExcerpt", "Excerpt is not present on the declared page")
      }
    }

    // A paper slide may not rest only on interpretation or unresolved passages.
    for (index, slide) in document.slides.enumerated() where slide.kind == .paper {
      collector.require(
        slide.points.contains { point in
          point.evidenceIDs.contains { id in
            guard let evidenceClass = evidenceByID[id]?.class else { return false }
            return evidenceClass == .authorStatement || evidenceClass == .directEvidence
          }
        },
        "unsupported-slide", "slides[\(index)].points",
        "A paper slide requires at least one point with author-statement or direct evidence")
    }

    return StructuredReviewValidationReport(
      validatorVersion: Self.validatorVersion,
      findings: collector.findings)
  }

  public func validateOrThrow(
    _ document: ReviewDocumentV2, pageTexts: [String],
    conversationMessageIDs: Set<String>? = nil
  ) throws {
    let report = validate(
      document, pageTexts: pageTexts, conversationMessageIDs: conversationMessageIDs)
    guard report.passed else { throw ReviewDocumentValidationError(report: report) }
  }

  /// Compares excerpts the way a reader would: whitespace runs, ligatures (NFKC), soft hyphens,
  /// and hyphens between letters, including PDF line-end breaks such as "fol-\nlowed", are ignored.
  public static func normalizeEvidenceText(_ text: String) -> String {
    let lineNormalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .precomposedStringWithCompatibilityMapping
    var result = ""
    var inWhitespace = false
    for scalar in lineNormalized.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if !result.isEmpty { inWhitespace = true }
      } else {
        if inWhitespace { result.append(" ") }
        result.unicodeScalars.append(scalar)
        inWhitespace = false
      }
    }
    return result.replacingOccurrences(
      of: #"(?<=\p{L})[-\x{2010}\x{2011}] ?(?=\p{L})"#, with: "", options: .regularExpression)
  }

  private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }
}

private struct ClaimRecord {
  let id: String
  let path: String
  let evidenceIDs: [String]
  let prose: [(String, String)]
  let evidenceRequired: Bool

  init(_ statement: EvidenceLinkedStatement, path: String, evidenceRequired: Bool) {
    id = statement.id
    self.path = path
    evidenceIDs = statement.evidenceIDs
    prose = [("text", statement.text)]
    self.evidenceRequired = evidenceRequired
  }

  init(
    id: String, path: String, evidenceIDs: [String], prose: [(String, String)],
    evidenceRequired: Bool
  ) {
    self.id = id
    self.path = path
    self.evidenceIDs = evidenceIDs
    self.prose = prose
    self.evidenceRequired = evidenceRequired
  }
}

private struct FindingCollector {
  var findings: [StructuredReviewValidationFinding] = []

  mutating func require(_ condition: Bool, _ code: String, _ path: String, _ message: String) {
    if !condition { findings.append(.init(code: code, path: path, message: message)) }
  }

  mutating func maximum(_ actual: Int, _ maximum: Int, at path: String) {
    require(actual <= maximum, "collection-too-large", path, "Maximum count is \(maximum); found \(actual)")
  }

  mutating func identifier(_ value: String, at path: String) {
    let scalars = value.unicodeScalars
    let firstValid = scalars.first.map { $0.value >= 97 && $0.value <= 122 } ?? false
    let restValid = scalars.dropFirst().allSatisfy {
      ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57)
        || $0 == "_" || $0 == "-"
    }
    require(firstValid && restValid && scalars.count <= 64, "invalid-id", path, "ID must match [a-z][a-z0-9_-]{0,63}")
  }

  mutating func prose(_ value: String, at path: String, maximumBytes: Int = 16 * 1024) {
    require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty-prose", path, "Value must not be empty")
    require(value.utf8.count <= maximumBytes, "prose-too-large", path, "Maximum UTF-8 size is \(maximumBytes) bytes")
    require(!containsForbiddenControl(value), "control-character", path, "Value contains a forbidden control character")
    require(!containsUnsafeContent(value), "unsafe-content", path, "Markup, remote URLs, and absolute paths are forbidden")
  }

  /// LaTeX is never placed in the page as markup (it is rendered to MathML or escaped), so only
  /// size and control characters are checked; `<` and `>` are ordinary math.
  mutating func latex(_ value: String, at path: String, maximumBytes: Int) {
    require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty-prose", path, "Value must not be empty")
    require(value.utf8.count <= maximumBytes, "prose-too-large", path, "Maximum UTF-8 size is \(maximumBytes) bytes")
    require(!containsForbiddenControl(value), "control-character", path, "Value contains a forbidden control character")
  }

  mutating func unique(_ values: [String], namespace: String) {
    var seen = Set<String>()
    for value in values where !seen.insert(value).inserted {
      findings.append(.init(code: "duplicate-id", path: namespace, message: "Duplicate ID: \(value)"))
    }
  }

  mutating func uniqueReferences(_ values: [String], at path: String) {
    var seen = Set<String>()
    for value in values where !seen.insert(value).inserted {
      findings.append(.init(code: "duplicate-reference", path: path, message: "Duplicate reference: \(value)"))
    }
  }

  private func containsForbiddenControl(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      scalar.value == 0 || (scalar.value < 32 && scalar != "\t" && scalar != "\n") || scalar.value == 127
    }
  }

  private func containsUnsafeContent(_ value: String) -> Bool {
    let lower = value.lowercased()
    if lower.contains("<script") || lower.contains("</") || lower.contains("javascript:")
      || lower.contains("data:text/html") || lower.contains("http://") || lower.contains("https://")
      || lower.contains("www.") || lower.contains("mailto:") || lower.contains("ftp://")
    { return true }
    if value.range(of: #"<[^>]+>"#, options: .regularExpression) != nil { return true }
    if value.range(of: #"(?i)\bon[a-z0-9_-]+\s*="#, options: .regularExpression) != nil { return true }
    if value.range(of: #"(?i)(?:^|\s)[a-z]:\\[^\s]+"#, options: .regularExpression) != nil { return true }
    return value.range(
      of: #"(?:^|[\s(\"'=])/(?:[^/\s]+/)+[^/\s]+"#, options: .regularExpression) != nil
  }
}

private enum StrictReviewJSONShape {
  static func validateRoot(_ value: Any) throws {
    let root = try object(
      value, at: "$", keys: ["schemaVersion", "title", "slides", "evidence", "discussion"],
      optional: ["discussion"])
    try scalar(root["schemaVersion"], at: "$.schemaVersion", as: NSNumber.self)
    try scalar(root["title"], at: "$.title", as: String.self)
    try array(root["slides"], at: "$.slides", each: slide)
    try array(root["evidence"], at: "$.evidence", each: evidence)
    if root["discussion"] != nil {
      try array(root["discussion"], at: "$.discussion", each: discussionNote)
    }
  }

  static func validatePatch(_ value: Any) throws {
    let root = try object(value, at: "$", keys: ["replace", "remove"], optional: ["replace", "remove"])
    if let replace = root["replace"] {
      let keys: Set<String> = ["evidence", "points", "figures", "equations"]
      let item = try object(replace, at: "$.replace", keys: keys, optional: keys)
      if item["evidence"] != nil { try array(item["evidence"], at: "$.replace.evidence", each: evidence) }
      if item["points"] != nil { try array(item["points"], at: "$.replace.points", each: statement) }
      if item["figures"] != nil { try array(item["figures"], at: "$.replace.figures", each: figure) }
      if item["equations"] != nil {
        try array(item["equations"], at: "$.replace.equations", each: equation)
      }
    }
    if let remove = root["remove"] {
      let keys: Set<String> = ["evidence", "points", "figures", "equations", "slides"]
      let item = try object(remove, at: "$.remove", keys: keys, optional: keys)
      for key in keys.sorted() where item[key] != nil { try strings(item[key], "$.remove.\(key)") }
    }
  }

  private static func slide(_ value: Any?, _ path: String) throws {
    let item = try object(
      value, at: path,
      keys: ["id", "kind", "title", "points", "figures", "equations", "script", "qa"])
    for key in ["id", "kind", "title", "script"] { try string(item[key], "\(path).\(key)") }
    try array(item["points"], at: "\(path).points", each: statement)
    try array(item["figures"], at: "\(path).figures", each: figure)
    try array(item["equations"], at: "\(path).equations", each: equation)
    try array(item["qa"], at: "\(path).qa", each: question)
  }

  private static func statement(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "text", "evidenceIDs"])
    try string(item["id"], "\(path).id")
    try string(item["text"], "\(path).text")
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func figure(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "label", "description", "evidenceIDs"])
    for key in ["id", "label", "description"] { try string(item[key], "\(path).\(key)") }
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func equation(_ value: Any?, _ path: String) throws {
    let item = try object(
      value, at: path, keys: ["id", "label", "latex", "meaning", "variables", "evidenceIDs"])
    for key in ["id", "label", "latex", "meaning"] { try string(item[key], "\(path).\(key)") }
    try array(item["variables"], at: "\(path).variables") { value, variablePath in
      let variable = try object(value, at: variablePath, keys: ["symbol", "meaning"])
      try string(variable["symbol"], "\(variablePath).symbol")
      try string(variable["meaning"], "\(variablePath).meaning")
    }
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func question(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["question", "answer"])
    try string(item["question"], "\(path).question")
    try string(item["answer"], "\(path).answer")
  }

  private static func evidence(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "pageIndex", "printedLocator", "class", "exactExcerpt", "supports"], optional: ["printedLocator"])
    try string(item["id"], "\(path).id")
    try scalar(item["pageIndex"], at: "\(path).pageIndex", as: NSNumber.self)
    if let locator = item["printedLocator"], !(locator is NSNull) { try string(locator, "\(path).printedLocator") }
    try string(item["class"], "\(path).class")
    try string(item["exactExcerpt"], "\(path).exactExcerpt")
    try strings(item["supports"], "\(path).supports")
  }

  private static func discussionNote(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["kind", "text", "messageIDs"])
    try string(item["kind"], "\(path).kind")
    try string(item["text"], "\(path).text")
    try strings(item["messageIDs"], "\(path).messageIDs")
  }

  private static func object(
    _ value: Any?, at path: String, keys: Set<String>, optional: Set<String> = []
  ) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
      throw ReviewDocumentDecodingError.wrongType(path: path, expected: "object")
    }
    let actual = Set(object.keys)
    let unknown = actual.subtracting(keys).sorted()
    if !unknown.isEmpty { throw ReviewDocumentDecodingError.unexpectedKeys(path: path, keys: unknown) }
    let missing = keys.subtracting(optional).subtracting(actual).sorted()
    if !missing.isEmpty { throw ReviewDocumentDecodingError.missingKeys(path: path, keys: missing) }
    return object
  }

  private static func array(
    _ value: Any?, at path: String, each: (Any?, String) throws -> Void
  ) throws {
    guard let values = value as? [Any] else {
      throw ReviewDocumentDecodingError.wrongType(path: path, expected: "array")
    }
    for (index, value) in values.enumerated() { try each(value, "\(path)[\(index)]") }
  }

  private static func strings(_ value: Any?, _ path: String) throws {
    try array(value, at: path) { value, itemPath in try string(value, itemPath) }
  }

  private static func string(_ value: Any?, _ path: String) throws {
    try scalar(value, at: path, as: String.self)
  }

  private static func scalar<T>(_ value: Any?, at path: String, as type: T.Type) throws {
    guard value is T else {
      throw ReviewDocumentDecodingError.wrongType(path: path, expected: String(describing: T.self))
    }
  }
}
