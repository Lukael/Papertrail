import Foundation

public struct ReviewPaperRecord: Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let sourceRelativePath: String
  public let sourceSHA256: String
  public let selectedReviewVersionID: UUID?
  public let automaticReviewRequiredAt: Date?
  public let automaticReviewCompletedAt: Date?

  public var automaticReviewRequired: Bool {
    automaticReviewRequiredAt != nil && automaticReviewCompletedAt == nil
  }
}

public struct ReviewSessionRecord: Equatable, Sendable {
  public let id: UUID
  public let externalThreadID: String?
  public let workspaceRelativePath: String
}

public struct ReviewGenerationRecord: Equatable, Sendable {
  public let id: UUID
  public let paperID: UUID
  public let sessionID: UUID
  public let operationID: UUID?
  public let workspaceRelativePath: String
  public let reviewVersionID: UUID?
  public let reviewRelativePath: String?
  public let predecessorGenerationID: UUID?
  public let createdAt: Date
  public let processOutcome: ProcessOutcome
  public let structuralValidation: StructuralValidationState
  public let evidenceReportState: EvidenceReportState
  public let qualityVerification: QualityVerificationState
  public let promotionPhase: ReviewPromotionPhase
  public let promotionVersionID: UUID?
  public let promotionRelativePath: String?
  public let promotionManifestSHA256: String?
  public let promotionAutoSelect: Bool

  public var label: String {
    if qualityVerification == .verified { return ReviewQualityLabel.qualityVerified.rawValue }
    if processOutcome == .turnCompleted && structuralValidation == .passed {
      return ReviewQualityLabel.generatedStructureChecked.rawValue
    }
    if structuralValidation == .failed { return ReviewQualityLabel.generatedStructureFailed.rawValue }
    return processOutcome.rawValue
  }

  public var isSelectable: Bool {
    processOutcome == .turnCompleted && structuralValidation == .passed
      && reviewVersionID != nil && reviewRelativePath != nil
  }
}

/// A concise, app-owned projection of a review turn for the paper chat transcript.
/// The complete production prompt remains in the private generation workspace and
/// in the Codex thread; the transcript only needs enough context to make the
/// shared review/chat conversation understandable without duplicating it.
public enum ReviewChatProjection {
  public static func request(paperTitle: String) -> String {
    let normalized = paperTitle.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    let title = String(normalized.prefix(512))
    return "Generate a Papertrail document for “\(title)” from the paper and completed conversation captured when generation was requested. Keep paper evidence separate from discussion interpretations, hypotheses, and open questions."
  }

  public static let completedFallback =
    "Review generation completed. Papertrail is validating and preparing the generated review."
}

public enum ReviewGenerationStoreError: Error, Equatable {
  case paperNotFound
  case generationNotFound
  case generationAlreadyExists
  case invalidPaperPath
  case invalidTransition
  case crossPaperReference
  case reviewNotSelectable
  case versionAlreadyExists
}

public protocol ReviewGenerationStore: Sendable {
  func paper(id: UUID) throws -> ReviewPaperRecord
  func currentSession(paperID: UUID) throws -> ReviewSessionRecord?
  func markAutomaticReviewCompleted(paperID: UUID) throws
  func createGeneration(
    generationID: UUID, paperID: UUID, sessionID: UUID, operationID: UUID,
    workspaceRelativePath: String, sessionWorkspaceRelativePath: String,
    promptSHA256: String, journalRelativePath: String,
    predecessorGenerationID: UUID?
  ) throws -> ReviewSessionRecord
  func recordProcessResult(generationID: UUID, result: CodexTransportResult) throws
  func recordPreparationFailure(generationID: UUID, outcome: ProcessOutcome) throws
  func transitionProcess(generationID: UUID, to: ProcessOutcome) throws
  func transitionStructure(generationID: UUID, to: StructuralValidationState) throws
  func transitionEvidence(generationID: UUID, to: EvidenceReportState) throws
  func transitionQuality(
    versionID: UUID, to: QualityVerificationState, verifier: String?,
    evidenceReferencesJSON: String
  ) throws
  func beginPromotion(
    generationID: UUID, versionID: UUID, reviewRelativePath: String,
    manifestSHA256: String, autoSelect: Bool
  ) throws
  func markPromotionFilesMoved(generationID: UUID) throws
  func commitPromotion(generationID: UUID, applySelection: Bool) throws
  func recoverPromotion(generationID: UUID) throws
  func markPromotionPhase(generationID: UUID, phase: ReviewPromotionPhase) throws
  func select(paperID: UUID, versionID: UUID) throws
  func generations(paperID: UUID) throws -> [ReviewGenerationRecord]
  func reconcileInterruptedGenerations() throws -> [UUID]
}
