import Foundation

public struct ReviewDocumentV1: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let title: String
  public let summary: EvidenceLinkedStatement
  public let researchProblem: EvidenceLinkedStatement
  public let method: ReviewMethod
  public let contributions: [EvidenceLinkedStatement]
  public let experiments: ReportedExperiments
  public let authorLimitations: ReportedStatements
  public let reviewerConcerns: ReportedConcerns
  public let strongestSupportedConclusion: EvidenceLinkedStatement
  public let followUpQuestions: [String]
  public let evidence: [ReviewEvidence]
  /// Conversation-derived notes kept separate from claims verified against the paper.
  public let discussion: [ReviewDiscussionNote]?

  public init(
    schemaVersion: Int = 1,
    title: String,
    summary: EvidenceLinkedStatement,
    researchProblem: EvidenceLinkedStatement,
    method: ReviewMethod,
    contributions: [EvidenceLinkedStatement],
    experiments: ReportedExperiments,
    authorLimitations: ReportedStatements,
    reviewerConcerns: ReportedConcerns,
    strongestSupportedConclusion: EvidenceLinkedStatement,
    followUpQuestions: [String],
    evidence: [ReviewEvidence],
    discussion: [ReviewDiscussionNote]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.summary = summary
    self.researchProblem = researchProblem
    self.method = method
    self.contributions = contributions
    self.experiments = experiments
    self.authorLimitations = authorLimitations
    self.reviewerConcerns = reviewerConcerns
    self.strongestSupportedConclusion = strongestSupportedConclusion
    self.followUpQuestions = followUpQuestions
    self.evidence = evidence
    self.discussion = discussion
  }
}

/// A category that states how an item distilled from the paper conversation should be read.
public enum ReviewDiscussionKind: String, Codable, Equatable, Sendable {
  /// A question raised in the conversation.
  case question
  /// An interpretation discussed by the user and assistant rather than a verified paper fact.
  case interpretation
  /// A tentative explanation or prediction raised in the conversation.
  case hypothesis
  /// A question that remained unresolved when the review was generated.
  case openQuestion
}

/// A review note distilled from the conversation and linked back to its source messages.
public struct ReviewDiscussionNote: Codable, Equatable, Sendable {
  /// The epistemic category of the note.
  public let kind: ReviewDiscussionKind
  /// The concise Korean summary of the conversational point.
  public let text: String
  /// Canonical lowercase UUIDs of the snapshot messages supporting this note.
  public let messageIDs: [String]

  public init(kind: ReviewDiscussionKind, text: String, messageIDs: [String]) {
    self.kind = kind
    self.text = text
    self.messageIDs = messageIDs
  }
}

public struct EvidenceLinkedStatement: Codable, Equatable, Sendable {
  public let id: String
  public let text: String
  public let evidenceIDs: [String]

  public init(id: String, text: String, evidenceIDs: [String]) {
    self.id = id
    self.text = text
    self.evidenceIDs = evidenceIDs
  }
}

public struct ReviewMethod: Codable, Equatable, Sendable {
  public let overview: EvidenceLinkedStatement
  public let pipeline: [MethodStep]
  public let assumptions: [EvidenceLinkedStatement]

  public init(
    overview: EvidenceLinkedStatement,
    pipeline: [MethodStep],
    assumptions: [EvidenceLinkedStatement]
  ) {
    self.overview = overview
    self.pipeline = pipeline
    self.assumptions = assumptions
  }
}

public struct MethodStep: Codable, Equatable, Sendable {
  public let id: String
  public let input: String
  public let process: String
  public let output: String
  public let evidenceIDs: [String]

  public init(
    id: String, input: String, process: String, output: String, evidenceIDs: [String]
  ) {
    self.id = id
    self.input = input
    self.process = process
    self.output = output
    self.evidenceIDs = evidenceIDs
  }
}

public struct Experiment: Codable, Equatable, Sendable {
  public let id: String
  public let condition: String
  public let metric: String
  public let result: String
  public let evidenceIDs: [String]

  public init(
    id: String, condition: String, metric: String, result: String, evidenceIDs: [String]
  ) {
    self.id = id
    self.condition = condition
    self.metric = metric
    self.result = result
    self.evidenceIDs = evidenceIDs
  }
}

