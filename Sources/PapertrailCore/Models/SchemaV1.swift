#if !PPR_PORTABLE_SCHEMA
  import Foundation
  import SwiftData

  public enum SessionPurpose: String, Codable, Sendable {
    case reviewGeneration
    case paperChat
  }

  public enum SessionLifecycle: String, Codable, Sendable {
    case staged
    case active
    case historical
    case failed
  }

  public enum PaperRepairState: String, Codable, Sendable {
    case none
    case currentChatPointerInvalid
    case legacyCurrentChatAmbiguous
    case sourceMissing
    case selectedReviewMissing
  }

  public enum ProcessOutcome: String, Codable, Sendable {
    case pending, running, turnCompleted, failed, cancelled, interrupted, protocolFailure
  }

  public enum StructuralValidationState: String, Codable, Sendable {
    case notRun, running, passed, failed
  }

  public enum EvidenceReportState: String, Codable, Sendable {
    case missing, produced, invalid
  }

  public enum QualityVerificationState: String, Codable, Sendable {
    case notPerformed, inProgress, verified, failed
  }
  public enum ReviewPromotionPhase: String, Codable, Sendable {
    case none, intentRecorded, filesMoved, committed, selected, recoveryRequired, quarantined
  }

  public enum PersonalPaperReviewSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
      [
        Paper.self, CodexSession.self, CodexOperation.self, ChatMessage.self,
        ReviewGeneration.self, ReviewEvidenceReport.self, QualityVerification.self,
      ]
    }

    @Model
    public final class Paper {
      @Attribute(.unique) public var id: UUID
      public var canonicalTitle: String
      public var safeBasename: String
      public var sourceRelativePath: String
      public var sourceSHA256: String
      public var bibliographicTitle: String?
      public var bibliographicAuthors: String?
      public var doi: String?
      public var readingPageIndex: Int
      public var readingScale: Double
      public var selectedReviewVersionID: UUID?
      public var currentChatSessionID: UUID?
      public var automaticReviewRequiredAt: Date?
      public var automaticReviewCompletedAt: Date?
      public var repairStateRawValue: String
      public var createdAt: Date
      public var updatedAt: Date

      public init(
        id: UUID = UUID(), canonicalTitle: String, safeBasename: String,
        sourceRelativePath: String, sourceSHA256: String, createdAt: Date = Date()
      ) {
        self.id = id
        self.canonicalTitle = canonicalTitle
        self.safeBasename = safeBasename
        self.sourceRelativePath = sourceRelativePath
        self.sourceSHA256 = sourceSHA256
        self.readingPageIndex = 0
        self.readingScale = 1
        self.repairStateRawValue = PaperRepairState.none.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
      }

      public var repairState: PaperRepairState {
        get { PaperRepairState(rawValue: repairStateRawValue) ?? .currentChatPointerInvalid }
        set { repairStateRawValue = newValue.rawValue }
      }
    }

    @Model
    public final class CodexSession {
      @Attribute(.unique) public var id: UUID
      public var paperID: UUID
      public var purposeRawValue: String
      public var purposeReferenceID: UUID?
      public var externalThreadID: String?
      public var workspaceRelativePath: String
      public var lifecycleRawValue: String
      public var createdAt: Date
      public var replacedAt: Date?
      public var predecessorSessionID: UUID?
      public var replacementSessionID: UUID?
      public var replacementReason: String?

      public init(
        id: UUID = UUID(), paperID: UUID, purpose: SessionPurpose,
        purposeReferenceID: UUID? = nil, workspaceRelativePath: String,
        lifecycle: SessionLifecycle = .staged, createdAt: Date = Date()
      ) {
        self.id = id
        self.paperID = paperID
        self.purposeRawValue = purpose.rawValue
        self.purposeReferenceID = purposeReferenceID
        self.workspaceRelativePath = workspaceRelativePath
        self.lifecycleRawValue = lifecycle.rawValue
        self.createdAt = createdAt
      }

      public var purpose: SessionPurpose {
        get { SessionPurpose(rawValue: purposeRawValue) ?? .paperChat }
        set { purposeRawValue = newValue.rawValue }
      }

      public var lifecycle: SessionLifecycle {
        get { SessionLifecycle(rawValue: lifecycleRawValue) ?? .failed }
        set { lifecycleRawValue = newValue.rawValue }
      }

      public func isCurrentChat(for paper: Paper) -> Bool {
        purpose == .paperChat && paper.id == paperID && paper.currentChatSessionID == id
      }
    }

    @Model
    public final class CodexOperation {
      @Attribute(.unique) public var id: UUID
      @Attribute(.unique) public var clientOperationID: UUID
      public var sessionID: UUID
      public var kindRawValue: String
      public var externalTurnID: String?
      public var externalItemID: String?
      public var promptSHA256: String
      public var startedAt: Date?
      public var endedAt: Date?
      public var processOutcomeRawValue: String
      public var exitCode: Int?
      public var signal: Int?
      public var terminalEventRawValue: String?
      public var retryPredecessorID: UUID?
      public var journalRelativePath: String

      public init(
        id: UUID = UUID(), clientOperationID: UUID = UUID(), sessionID: UUID,
        kind: String, promptSHA256: String, journalRelativePath: String
      ) {
        self.id = id
        self.clientOperationID = clientOperationID
        self.sessionID = sessionID
        self.kindRawValue = kind
        self.promptSHA256 = promptSHA256
        self.processOutcomeRawValue = ProcessOutcome.pending.rawValue
        self.journalRelativePath = journalRelativePath
      }
    }

    @Model
    public final class ChatMessage {
      @Attribute(.unique) public var id: UUID
      public var paperID: UUID
      public var sessionID: UUID
      public var operationID: UUID?
      public var roleRawValue: String
      public var committedContent: String
      public var draftContent: String?
      public var createdAt: Date
      public var updatedAt: Date
      public var deliveryStateRawValue: String

      public init(
        id: UUID = UUID(), paperID: UUID, sessionID: UUID, operationID: UUID? = nil,
        role: String, committedContent: String, deliveryState: String,
        createdAt: Date = Date()
      ) {
        self.id = id
        self.paperID = paperID
        self.sessionID = sessionID
        self.operationID = operationID
        self.roleRawValue = role
        self.committedContent = committedContent
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deliveryStateRawValue = deliveryState
      }
    }

    @Model
    public final class ReviewGeneration {
      @Attribute(.unique) public var id: UUID
      public var paperID: UUID
      public var sessionID: UUID
      public var operationID: UUID?
      public var workspaceRelativePath: String
      public var reviewVersionID: UUID?
      public var reviewRelativePath: String?
      public var predecessorGenerationID: UUID?
      public var processOutcomeRawValue: String
      public var structuralValidationRawValue: String
      public var evidenceReportStateRawValue: String
      public var promotionPhaseRawValue: String
      public var promotionVersionID: UUID?
      public var promotionRelativePath: String?
      public var promotionManifestSHA256: String?
      public var promotionAutoSelect: Bool
      public var createdAt: Date

      public init(
        id: UUID = UUID(), paperID: UUID, sessionID: UUID,
        workspaceRelativePath: String, predecessorGenerationID: UUID? = nil,
        createdAt: Date = Date()
      ) {
        self.id = id
        self.paperID = paperID
        self.sessionID = sessionID
        self.workspaceRelativePath = workspaceRelativePath
        self.predecessorGenerationID = predecessorGenerationID
        self.processOutcomeRawValue = ProcessOutcome.pending.rawValue
        self.structuralValidationRawValue = StructuralValidationState.notRun.rawValue
        self.evidenceReportStateRawValue = EvidenceReportState.missing.rawValue
        self.promotionPhaseRawValue = ReviewPromotionPhase.none.rawValue
        self.promotionAutoSelect = false
        self.createdAt = createdAt
      }

      public var isSelectable: Bool {
        processOutcomeRawValue == ProcessOutcome.turnCompleted.rawValue
          && structuralValidationRawValue == StructuralValidationState.passed.rawValue
          && reviewVersionID != nil && reviewRelativePath != nil
      }
    }

    @Model
    public final class ReviewEvidenceReport {
      @Attribute(.unique) public var id: UUID
      public var generationID: UUID
      public var reviewVersionID: UUID
      public var relativePath: String
      public var stateRawValue: String
      public var independentlyVerified: Bool
      public var createdAt: Date

      public init(
        id: UUID = UUID(), generationID: UUID, reviewVersionID: UUID,
        relativePath: String, state: EvidenceReportState, createdAt: Date = Date()
      ) {
        self.id = id
        self.generationID = generationID
        self.reviewVersionID = reviewVersionID
        self.relativePath = relativePath
        self.stateRawValue = state.rawValue
        self.independentlyVerified = false
        self.createdAt = createdAt
      }
    }

    @Model
    public final class QualityVerification {
      @Attribute(.unique) public var id: UUID
      public var generationID: UUID
      public var reviewVersionID: UUID
      public var stateRawValue: String
      public var verifier: String?
      public var verifiedAt: Date?
      public var evidenceReferencesJSON: String

      public init(
        id: UUID = UUID(), generationID: UUID, reviewVersionID: UUID,
        state: QualityVerificationState = .notPerformed
      ) {
        self.id = id
        self.generationID = generationID
        self.reviewVersionID = reviewVersionID
        self.stateRawValue = state.rawValue
        self.evidenceReferencesJSON = "[]"
      }
    }
  }

  public typealias Paper = PersonalPaperReviewSchemaV1.Paper
  public typealias CodexSession = PersonalPaperReviewSchemaV1.CodexSession
  public typealias CodexOperation = PersonalPaperReviewSchemaV1.CodexOperation
  public typealias ChatMessage = PersonalPaperReviewSchemaV1.ChatMessage
  public typealias ReviewGeneration = PersonalPaperReviewSchemaV1.ReviewGeneration
  public typealias ReviewEvidenceReport = PersonalPaperReviewSchemaV1.ReviewEvidenceReport
  public typealias QualityVerification = PersonalPaperReviewSchemaV1.QualityVerification

  public enum PersonalPaperReviewMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [PersonalPaperReviewSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
  }
#endif
