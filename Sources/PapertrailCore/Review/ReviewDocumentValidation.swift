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

  public func decode(_ data: Data) throws -> ReviewDocumentV1 {
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
      let document = try JSONDecoder().decode(ReviewDocumentV1.self, from: data)
      guard document.schemaVersion == 1 else {
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
    _ document: ReviewDocumentV1, pageTexts: [String],
    conversationMessageIDs: Set<String>? = nil
  ) -> StructuredReviewValidationReport {
    var collector = FindingCollector()
    collector.require(document.schemaVersion == 1, "schema-version", "schemaVersion", "Schema version must be 1")
    collector.prose(document.title, at: "title", maximumBytes: 1024)

    let statements = statementRecords(document)
    let steps = document.method.pipeline.enumerated().map { index, value in
      ClaimRecord(
        id: value.id, path: "method.pipeline[\(index)]", evidenceIDs: value.evidenceIDs,
        prose: [("input", value.input), ("process", value.process), ("output", value.output)],
        evidenceRequired: true)
    }
    let experiments = experimentRecords(document)
    let concerns = concernRecords(document)
    let claims = statements + steps + experiments + concerns

    collector.require(!document.method.pipeline.isEmpty, "pipeline-empty", "method.pipeline", "At least one method step is required")
    collector.maximum(document.method.pipeline.count, 32, at: "method.pipeline")
    collector.maximum(document.method.assumptions.count, 32, at: "method.assumptions")
    collector.require(!document.contributions.isEmpty, "contributions-empty", "contributions", "At least one contribution is required")
    collector.maximum(document.contributions.count, 32, at: "contributions")
    collector.maximum(document.followUpQuestions.count, 32, at: "followUpQuestions")
    collector.maximum(document.evidence.count, 256, at: "evidence")

    let discussion = document.discussion ?? []
    collector.maximum(discussion.count, 64, at: "discussion")
    if let conversationMessageIDs {
      collector.require(
        conversationMessageIDs.isEmpty || !discussion.isEmpty,
        "discussion-required", "discussion",
        "Discussion is required when the conversation contains messages")
    }
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

    switch document.experiments {
    case .reported(let items):
      collector.require(!items.isEmpty, "reported-empty", "experiments.items", "Reported experiments must not be empty")
      collector.maximum(items.count, 64, at: "experiments.items")
    case .notReported(let note):
      collector.prose(note, at: "experiments.note")
    }
    switch document.authorLimitations {
    case .reported(let items):
      collector.require(!items.isEmpty, "reported-empty", "authorLimitations.items", "Reported limitations must not be empty")
      collector.maximum(items.count, 32, at: "authorLimitations.items")
    case .notReported(let note):
      collector.prose(note, at: "authorLimitations.note")
    }
    switch document.reviewerConcerns {
    case .reported(let items):
      collector.require(!items.isEmpty, "reported-empty", "reviewerConcerns.items", "Reported concerns must not be empty")
      collector.maximum(items.count, 32, at: "reviewerConcerns.items")
    case .noSupportedConcern(let note):
      collector.prose(note, at: "reviewerConcerns.note")
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
    for (index, question) in document.followUpQuestions.enumerated() {
      collector.prose(question, at: "followUpQuestions[\(index)]")
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

    collector.require(
      document.contributions.contains { contribution in
        contribution.evidenceIDs.contains { id in
          guard let evidenceClass = evidenceByID[id]?.class else { return false }
          return evidenceClass == .authorStatement || evidenceClass == .directEvidence
        }
      },
      "unsupported-contributions", "contributions",
      "At least one contribution requires author-statement or direct evidence")
    collector.require(
      document.strongestSupportedConclusion.evidenceIDs.contains { id in
        guard let evidenceClass = evidenceByID[id]?.class else { return false }
        return evidenceClass == .authorStatement || evidenceClass == .directEvidence
      },
      "unsupported-conclusion", "strongestSupportedConclusion",
      "Strongest conclusion requires author-statement or direct evidence")

    return StructuredReviewValidationReport(
      validatorVersion: Self.validatorVersion,
      findings: collector.findings)
  }

  public func validateOrThrow(
    _ document: ReviewDocumentV1, pageTexts: [String],
    conversationMessageIDs: Set<String>? = nil
  ) throws {
    let report = validate(
      document, pageTexts: pageTexts, conversationMessageIDs: conversationMessageIDs)
    guard report.passed else { throw ReviewDocumentValidationError(report: report) }
  }

  public static func normalizeEvidenceText(_ text: String) -> String {
    let lineNormalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .precomposedStringWithCanonicalMapping
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
    return result
  }

  private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }

  private func statementRecords(_ document: ReviewDocumentV1) -> [ClaimRecord] {
    var records = [
      ClaimRecord(document.summary, path: "summary"),
      ClaimRecord(document.researchProblem, path: "researchProblem"),
      ClaimRecord(document.method.overview, path: "method.overview"),
      ClaimRecord(document.strongestSupportedConclusion, path: "strongestSupportedConclusion"),
    ]
    records += document.method.assumptions.enumerated().map { ClaimRecord($0.element, path: "method.assumptions[\($0.offset)]") }
    records += document.contributions.enumerated().map { ClaimRecord($0.element, path: "contributions[\($0.offset)]") }
    if case .reported(let items) = document.authorLimitations {
      records += items.enumerated().map { ClaimRecord($0.element, path: "authorLimitations.items[\($0.offset)]") }
    }
    return records
  }

  private func experimentRecords(_ document: ReviewDocumentV1) -> [ClaimRecord] {
    guard case .reported(let items) = document.experiments else { return [] }
    return items.enumerated().map { index, value in
      ClaimRecord(
        id: value.id, path: "experiments.items[\(index)]", evidenceIDs: value.evidenceIDs,
        prose: [("condition", value.condition), ("metric", value.metric), ("result", value.result)],
        evidenceRequired: true)
    }
  }

  private func concernRecords(_ document: ReviewDocumentV1) -> [ClaimRecord] {
    guard case .reported(let items) = document.reviewerConcerns else { return [] }
    return items.enumerated().map { index, value in
      ClaimRecord(
        id: value.id, path: "reviewerConcerns.items[\(index)]", evidenceIDs: value.evidenceIDs,
        prose: [
          ("affectedClaim", value.affectedClaim), ("concern", value.concern),
          ("whyItMatters", value.whyItMatters), ("unresolved", value.unresolved),
          ("resolvingCheck", value.resolvingCheck),
        ], evidenceRequired: false)
    }
  }
}

private struct ClaimRecord {
  let id: String
  let path: String
  let evidenceIDs: [String]
  let prose: [(String, String)]
  let evidenceRequired: Bool

  init(_ statement: EvidenceLinkedStatement, path: String) {
    id = statement.id
    self.path = path
    evidenceIDs = statement.evidenceIDs
    prose = [("text", statement.text)]
    evidenceRequired = true
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
    let root = try object(value, at: "$", keys: [
      "schemaVersion", "title", "summary", "researchProblem", "method", "contributions",
      "experiments", "authorLimitations", "reviewerConcerns",
      "strongestSupportedConclusion", "followUpQuestions", "evidence", "discussion",
    ], optional: ["discussion"])
    try scalar(root["schemaVersion"], at: "$.schemaVersion", as: NSNumber.self)
    try scalar(root["title"], at: "$.title", as: String.self)
    try statement(root["summary"], "$.summary")
    try statement(root["researchProblem"], "$.researchProblem")
    let method = try object(root["method"], at: "$.method", keys: ["overview", "pipeline", "assumptions"])
    try statement(method["overview"], "$.method.overview")
    try array(method["pipeline"], at: "$.method.pipeline", each: methodStep)
    try array(method["assumptions"], at: "$.method.assumptions", each: statement)
    try array(root["contributions"], at: "$.contributions", each: statement)
    try tagged(root["experiments"], at: "$.experiments", item: experiment, absentStatus: "notReported")
    try tagged(root["authorLimitations"], at: "$.authorLimitations", item: statement, absentStatus: "notReported")
    try tagged(root["reviewerConcerns"], at: "$.reviewerConcerns", item: concern, absentStatus: "noSupportedConcern")
    try statement(root["strongestSupportedConclusion"], "$.strongestSupportedConclusion")
    try array(root["followUpQuestions"], at: "$.followUpQuestions") { value, path in
      try scalar(value, at: path, as: String.self)
    }
    try array(root["evidence"], at: "$.evidence", each: evidence)
    if root["discussion"] != nil {
      try array(root["discussion"], at: "$.discussion", each: discussionNote)
    }
  }

  private static func statement(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "text", "evidenceIDs"])
    try string(item["id"], "\(path).id")
    try string(item["text"], "\(path).text")
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func methodStep(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "input", "process", "output", "evidenceIDs"])
    for key in ["id", "input", "process", "output"] { try string(item[key], "\(path).\(key)") }
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func experiment(_ value: Any?, _ path: String) throws {
    let item = try object(value, at: path, keys: ["id", "condition", "metric", "result", "evidenceIDs"])
    for key in ["id", "condition", "metric", "result"] { try string(item[key], "\(path).\(key)") }
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
  }

  private static func concern(_ value: Any?, _ path: String) throws {
    let proseKeys = ["id", "affectedClaim", "concern", "whyItMatters", "unresolved", "resolvingCheck"]
    let item = try object(value, at: path, keys: Set(proseKeys + ["evidenceIDs"]))
    for key in proseKeys { try string(item[key], "\(path).\(key)") }
    try strings(item["evidenceIDs"], "\(path).evidenceIDs")
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

  private static func tagged(
    _ value: Any?, at path: String, item: (Any?, String) throws -> Void,
    absentStatus: String
  ) throws {
    guard let raw = value as? [String: Any], let status = raw["status"] as? String else {
      throw ReviewDocumentDecodingError.wrongType(path: path, expected: "tagged object")
    }
    if status == "reported" {
      let object = try object(raw, at: path, keys: ["status", "items"])
      try array(object["items"], at: "\(path).items", each: item)
    } else if status == absentStatus {
      let object = try object(raw, at: path, keys: ["status", "note"])
      try string(object["note"], "\(path).note")
    } else {
      throw ReviewDocumentDecodingError.invalidTaggedUnion(path: path)
    }
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