public struct ReviewerConcern: Codable, Equatable, Sendable {
  public let id: String
  public let affectedClaim: String
  public let concern: String
  public let whyItMatters: String
  public let unresolved: String
  public let resolvingCheck: String
  public let evidenceIDs: [String]

  public init(
    id: String,
    affectedClaim: String,
    concern: String,
    whyItMatters: String,
    unresolved: String,
    resolvingCheck: String,
    evidenceIDs: [String]
  ) {
    self.id = id
    self.affectedClaim = affectedClaim
    self.concern = concern
    self.whyItMatters = whyItMatters
    self.unresolved = unresolved
    self.resolvingCheck = resolvingCheck
    self.evidenceIDs = evidenceIDs
  }
}

public enum ReviewEvidenceClass: String, Codable, Equatable, Sendable {
  case authorStatement
  case directEvidence
  case interpretation
  case unresolved
}

public struct ReviewEvidence: Codable, Equatable, Sendable {
  public let id: String
  public let pageIndex: Int
  public let printedLocator: String?
  public let `class`: ReviewEvidenceClass
  public let exactExcerpt: String
  public let supports: [String]

  public init(
    id: String,
    pageIndex: Int,
    printedLocator: String? = nil,
    class: ReviewEvidenceClass,
    exactExcerpt: String,
    supports: [String]
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.printedLocator = printedLocator
    self.class = `class`
    self.exactExcerpt = exactExcerpt
    self.supports = supports
  }
}

public enum ReportedExperiments: Codable, Equatable, Sendable {
  case reported([Experiment])
  case notReported(note: String)

  private enum CodingKeys: String, CodingKey { case status, items, note }
  private enum Status: String, Codable { case reported, notReported }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .reported:
      guard container.contains(.items), !container.contains(.note) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "reported requires only items")
      }
      self = .reported(try container.decode([Experiment].self, forKey: .items))
    case .notReported:
      guard container.contains(.note), !container.contains(.items) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "notReported requires only note")
      }
      self = .notReported(note: try container.decode(String.self, forKey: .note))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .reported(let items):
      try container.encode(Status.reported, forKey: .status)
      try container.encode(items, forKey: .items)
    case .notReported(let note):
      try container.encode(Status.notReported, forKey: .status)
      try container.encode(note, forKey: .note)
    }
  }
}

public enum ReportedStatements: Codable, Equatable, Sendable {
  case reported([EvidenceLinkedStatement])
  case notReported(note: String)

  private enum CodingKeys: String, CodingKey { case status, items, note }
  private enum Status: String, Codable { case reported, notReported }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .reported:
      guard container.contains(.items), !container.contains(.note) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "reported requires only items")
      }
      self = .reported(try container.decode([EvidenceLinkedStatement].self, forKey: .items))
    case .notReported:
      guard container.contains(.note), !container.contains(.items) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "notReported requires only note")
      }
      self = .notReported(note: try container.decode(String.self, forKey: .note))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .reported(let items):
      try container.encode(Status.reported, forKey: .status)
      try container.encode(items, forKey: .items)
    case .notReported(let note):
      try container.encode(Status.notReported, forKey: .status)
      try container.encode(note, forKey: .note)
    }
  }
}

public enum ReportedConcerns: Codable, Equatable, Sendable {
  case reported([ReviewerConcern])
  case noSupportedConcern(note: String)

  private enum CodingKeys: String, CodingKey { case status, items, note }
  private enum Status: String, Codable { case reported, noSupportedConcern }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Status.self, forKey: .status) {
    case .reported:
      guard container.contains(.items), !container.contains(.note) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "reported requires only items")
      }
      self = .reported(try container.decode([ReviewerConcern].self, forKey: .items))
    case .noSupportedConcern:
      guard container.contains(.note), !container.contains(.items) else {
        throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "noSupportedConcern requires only note")
      }
      self = .noSupportedConcern(note: try container.decode(String.self, forKey: .note))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .reported(let items):
      try container.encode(Status.reported, forKey: .status)
      try container.encode(items, forKey: .items)
    case .noSupportedConcern(let note):
      try container.encode(Status.noSupportedConcern, forKey: .status)
      try container.encode(note, forKey: .note)
    }
  }
}
