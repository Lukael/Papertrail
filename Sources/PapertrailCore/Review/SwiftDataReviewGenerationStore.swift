#if !PPR_PORTABLE_SCHEMA
  import Foundation
  import SwiftData

  public final class SwiftDataReviewGenerationStore: ReviewGenerationStore, @unchecked Sendable {
    private let container: ModelContainer
    public init(container: ModelContainer) { self.container = container }

    public func paper(id: UUID) throws -> ReviewPaperRecord {
      let context = ModelContext(container)
      guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == id })
      else { throw ReviewGenerationStoreError.paperNotFound }
      return ReviewPaperRecord(
        id: paper.id, title: paper.canonicalTitle, sourceRelativePath: paper.sourceRelativePath,
        sourceSHA256: paper.sourceSHA256, selectedReviewVersionID: paper.selectedReviewVersionID,
        automaticReviewRequiredAt: paper.automaticReviewRequiredAt,
        automaticReviewCompletedAt: paper.automaticReviewCompletedAt)
    }

    public func currentSession(paperID: UUID) throws -> ReviewSessionRecord? {
      let context = ModelContext(container)
      guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
        $0.id == paperID
      }) else { throw ReviewGenerationStoreError.paperNotFound }
      guard let sessionID = paper.currentChatSessionID else { return nil }
      guard let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: {
        $0.id == sessionID && $0.paperID == paperID && $0.purpose == .paperChat
          && $0.lifecycle == .active
      }) else { throw ReviewGenerationStoreError.crossPaperReference }
      return Self.sessionRecord(session)
    }

    public func markAutomaticReviewCompleted(paperID: UUID) throws {
      let context = ModelContext(container)
      guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
        $0.id == paperID
      }) else { throw ReviewGenerationStoreError.paperNotFound }
      guard paper.automaticReviewRequiredAt != nil else {
        throw ReviewGenerationStoreError.invalidTransition
      }
      if paper.automaticReviewCompletedAt == nil {
        paper.automaticReviewCompletedAt = Date()
        paper.updatedAt = Date()
        try context.save()
      }
    }

    public func createGeneration(
      generationID: UUID, paperID: UUID, sessionID: UUID, operationID: UUID,
      workspaceRelativePath: String, sessionWorkspaceRelativePath: String,
      promptSHA256: String, journalRelativePath: String,
      predecessorGenerationID: UUID?
    ) throws -> ReviewSessionRecord {
      let context = ModelContext(container)
      let papers = try context.fetch(FetchDescriptor<Paper>())
      let generations = try context.fetch(FetchDescriptor<ReviewGeneration>())
      let sessions = try context.fetch(FetchDescriptor<CodexSession>())
      let operations = try context.fetch(FetchDescriptor<CodexOperation>())
      guard let paper = papers.first(where: { $0.id == paperID }) else {
        throw ReviewGenerationStoreError.paperNotFound
      }
      guard !generations.contains(where: { $0.id == generationID }),
        !operations.contains(where: { $0.id == operationID })
      else { throw ReviewGenerationStoreError.generationAlreadyExists }
      if let predecessorGenerationID {
        guard generations.contains(where: {
          $0.id == predecessorGenerationID && $0.paperID == paperID
        }) else { throw ReviewGenerationStoreError.crossPaperReference }
      }
      let prefix = "Papers/\(paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/workspace/agent"
      guard workspaceRelativePath == prefix else { throw ReviewGenerationStoreError.invalidPaperPath }
      guard sessionWorkspaceRelativePath == workspaceRelativePath,
        !sessions.contains(where: { $0.id == sessionID })
      else { throw ReviewGenerationStoreError.generationAlreadyExists }
      let session = CodexSession(
        id: sessionID, paperID: paperID, purpose: .reviewGeneration,
        purposeReferenceID: generationID, workspaceRelativePath: workspaceRelativePath,
        lifecycle: .active)
      context.insert(session)
      let operation = CodexOperation(
        id: operationID, clientOperationID: operationID, sessionID: session.id,
        kind: "generateReview", promptSHA256: promptSHA256,
        journalRelativePath: journalRelativePath)
      operation.startedAt = Date()
      operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
      let requestMessage = ChatMessage(
        id: ChatMessageIdentity.reviewRequest(operationID: operationID),
        paperID: paperID, sessionID: session.id, operationID: operationID,
        role: "user", committedContent: ReviewChatProjection.request(paperTitle: paper.canonicalTitle),
        deliveryState: "queued")
      let generation = ReviewGeneration(
        id: generationID, paperID: paperID, sessionID: session.id,
        workspaceRelativePath: workspaceRelativePath,
        predecessorGenerationID: predecessorGenerationID)
      generation.operationID = operationID
      generation.processOutcomeRawValue = ProcessOutcome.running.rawValue
      context.insert(operation); context.insert(requestMessage); context.insert(generation)
      try context.save()
      return Self.sessionRecord(session)
    }

    public func recordProcessResult(generationID: UUID, result: CodexTransportResult) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }),
        let operationID = generation.operationID,
        let operation = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == operationID }),
        let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == generation.sessionID })
      else { throw ReviewGenerationStoreError.generationNotFound }
      guard generation.processOutcomeRawValue == ProcessOutcome.running.rawValue else {
        throw ReviewGenerationStoreError.invalidTransition
      }
      if let thread = result.state.externalThreadID {
        if let existing = session.externalThreadID, existing != thread {
          generation.processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
          operation.processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
          operation.endedAt = Date()
          try context.save()
          throw ReviewGenerationStoreError.invalidTransition
        }
        session.externalThreadID = thread
      }
      let outcome = Self.persisted(result.state.outcome)
      try ReviewStateMachine.validate(process: .running, to: outcome)
      generation.processOutcomeRawValue = outcome.rawValue
      operation.processOutcomeRawValue = outcome.rawValue
      operation.exitCode = Int(result.exitStatus)
      operation.terminalEventRawValue = result.state.terminalEvents.last
      operation.endedAt = Date()
      session.lifecycle = .active
      let existingMessages = try context.fetch(FetchDescriptor<ChatMessage>()).filter {
        $0.operationID == operationID
      }
      for message in existingMessages where message.roleRawValue == "user" {
        message.deliveryStateRawValue = outcome == .turnCompleted ? "committed" : outcome.rawValue
        message.updatedAt = Date()
      }
      let projectedMessages = result.state.messages.isEmpty && outcome == .turnCompleted
        ? [ProjectedMessage(
            itemID: "papertrail-review-completed", draft: nil,
            committed: ReviewChatProjection.completedFallback)]
        : result.state.messages
      for projected in projectedMessages {
        let message = ChatMessage(
          id: ChatMessageIdentity.assistant(operationID: operationID, itemID: projected.itemID),
          paperID: generation.paperID, sessionID: session.id, operationID: operationID,
          role: "assistant", committedContent: projected.committed ?? "",
          deliveryState: projected.committed == nil ? "draft" : "committed")
        message.draftContent = projected.draft
        context.insert(message)
      }
      try context.save()
    }

    public func recordPreparationFailure(generationID: UUID, outcome: ProcessOutcome) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID })
      else { throw ReviewGenerationStoreError.generationNotFound }
      guard generation.reviewVersionID == nil else { throw ReviewGenerationStoreError.invalidTransition }
      let current = ProcessOutcome(rawValue: generation.processOutcomeRawValue) ?? .protocolFailure
      try ReviewStateMachine.validate(process: current, to: outcome)
      generation.processOutcomeRawValue = outcome.rawValue
      if let operationID = generation.operationID,
        let operation = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == operationID })
      {
        operation.processOutcomeRawValue = outcome.rawValue; operation.endedAt = Date()
        for message in try context.fetch(FetchDescriptor<ChatMessage>())
        where message.operationID == operationID {
          message.deliveryStateRawValue = outcome.rawValue
          message.updatedAt = Date()
        }
      }
      try context.save()
    }

    public func transitionProcess(generationID: UUID, to: ProcessOutcome) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }) else { throw ReviewGenerationStoreError.generationNotFound }
      let from = ProcessOutcome(rawValue: generation.processOutcomeRawValue) ?? .protocolFailure
      try ReviewStateMachine.validate(process: from, to: to)
      generation.processOutcomeRawValue = to.rawValue
      if let operationID = generation.operationID,
        let operation = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == operationID })
      { operation.processOutcomeRawValue = to.rawValue; operation.endedAt = Date() }
      try context.save()
    }

    public func transitionStructure(generationID: UUID, to: StructuralValidationState) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }) else { throw ReviewGenerationStoreError.generationNotFound }
      let from = StructuralValidationState(rawValue: generation.structuralValidationRawValue) ?? .failed
      try ReviewStateMachine.validate(structure: from, to: to)
      if to == .running && generation.processOutcomeRawValue != ProcessOutcome.turnCompleted.rawValue { throw ReviewGenerationStoreError.invalidTransition }
      generation.structuralValidationRawValue = to.rawValue
      try context.save()
    }

    public func transitionEvidence(generationID: UUID, to: EvidenceReportState) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }) else { throw ReviewGenerationStoreError.generationNotFound }
      let from = EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid
      try ReviewStateMachine.validate(evidence: from, to: to)
      generation.evidenceReportStateRawValue = to.rawValue
      try context.save()
    }

    public func transitionQuality(
      versionID: UUID, to: QualityVerificationState, verifier: String?, evidenceReferencesJSON: String
    ) throws {
      let context = ModelContext(container)
      guard let quality = try context.fetch(FetchDescriptor<QualityVerification>()).first(where: { $0.reviewVersionID == versionID }) else { throw ReviewGenerationStoreError.reviewNotSelectable }
      let from = QualityVerificationState(rawValue: quality.stateRawValue) ?? .failed
      try ReviewStateMachine.validate(quality: from, to: to)
      if to == .verified {
        guard let verifier, !verifier.isEmpty,
          (try? JSONSerialization.jsonObject(with: Data(evidenceReferencesJSON.utf8))) != nil
        else { throw ReviewGenerationStoreError.invalidTransition }
        quality.verifier = verifier; quality.verifiedAt = Date()
      }
      quality.stateRawValue = to.rawValue
      quality.evidenceReferencesJSON = evidenceReferencesJSON
      try context.save()
    }

    public func beginPromotion(
      generationID: UUID, versionID: UUID, reviewRelativePath: String,
      manifestSHA256: String, autoSelect: Bool
    ) throws {
      let context = ModelContext(container)
      let generations = try context.fetch(FetchDescriptor<ReviewGeneration>())
      guard let generation = generations.first(where: { $0.id == generationID }) else { throw ReviewGenerationStoreError.generationNotFound }
      guard generation.processOutcomeRawValue == ProcessOutcome.turnCompleted.rawValue,
        generation.structuralValidationRawValue == StructuralValidationState.passed.rawValue,
        generation.reviewVersionID == nil,
        generation.promotionPhaseRawValue == ReviewPromotionPhase.none.rawValue
      else { throw ReviewGenerationStoreError.invalidTransition }
      try ReviewStateMachine.validate(promotion: .none, to: .intentRecorded)
      guard !generations.contains(where: { $0.reviewVersionID == versionID || $0.promotionVersionID == versionID }) else { throw ReviewGenerationStoreError.versionAlreadyExists }
      let prefix = "Papers/\(generation.paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/review/\(versionID.uuidString.lowercased())"
      guard reviewRelativePath == prefix, Self.validSHA256(manifestSHA256) else {
        throw ReviewGenerationStoreError.invalidPaperPath
      }
      generation.promotionPhaseRawValue = ReviewPromotionPhase.intentRecorded.rawValue
      generation.promotionVersionID = versionID
      generation.promotionRelativePath = reviewRelativePath
      generation.promotionManifestSHA256 = manifestSHA256
      generation.promotionAutoSelect = autoSelect
      try context.save()
    }

    public func markPromotionFilesMoved(generationID: UUID) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }), generation.promotionPhaseRawValue == ReviewPromotionPhase.intentRecorded.rawValue else { throw ReviewGenerationStoreError.invalidTransition }
      generation.promotionPhaseRawValue = ReviewPromotionPhase.filesMoved.rawValue
      try context.save()
    }

    public func commitPromotion(generationID: UUID, applySelection: Bool) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }),
        let versionID = generation.promotionVersionID,
        let relative = generation.promotionRelativePath,
        generation.promotionManifestSHA256 != nil
      else { throw ReviewGenerationStoreError.generationNotFound }
      guard [ReviewPromotionPhase.intentRecorded.rawValue, ReviewPromotionPhase.filesMoved.rawValue].contains(generation.promotionPhaseRawValue), generation.reviewVersionID == nil else { throw ReviewGenerationStoreError.invalidTransition }
      let currentPhase = ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none
      try ReviewStateMachine.validate(promotion: currentPhase, to: .committed)
      generation.reviewVersionID = versionID
      generation.reviewRelativePath = relative
      generation.promotionPhaseRawValue = ReviewPromotionPhase.committed.rawValue
      context.insert(ReviewEvidenceReport(generationID: generationID, reviewVersionID: versionID, relativePath: relative + "/evidence-report.json", state: EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid))
      context.insert(QualityVerification(generationID: generationID, reviewVersionID: versionID))
      if applySelection && generation.promotionAutoSelect {
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == generation.paperID }) else { throw ReviewGenerationStoreError.paperNotFound }
        paper.selectedReviewVersionID = versionID; paper.updatedAt = Date()
        try ReviewStateMachine.validate(promotion: .committed, to: .selected)
        generation.promotionPhaseRawValue = ReviewPromotionPhase.selected.rawValue
      }
      try context.save()
    }

    public func recoverPromotion(generationID: UUID) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }),
        let versionID = generation.promotionVersionID,
        let relative = generation.promotionRelativePath,
        generation.promotionManifestSHA256 != nil,
        generation.reviewVersionID == nil
      else { throw ReviewGenerationStoreError.generationNotFound }
      let current = ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none
      if current == .intentRecorded {
        try ReviewStateMachine.validate(promotion: current, to: .filesMoved)
      }
      try ReviewStateMachine.validate(
        promotion: current == .intentRecorded ? .filesMoved : current, to: .committed)
      try ReviewStateMachine.validate(promotion: .committed, to: .recoveryRequired)
      generation.reviewVersionID = versionID
      generation.reviewRelativePath = relative
      generation.promotionPhaseRawValue = ReviewPromotionPhase.recoveryRequired.rawValue
      context.insert(ReviewEvidenceReport(
        generationID: generationID, reviewVersionID: versionID,
        relativePath: relative + "/evidence-report.json",
        state: EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid))
      context.insert(QualityVerification(generationID: generationID, reviewVersionID: versionID))
      try context.save()
    }

    public func markPromotionPhase(generationID: UUID, phase: ReviewPromotionPhase) throws {
      let context = ModelContext(container)
      guard let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: { $0.id == generationID }) else { throw ReviewGenerationStoreError.generationNotFound }
      let current = ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none
      try ReviewStateMachine.validate(promotion: current, to: phase)
      generation.promotionPhaseRawValue = phase.rawValue
      try context.save()
    }

    public func select(paperID: UUID, versionID: UUID) throws {
      let context = ModelContext(container)
      guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID })
      else { throw ReviewGenerationStoreError.paperNotFound }
      guard try context.fetch(FetchDescriptor<ReviewGeneration>()).contains(where: {
        $0.paperID == paperID && $0.reviewVersionID == versionID && $0.isSelectable
      }) else { throw ReviewGenerationStoreError.reviewNotSelectable }
      paper.selectedReviewVersionID = versionID; paper.updatedAt = Date()
      try context.save()
    }

    public func generations(paperID: UUID) throws -> [ReviewGenerationRecord] {
      let context = ModelContext(container)
      let qualities = try context.fetch(FetchDescriptor<QualityVerification>())
      return try context.fetch(FetchDescriptor<ReviewGeneration>()).filter { $0.paperID == paperID }
        .map { generation in
          let quality = generation.reviewVersionID.flatMap { version in
            qualities.first { $0.reviewVersionID == version }
          }
          return Self.record(generation, quality: quality)
        }.sorted {
          $0.createdAt == $1.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }

    public func reconcileInterruptedGenerations() throws -> [UUID] {
      let context = ModelContext(container)
      let generations = try context.fetch(FetchDescriptor<ReviewGeneration>()).filter {
        $0.processOutcomeRawValue == ProcessOutcome.running.rawValue
      }
      let operations = try context.fetch(FetchDescriptor<CodexOperation>())
      for generation in generations {
        generation.processOutcomeRawValue = ProcessOutcome.interrupted.rawValue
        if let operationID = generation.operationID,
          let operation = operations.first(where: { $0.id == operationID })
        { operation.processOutcomeRawValue = ProcessOutcome.interrupted.rawValue; operation.endedAt = Date() }
      }
      try context.save()
      return generations.map(\.id)
    }

    private static func persisted(_ outcome: CodexOperationOutcome) -> ProcessOutcome {
      switch outcome {
      case .turnCompleted: .turnCompleted
      case .failed: .failed
      case .cancelled: .cancelled
      case .timedOut, .interrupted: .interrupted
      case .protocolFailure: .protocolFailure
      case .running: .running
      }
    }

    private static func validSHA256(_ value: String) -> Bool {
      value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func record(
      _ generation: ReviewGeneration, quality: QualityVerification?
    ) -> ReviewGenerationRecord {
      ReviewGenerationRecord(
        id: generation.id, paperID: generation.paperID, sessionID: generation.sessionID,
        operationID: generation.operationID, workspaceRelativePath: generation.workspaceRelativePath,
        reviewVersionID: generation.reviewVersionID, reviewRelativePath: generation.reviewRelativePath,
        predecessorGenerationID: generation.predecessorGenerationID,
        createdAt: generation.createdAt,
        processOutcome: ProcessOutcome(rawValue: generation.processOutcomeRawValue) ?? .protocolFailure,
        structuralValidation: StructuralValidationState(rawValue: generation.structuralValidationRawValue) ?? .failed,
        evidenceReportState: EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid,
        qualityVerification: quality.flatMap { QualityVerificationState(rawValue: $0.stateRawValue) } ?? .notPerformed,
        promotionPhase: ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none,
        promotionVersionID: generation.promotionVersionID,
        promotionRelativePath: generation.promotionRelativePath,
        promotionManifestSHA256: generation.promotionManifestSHA256,
        promotionAutoSelect: generation.promotionAutoSelect)
    }

    private static func sessionRecord(_ session: CodexSession) -> ReviewSessionRecord {
      ReviewSessionRecord(
        id: session.id, externalThreadID: session.externalThreadID,
        workspaceRelativePath: session.workspaceRelativePath)
    }
  }
#endif
