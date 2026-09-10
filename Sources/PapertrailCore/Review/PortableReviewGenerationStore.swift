#if PPR_PORTABLE_SCHEMA
  import Foundation

  public final class PortableReviewGenerationStore: ReviewGenerationStore, @unchecked Sendable {
    private let store: DurableModelStore

    public init(store: DurableModelStore) { self.store = store }

    public func paper(id: UUID) throws -> ReviewPaperRecord {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == id }) else {
          throw ReviewGenerationStoreError.paperNotFound
        }
        return Self.paperRecord(paper)
      }
    }

    public func currentSession(paperID: UUID) throws -> ReviewSessionRecord? {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw ReviewGenerationStoreError.paperNotFound
        }
        guard let sessionID = paper.currentChatSessionID else { return nil }
        guard let session = snapshot.sessions.first(where: {
          $0.id == sessionID && $0.paperID == paperID && $0.purpose == .paperChat
            && $0.lifecycle == .active
        }) else { throw ReviewGenerationStoreError.crossPaperReference }
        return Self.sessionRecord(session)
      }
    }

    public func markAutomaticReviewCompleted(paperID: UUID) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
          throw ReviewGenerationStoreError.paperNotFound
        }
        guard snapshot.papers[index].automaticReviewRequiredAt != nil else {
          throw ReviewGenerationStoreError.invalidTransition
        }
        if snapshot.papers[index].automaticReviewCompletedAt == nil {
          snapshot.papers[index].automaticReviewCompletedAt = Date()
          snapshot.papers[index].updatedAt = Date()
        }
      }
    }

    public func createGeneration(
      generationID: UUID, paperID: UUID, sessionID: UUID, operationID: UUID,
      workspaceRelativePath: String, sessionWorkspaceRelativePath: String,
      promptSHA256: String, journalRelativePath: String,
      predecessorGenerationID: UUID?
    ) throws -> ReviewSessionRecord {
      try store.transaction { snapshot in
        guard let paperIndex = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
          throw ReviewGenerationStoreError.paperNotFound
        }
        guard !snapshot.generations.contains(where: { $0.id == generationID }),
          !snapshot.operations.contains(where: { $0.id == operationID })
        else { throw ReviewGenerationStoreError.generationAlreadyExists }
        if let predecessorGenerationID {
          guard snapshot.generations.contains(where: {
            $0.id == predecessorGenerationID && $0.paperID == paperID
          }) else { throw ReviewGenerationStoreError.crossPaperReference }
        }
        let expectedPrefix = "Papers/\(paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/workspace/agent"
        guard workspaceRelativePath == expectedPrefix else {
          throw ReviewGenerationStoreError.invalidPaperPath
        }
        guard sessionWorkspaceRelativePath == workspaceRelativePath,
          !snapshot.sessions.contains(where: { $0.id == sessionID })
        else { throw ReviewGenerationStoreError.generationAlreadyExists }
        let session = CodexSession(
          id: sessionID, paperID: paperID, purpose: .reviewGeneration,
          purposeReferenceID: generationID, workspaceRelativePath: workspaceRelativePath,
          lifecycle: .active)
        snapshot.sessions.append(session)
        var operation = CodexOperation(
          id: operationID, clientOperationID: operationID, sessionID: session.id,
          kind: "generateReview", promptSHA256: promptSHA256,
          journalRelativePath: journalRelativePath)
        operation.startedAt = Date()
        operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
        snapshot.operations.append(operation)
        snapshot.messages.append(
          ChatMessage(
            id: ChatMessageIdentity.reviewRequest(operationID: operationID),
            paperID: paperID, sessionID: session.id, operationID: operationID,
            role: "user",
            committedContent: ReviewChatProjection.request(
              paperTitle: snapshot.papers[paperIndex].canonicalTitle),
            deliveryState: "queued"))
        var generation = ReviewGeneration(
          id: generationID, paperID: paperID, sessionID: session.id,
          workspaceRelativePath: workspaceRelativePath,
          predecessorGenerationID: predecessorGenerationID)
        generation.operationID = operationID
        generation.processOutcomeRawValue = ProcessOutcome.running.rawValue
        snapshot.generations.append(generation)
        return Self.sessionRecord(session)
      }
    }

    public func recordProcessResult(generationID: UUID, result: CodexTransportResult) throws {
      try store.transaction { snapshot in
        guard let generationIndex = snapshot.generations.firstIndex(where: { $0.id == generationID }),
          let operationID = snapshot.generations[generationIndex].operationID,
          let operationIndex = snapshot.operations.firstIndex(where: { $0.id == operationID }),
          let sessionIndex = snapshot.sessions.firstIndex(where: {
            $0.id == snapshot.generations[generationIndex].sessionID
          })
        else { throw ReviewGenerationStoreError.generationNotFound }
        guard snapshot.generations[generationIndex].processOutcomeRawValue == ProcessOutcome.running.rawValue
        else { throw ReviewGenerationStoreError.invalidTransition }
        if let thread = result.state.externalThreadID {
          if let existing = snapshot.sessions[sessionIndex].externalThreadID, existing != thread {
            snapshot.generations[generationIndex].processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
            snapshot.operations[operationIndex].processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
            snapshot.operations[operationIndex].endedAt = Date()
            throw ReviewGenerationStoreError.invalidTransition
          }
          snapshot.sessions[sessionIndex].externalThreadID = thread
        }
        let outcome = Self.persisted(result.state.outcome)
        try ReviewStateMachine.validate(process: .running, to: outcome)
        snapshot.generations[generationIndex].processOutcomeRawValue = outcome.rawValue
        snapshot.operations[operationIndex].processOutcomeRawValue = outcome.rawValue
        snapshot.operations[operationIndex].exitCode = Int(result.exitStatus)
        snapshot.operations[operationIndex].terminalEventRawValue = result.state.terminalEvents.last
        snapshot.operations[operationIndex].endedAt = Date()
        snapshot.sessions[sessionIndex].lifecycle = .active
        for messageIndex in snapshot.messages.indices
        where snapshot.messages[messageIndex].operationID == operationID
          && snapshot.messages[messageIndex].roleRawValue == "user"
        {
          snapshot.messages[messageIndex].deliveryStateRawValue =
            outcome == .turnCompleted ? "committed" : outcome.rawValue
          snapshot.messages[messageIndex].updatedAt = Date()
        }
        let projectedMessages = result.state.messages.isEmpty && outcome == .turnCompleted
          ? [ProjectedMessage(
              itemID: "papertrail-review-completed", draft: nil,
              committed: ReviewChatProjection.completedFallback)]
          : result.state.messages
        for projected in projectedMessages {
          let id = ChatMessageIdentity.assistant(
            operationID: operationID, itemID: projected.itemID)
          var message = ChatMessage(
            id: id, paperID: snapshot.sessions[sessionIndex].paperID,
            sessionID: snapshot.sessions[sessionIndex].id, operationID: operationID,
            role: "assistant", committedContent: projected.committed ?? "",
            deliveryState: projected.committed == nil ? "draft" : "committed")
          message.draftContent = projected.draft
          snapshot.messages.append(message)
        }
      }
    }

    public func recordPreparationFailure(generationID: UUID, outcome: ProcessOutcome) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        guard snapshot.generations[index].reviewVersionID == nil else {
          throw ReviewGenerationStoreError.invalidTransition
        }
        let current = ProcessOutcome(rawValue: snapshot.generations[index].processOutcomeRawValue)
          ?? .protocolFailure
        try ReviewStateMachine.validate(process: current, to: outcome)
        snapshot.generations[index].processOutcomeRawValue = outcome.rawValue
        if let operationID = snapshot.generations[index].operationID,
          let operationIndex = snapshot.operations.firstIndex(where: { $0.id == operationID })
        {
          snapshot.operations[operationIndex].processOutcomeRawValue = outcome.rawValue
          snapshot.operations[operationIndex].endedAt = Date()
          for messageIndex in snapshot.messages.indices
          where snapshot.messages[messageIndex].operationID == operationID
          {
            snapshot.messages[messageIndex].deliveryStateRawValue = outcome.rawValue
            snapshot.messages[messageIndex].updatedAt = Date()
          }
        }
      }
    }

    public func transitionProcess(generationID: UUID, to: ProcessOutcome) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        let from = ProcessOutcome(rawValue: snapshot.generations[index].processOutcomeRawValue)
          ?? .protocolFailure
        try ReviewStateMachine.validate(process: from, to: to)
        snapshot.generations[index].processOutcomeRawValue = to.rawValue
        if let operationID = snapshot.generations[index].operationID,
          let operationIndex = snapshot.operations.firstIndex(where: { $0.id == operationID })
        { snapshot.operations[operationIndex].processOutcomeRawValue = to.rawValue }
      }
    }

    public func transitionStructure(
      generationID: UUID, to: StructuralValidationState
    ) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        let from = StructuralValidationState(
          rawValue: snapshot.generations[index].structuralValidationRawValue) ?? .failed
        try ReviewStateMachine.validate(structure: from, to: to)
        if to == .running,
          snapshot.generations[index].processOutcomeRawValue != ProcessOutcome.turnCompleted.rawValue
        { throw ReviewGenerationStoreError.invalidTransition }
        snapshot.generations[index].structuralValidationRawValue = to.rawValue
      }
    }

    public func transitionEvidence(generationID: UUID, to: EvidenceReportState) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        let from = EvidenceReportState(rawValue: snapshot.generations[index].evidenceReportStateRawValue)
          ?? .invalid
        try ReviewStateMachine.validate(evidence: from, to: to)
        snapshot.generations[index].evidenceReportStateRawValue = to.rawValue
      }
    }

    public func transitionQuality(
      versionID: UUID, to: QualityVerificationState, verifier: String?,
      evidenceReferencesJSON: String
    ) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.qualityVerifications.firstIndex(where: {
          $0.reviewVersionID == versionID
        }) else { throw ReviewGenerationStoreError.reviewNotSelectable }
        let from = QualityVerificationState(
          rawValue: snapshot.qualityVerifications[index].stateRawValue) ?? .failed
        try ReviewStateMachine.validate(quality: from, to: to)
        if to == .verified {
          guard let verifier, !verifier.isEmpty,
            (try? JSONSerialization.jsonObject(with: Data(evidenceReferencesJSON.utf8))) != nil
          else { throw ReviewGenerationStoreError.invalidTransition }
          snapshot.qualityVerifications[index].verifier = verifier
          snapshot.qualityVerifications[index].verifiedAt = Date()
        }
        snapshot.qualityVerifications[index].stateRawValue = to.rawValue
        snapshot.qualityVerifications[index].evidenceReferencesJSON = evidenceReferencesJSON
      }
    }

    public func beginPromotion(
      generationID: UUID, versionID: UUID, reviewRelativePath: String,
      manifestSHA256: String, autoSelect: Bool
    ) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        let generation = snapshot.generations[index]
        guard generation.processOutcomeRawValue == ProcessOutcome.turnCompleted.rawValue,
          generation.structuralValidationRawValue == StructuralValidationState.passed.rawValue,
          generation.reviewVersionID == nil,
          generation.promotionPhaseRawValue == ReviewPromotionPhase.none.rawValue
        else { throw ReviewGenerationStoreError.invalidTransition }
        try ReviewStateMachine.validate(promotion: .none, to: .intentRecorded)
        guard !snapshot.generations.contains(where: {
          $0.reviewVersionID == versionID || $0.promotionVersionID == versionID
        }) else {
          throw ReviewGenerationStoreError.versionAlreadyExists
        }
        let prefix = "Papers/\(generation.paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/review/\(versionID.uuidString.lowercased())"
        guard reviewRelativePath == prefix, Self.validSHA256(manifestSHA256) else {
          throw ReviewGenerationStoreError.invalidPaperPath
        }
        snapshot.generations[index].promotionPhaseRawValue = ReviewPromotionPhase.intentRecorded.rawValue
        snapshot.generations[index].promotionVersionID = versionID
        snapshot.generations[index].promotionRelativePath = reviewRelativePath
        snapshot.generations[index].promotionManifestSHA256 = manifestSHA256
        snapshot.generations[index].promotionAutoSelect = autoSelect
      }
    }

    public func markPromotionFilesMoved(generationID: UUID) throws {
      try markPromotionPhase(generationID: generationID, phase: .filesMoved)
    }

    public func commitPromotion(generationID: UUID, applySelection: Bool) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }),
          let versionID = snapshot.generations[index].promotionVersionID,
          let relative = snapshot.generations[index].promotionRelativePath,
          snapshot.generations[index].promotionManifestSHA256 != nil
        else { throw ReviewGenerationStoreError.generationNotFound }
        let generation = snapshot.generations[index]
        guard [ReviewPromotionPhase.intentRecorded.rawValue, ReviewPromotionPhase.filesMoved.rawValue]
          .contains(generation.promotionPhaseRawValue), generation.reviewVersionID == nil
        else { throw ReviewGenerationStoreError.invalidTransition }
        let currentPhase = ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none
        try ReviewStateMachine.validate(promotion: currentPhase, to: .committed)
        snapshot.generations[index].reviewVersionID = versionID
        snapshot.generations[index].reviewRelativePath = relative
        snapshot.generations[index].promotionPhaseRawValue = ReviewPromotionPhase.committed.rawValue
        snapshot.evidenceReports.append(
          ReviewEvidenceReport(
            generationID: generationID, reviewVersionID: versionID,
            relativePath: relative + "/evidence-report.json",
            state: EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid))
        snapshot.qualityVerifications.append(
          QualityVerification(generationID: generationID, reviewVersionID: versionID))
        if applySelection && generation.promotionAutoSelect {
          guard let paperIndex = snapshot.papers.firstIndex(where: {
            $0.id == generation.paperID
          }) else { throw ReviewGenerationStoreError.paperNotFound }
          snapshot.papers[paperIndex].selectedReviewVersionID = versionID
          snapshot.papers[paperIndex].updatedAt = Date()
          try ReviewStateMachine.validate(promotion: .committed, to: .selected)
          snapshot.generations[index].promotionPhaseRawValue = ReviewPromotionPhase.selected.rawValue
        }
      }
    }

    public func recoverPromotion(generationID: UUID) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }),
          let versionID = snapshot.generations[index].promotionVersionID,
          let relative = snapshot.generations[index].promotionRelativePath,
          snapshot.generations[index].promotionManifestSHA256 != nil
        else { throw ReviewGenerationStoreError.generationNotFound }
        let generation = snapshot.generations[index]
        guard generation.reviewVersionID == nil else { throw ReviewGenerationStoreError.invalidTransition }
        let current = ReviewPromotionPhase(rawValue: generation.promotionPhaseRawValue) ?? .none
        if current == .intentRecorded {
          try ReviewStateMachine.validate(promotion: current, to: .filesMoved)
        }
        try ReviewStateMachine.validate(
          promotion: current == .intentRecorded ? .filesMoved : current, to: .committed)
        try ReviewStateMachine.validate(promotion: .committed, to: .recoveryRequired)
        snapshot.generations[index].reviewVersionID = versionID
        snapshot.generations[index].reviewRelativePath = relative
        snapshot.generations[index].promotionPhaseRawValue = ReviewPromotionPhase.recoveryRequired.rawValue
        snapshot.evidenceReports.append(ReviewEvidenceReport(
          generationID: generationID, reviewVersionID: versionID,
          relativePath: relative + "/evidence-report.json",
          state: EvidenceReportState(rawValue: generation.evidenceReportStateRawValue) ?? .invalid))
        snapshot.qualityVerifications.append(QualityVerification(
          generationID: generationID, reviewVersionID: versionID))
      }
    }

    public func markPromotionPhase(generationID: UUID, phase: ReviewPromotionPhase) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.generations.firstIndex(where: { $0.id == generationID }) else {
          throw ReviewGenerationStoreError.generationNotFound
        }
        let current = ReviewPromotionPhase(
          rawValue: snapshot.generations[index].promotionPhaseRawValue) ?? .none
        try ReviewStateMachine.validate(promotion: current, to: phase)
        snapshot.generations[index].promotionPhaseRawValue = phase.rawValue
      }
    }

    public func select(paperID: UUID, versionID: UUID) throws {
      try store.transaction { snapshot in
        guard let paperIndex = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
          throw ReviewGenerationStoreError.paperNotFound
        }
        guard snapshot.generations.contains(where: {
          $0.paperID == paperID && $0.reviewVersionID == versionID && $0.isSelectable
        }) else { throw ReviewGenerationStoreError.reviewNotSelectable }
        snapshot.papers[paperIndex].selectedReviewVersionID = versionID
        snapshot.papers[paperIndex].updatedAt = Date()
      }
    }

    public func generations(paperID: UUID) throws -> [ReviewGenerationRecord] {
      try store.read { snapshot in
        snapshot.generations.filter { $0.paperID == paperID }.map { generation in
          let quality = generation.reviewVersionID.flatMap { version in
            snapshot.qualityVerifications.first { $0.reviewVersionID == version }
          }
          return Self.record(generation, quality: quality)
        }.sorted {
          $0.createdAt == $1.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
      }
    }

    public func reconcileInterruptedGenerations() throws -> [UUID] {
      try store.transaction { snapshot in
        let indices = snapshot.generations.indices.filter {
          snapshot.generations[$0].processOutcomeRawValue == ProcessOutcome.running.rawValue
        }
        let ids = indices.map { snapshot.generations[$0].id }
        for index in indices {
          snapshot.generations[index].processOutcomeRawValue = ProcessOutcome.interrupted.rawValue
          if let operationID = snapshot.generations[index].operationID,
            let operationIndex = snapshot.operations.firstIndex(where: { $0.id == operationID })
          {
            snapshot.operations[operationIndex].processOutcomeRawValue = ProcessOutcome.interrupted.rawValue
            snapshot.operations[operationIndex].endedAt = Date()
          }
        }
        return ids
      }
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

    private static func paperRecord(_ paper: Paper) -> ReviewPaperRecord {
      ReviewPaperRecord(
        id: paper.id, title: paper.canonicalTitle, sourceRelativePath: paper.sourceRelativePath,
        sourceSHA256: paper.sourceSHA256, selectedReviewVersionID: paper.selectedReviewVersionID,
        automaticReviewRequiredAt: paper.automaticReviewRequiredAt,
        automaticReviewCompletedAt: paper.automaticReviewCompletedAt)
    }

    private static func sessionRecord(_ session: CodexSession) -> ReviewSessionRecord {
      ReviewSessionRecord(
        id: session.id, externalThreadID: session.externalThreadID,
        workspaceRelativePath: session.workspaceRelativePath)
    }

    private static func validSHA256(_ value: String) -> Bool {
      value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func record(
      _ generation: ReviewGeneration, quality: QualityVerification?
    ) -> ReviewGenerationRecord {
      ReviewGenerationRecord(
        id: generation.id, paperID: generation.paperID, sessionID: generation.sessionID,
        operationID: generation.operationID,
        workspaceRelativePath: generation.workspaceRelativePath,
        reviewVersionID: generation.reviewVersionID,
        reviewRelativePath: generation.reviewRelativePath,
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
  }
#endif
