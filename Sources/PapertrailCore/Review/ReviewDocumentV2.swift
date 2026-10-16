import Foundation

/// A journal-club presentation about one paper: slides with on-slide points and a speaker
/// script, grounded in verified page excerpts. Version 1 (a sectioned review) is no longer
/// generated; its promoted HTML stays readable because pages are rendered once and stored.
public struct ReviewDocumentV2: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let title: String
  public let slides: [ReviewSlide]
  public let evidence: [ReviewEvidence]
  /// Conversation-derived notes kept separate from claims verified against the paper.
  public let discussion: [ReviewDiscussionNote]?

  public init(
    schemaVersion: Int = 2,
    title: String,
    slides: [ReviewSlide],
    evidence: [ReviewEvidence],
    discussion: [ReviewDiscussionNote]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.slides = slides
    self.evidence = evidence
    self.discussion = discussion
  }
}

/// How a slide's points relate to the paper.
public enum ReviewSlideKind: String, Codable, Equatable, Sendable {
  /// Content stated in the paper; every point needs evidence.
  case paper
  /// Reviewer critique of the paper; points may cite evidence.
  case critique
  /// Questions for discussion; points may cite evidence.
  case questions
}

public struct ReviewSlide: Codable, Equatable, Sendable {
  public let id: String
  public let kind: ReviewSlideKind
  public let title: String
  /// Short on-slide bullets.
  public let points: [EvidenceLinkedStatement]
  /// Figures or tables the slide is about, located by their caption evidence.
  public let figures: [ReviewFigureReference]
  /// Key equations, reconstructed as LaTeX and located by the text that introduces them.
  public let equations: [ReviewEquation]
  /// What the presenter says for this slide.
  public let script: String
  /// Audience questions the presenter should be ready for.
  public let qa: [ReviewSlideQuestion]

  public init(
    id: String, kind: ReviewSlideKind, title: String, points: [EvidenceLinkedStatement],
    figures: [ReviewFigureReference] = [], equations: [ReviewEquation] = [], script: String,
    qa: [ReviewSlideQuestion] = []
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.points = points
    self.figures = figures
    self.equations = equations
    self.script = script
    self.qa = qa
  }
}

public struct ReviewFigureReference: Codable, Equatable, Sendable {
  public let id: String
  /// The paper's own label, such as "Fig. 3" or "Table 2".
  public let label: String
  /// What the figure shows, how to read it, and its takeaway.
  public let description: String
  public let evidenceIDs: [String]

  public init(id: String, label: String, description: String, evidenceIDs: [String]) {
    self.id = id
    self.label = label
    self.description = description
    self.evidenceIDs = evidenceIDs
  }
}

/// An equation card. PDF text extraction garbles typeset math, so `latex` is Claude's
/// reconstruction; the evidence is the running text that introduces or explains it.
public struct ReviewEquation: Codable, Equatable, Sendable {
  public let id: String
  /// The paper's own label, such as "Eq. 4".
  public let label: String
  public let latex: String
  /// What the equation computes and its role in the method.
  public let meaning: String
  public let variables: [ReviewEquationVariable]
  public let evidenceIDs: [String]

  public init(
    id: String, label: String, latex: String, meaning: String,
    variables: [ReviewEquationVariable], evidenceIDs: [String]
  ) {
    self.id = id
    self.label = label
    self.latex = latex
    self.meaning = meaning
    self.variables = variables
    self.evidenceIDs = evidenceIDs
  }
}

public struct ReviewEquationVariable: Codable, Equatable, Sendable {
  /// LaTeX for the symbol, such as "\\hat{x}".
  public let symbol: String
  public let meaning: String

  public init(symbol: String, meaning: String) {
    self.symbol = symbol
    self.meaning = meaning
  }
}

public struct ReviewSlideQuestion: Codable, Equatable, Sendable {
  public let question: String
  public let answer: String

  public init(question: String, answer: String) {
    self.question = question
    self.answer = answer
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
