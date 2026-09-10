#if PPR_PORTABLE_SCHEMA
  import CryptoKit
  import Foundation

  public final class PortablePaperChatStore: PaperChatStore, @unchecked Sendable {
    private let store: DurableModelStore
    public static let maximumUserMessageBytes = 16_384

    public init(store: DurableModelStore) { self.store = store }

    public func paper(id: UUID) throws -> PaperChatRecord {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == id }) else {
          throw ChatStoreError.paperNotFound
        }
        return Self.record(paper)
      }
    }

    public func currentSession(paperID: UUID) throws -> ChatSessionRecord? {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard let current = paper.currentChatSessionID else { return nil }
        guard let session = snapshot.sessions.first(where: { $0.id == current }) else {
          throw ChatStoreError.sessionNotFound
        }
        try Self.validateCurrent(session: session, paper: paper)
        return Self.record(session)
      }
    }

    public func assertCurrentSession(
      paperID: UUID, sessionID: UUID, externalThreadID: String?
    ) throws {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else {
          throw ChatStoreError.sessionNotFound
        }
        try Self.validateCurrent(session: session, paper: paper)
        if session.externalThreadID != externalThreadID {
          throw SessionOperationQueueError.externalThreadMismatch(
            expected: session.externalThreadID ?? "<unbound>",
            presented: externalThreadID ?? "<unbound>")
        }
      }
    }

    public func messages(paperID: UUID) throws -> [ChatMessageRecord] {
      try store.read { snapshot in
        guard snapshot.papers.contains(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        return snapshot.messages.filter { $0.paperID == paperID }
          .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
          .map(Self.record)
      }
    }

    public func selectedReviewContext(paperID: UUID) throws -> SelectedReviewChatContext? {
      try store.read { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard let versionID = paper.selectedReviewVersionID,
          let generation = snapshot.generations.first(where: {
            $0.paperID == paperID && $0.reviewVersionID == versionID && $0.isSelectable
          }), let relative = generation.reviewRelativePath
        else { return nil }
        let evidence = snapshot.evidenceReports.first { $0.reviewVersionID == versionID }
        let note = evidence?.independentlyVerified == true
          ? "structurally valid; evidence separately verified"
          : "Generated · structure checked; generator evidence is not independently verified"
        return SelectedReviewChatContext(relativePath: relative, qualityNote: note)
      }
    }

    public func predecessorTranscript(sessionID: UUID) throws -> [TranscriptMessage] {
      try store.read { snapshot in
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else {
          throw ChatStoreError.sessionNotFound
        }
        var chain = Set<UUID>()
        var cursor: UUID? = session.id
        while let id = cursor, chain.insert(id).inserted {
          cursor = snapshot.sessions.first(where: { $0.id == id })?.predecessorSessionID
        }
        return snapshot.messages.filter { chain.contains($0.sessionID) }.map {
          TranscriptMessage(
            id: $0.id.uuidString.lowercased(),
            role: TranscriptMessage.Role(rawValue: $0.roleRawValue) ?? .error,
            content: $0.committedContent, createdAt: $0.createdAt,
            committed: $0.draftContent == nil && $0.deliveryStateRawValue == "committed",
            deleted: false)
        }
      }
    }

    public func createInitialSession(
      paperID: UUID, sessionID: UUID, workspaceRelativePath: String
    ) throws -> ChatSessionRecord {
      try store.transaction { snapshot in
        guard let paperIndex = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard snapshot.papers[paperIndex].currentChatSessionID == nil else {
          throw ChatStoreError.invalidReplacement
        }
        let session = CodexSession(
          id: sessionID, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: workspaceRelativePath, lifecycle: .active)
        snapshot.sessions.append(session)
        snapshot.papers[paperIndex].currentChatSessionID = sessionID
        snapshot.papers[paperIndex].repairState = .none
        snapshot.papers[paperIndex].updatedAt = Date()
        return Self.record(session)
      }
    }

    public func commitReplacement(
      paperID: UUID, predecessorSessionID: UUID, successorSessionID: UUID,
      workspaceRelativePath: String, reason: String
    ) throws -> ChatSessionRecord {
      try store.transaction { snapshot in
        guard let paperIndex = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard snapshot.papers[paperIndex].currentChatSessionID == predecessorSessionID,
          let predecessorIndex = snapshot.sessions.firstIndex(where: { $0.id == predecessorSessionID }),
          snapshot.sessions[predecessorIndex].paperID == paperID,
          snapshot.sessions[predecessorIndex].purpose == .paperChat,
          !snapshot.sessions.contains(where: { $0.id == successorSessionID })
        else { throw ChatStoreError.invalidReplacement }
        let now = Date()
        var successor = CodexSession(
          id: successorSessionID, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: workspaceRelativePath, lifecycle: .active, createdAt: now)
        successor.predecessorSessionID = predecessorSessionID
        snapshot.sessions[predecessorIndex].replacementSessionID = successorSessionID
        snapshot.sessions[predecessorIndex].replacementReason = String(reason.prefix(1_024))
        snapshot.sessions[predecessorIndex].replacedAt = now
        snapshot.sessions[predecessorIndex].lifecycle = .historical
        snapshot.sessions.append(successor)
        snapshot.papers[paperIndex].currentChatSessionID = successorSessionID
        snapshot.papers[paperIndex].repairState = .none
        snapshot.papers[paperIndex].updatedAt = now
        return Self.record(successor)
      }
    }

    public func prepareTurn(
      paperID: UUID, sessionID: UUID, prompt: String, operationID: UUID,
      userMessageID: UUID, journalRelativePath: String, retryPredecessorID: UUID? = nil
    ) throws -> PreparedChatTurn {
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        prompt.utf8.count <= Self.maximumUserMessageBytes
      else { throw ChatStoreError.messageTooLarge }
      return try store.transaction { snapshot in
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }) else {
          throw ChatStoreError.paperNotFound
        }
        guard paper.currentChatSessionID == sessionID else { throw ChatStoreError.sessionNotCurrent }
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else {
          throw ChatStoreError.sessionNotFound
        }
        try Self.validateCurrent(session: session, paper: paper)
        if let retryPredecessorID {
          guard let prior = snapshot.operations.first(where: { $0.id == retryPredecessorID }),
            prior.processOutcomeRawValue != ProcessOutcome.running.rawValue,
            prior.processOutcomeRawValue != ProcessOutcome.turnCompleted.rawValue
          else { throw ChatStoreError.retryNotAllowed }
          guard prior.sessionID == sessionID
              || snapshot.sessions.first(where: { $0.id == sessionID })?.predecessorSessionID
                == prior.sessionID
          else { throw ChatStoreError.retryNotAllowed }
        }
        let hash = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        var operation = CodexOperation(
          id: operationID, clientOperationID: operationID, sessionID: sessionID,
          kind: "chatTurn", promptSHA256: hash, journalRelativePath: journalRelativePath)
        operation.startedAt = Date()
        operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
        operation.retryPredecessorID = retryPredecessorID
        snapshot.operations.append(operation)
        snapshot.messages.append(
          ChatMessage(
            id: userMessageID, paperID: paperID, sessionID: sessionID,
            operationID: operationID, role: "user", committedContent: prompt,
            deliveryState: "queued"))
        return PreparedChatTurn(
          paper: Self.record(paper), session: Self.record(session), operationID: operationID,
          userMessageID: userMessageID, prompt: prompt, journalRelativePath: journalRelativePath)
      }
    }

    public func applyTransportResult(operationID: UUID, result: CodexTransportResult) throws {
      let committedError: Error? = try store.transaction { snapshot in
        guard let operationIndex = snapshot.operations.firstIndex(where: { $0.id == operationID })
        else { throw ChatStoreError.operationNotFound }
        let sessionID = snapshot.operations[operationIndex].sessionID
        guard let sessionIndex = snapshot.sessions.firstIndex(where: { $0.id == sessionID }) else {
          throw ChatStoreError.sessionNotFound
        }
        let paperID = snapshot.sessions[sessionIndex].paperID
        guard let paper = snapshot.papers.first(where: { $0.id == paperID }),
          paper.currentChatSessionID == sessionID,
          snapshot.sessions[sessionIndex].purpose == .paperChat,
          snapshot.sessions[sessionIndex].lifecycle == .active
        else {
          snapshot.operations[operationIndex].processOutcomeRawValue =
            ProcessOutcome.interrupted.rawValue
          snapshot.operations[operationIndex].endedAt = Date()
          for messageIndex in snapshot.messages.indices
          where snapshot.messages[messageIndex].operationID == operationID
          {
            snapshot.messages[messageIndex].deliveryStateRawValue =
              ProcessOutcome.interrupted.rawValue
            snapshot.messages[messageIndex].updatedAt = Date()
          }
          return ChatStoreError.sessionNotCurrent
        }
        if let thread = result.state.externalThreadID {
          if let existing = snapshot.sessions[sessionIndex].externalThreadID, existing != thread {
            snapshot.operations[operationIndex].processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
            snapshot.operations[operationIndex].endedAt = Date()
            for messageIndex in snapshot.messages.indices
            where snapshot.messages[messageIndex].operationID == operationID
            {
              snapshot.messages[messageIndex].deliveryStateRawValue =
                ProcessOutcome.protocolFailure.rawValue
              snapshot.messages[messageIndex].updatedAt = Date()
            }
            return SessionOperationQueueError.externalThreadMismatch(
              expected: existing, presented: thread)
          }
          snapshot.sessions[sessionIndex].externalThreadID = thread
        }
        snapshot.operations[operationIndex].processOutcomeRawValue = Self.persisted(result.state.outcome).rawValue
        snapshot.operations[operationIndex].exitCode = Int(result.exitStatus)
        snapshot.operations[operationIndex].terminalEventRawValue = result.state.terminalEvents.last
        snapshot.operations[operationIndex].endedAt = Date()
        for messageIndex in snapshot.messages.indices
        where snapshot.messages[messageIndex].operationID == operationID
          && snapshot.messages[messageIndex].roleRawValue == "user"
        {
          snapshot.messages[messageIndex].deliveryStateRawValue =
            result.state.outcome == .turnCompleted ? "committed" : result.state.outcome.rawValue
          snapshot.messages[messageIndex].updatedAt = Date()
        }
        for projected in result.state.messages {
          let id = ChatMessageIdentity.assistant(operationID: operationID, itemID: projected.itemID)
          if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
            snapshot.messages[index].committedContent = projected.committed ?? ""
            snapshot.messages[index].draftContent = projected.draft
            snapshot.messages[index].deliveryStateRawValue = projected.committed == nil ? "draft" : "committed"
            snapshot.messages[index].updatedAt = Date()
          } else {
            var message = ChatMessage(
              id: id, paperID: paperID, sessionID: sessionID, operationID: operationID,
              role: "assistant", committedContent: projected.committed ?? "",
              deliveryState: projected.committed == nil ? "draft" : "committed")
            message.draftContent = projected.draft
            snapshot.messages.append(message)
          }
        }
        return nil
      }
      if let committedError { throw committedError }
    }

    public func recordOperationFailure(operationID: UUID, outcome: ProcessOutcome) throws {
      try store.transaction { snapshot in
        guard let index = snapshot.operations.firstIndex(where: { $0.id == operationID }) else {
          throw ChatStoreError.operationNotFound
        }
        guard snapshot.operations[index].processOutcomeRawValue == ProcessOutcome.pending.rawValue
          || snapshot.operations[index].processOutcomeRawValue == ProcessOutcome.running.rawValue
        else { return () }
        snapshot.operations[index].processOutcomeRawValue = outcome.rawValue
        snapshot.operations[index].endedAt = Date()
        for messageIndex in snapshot.messages.indices
        where snapshot.messages[messageIndex].operationID == operationID
        {
          snapshot.messages[messageIndex].deliveryStateRawValue = outcome.rawValue
          snapshot.messages[messageIndex].updatedAt = Date()
        }
        return ()
      }
    }

    private static func validateCurrent(session: CodexSession, paper: Paper) throws {
      guard session.paperID == paper.id else { throw ChatStoreError.crossPaperReference }
      guard session.purpose == .paperChat else { throw ChatStoreError.crossPaperReference }
      guard session.lifecycle == .active else { throw ChatStoreError.historicalSession }
      guard paper.currentChatSessionID == session.id else { throw ChatStoreError.sessionNotCurrent }
    }

    private static func record(_ paper: Paper) -> PaperChatRecord {
      PaperChatRecord(
        paperID: paper.id, title: paper.canonicalTitle,
        sourceRelativePath: paper.sourceRelativePath, sourceSHA256: paper.sourceSHA256,
        selectedReviewVersionID: paper.selectedReviewVersionID,
        currentSessionID: paper.currentChatSessionID)
    }

    private static func record(_ session: CodexSession) -> ChatSessionRecord {
      ChatSessionRecord(
        id: session.id, paperID: session.paperID,
        workspaceRelativePath: session.workspaceRelativePath,
        externalThreadID: session.externalThreadID,
        predecessorSessionID: session.predecessorSessionID, lifecycle: session.lifecycle)
    }

    private static func record(_ message: ChatMessage) -> ChatMessageRecord {
      ChatMessageRecord(
        id: message.id, paperID: message.paperID, sessionID: message.sessionID,
        operationID: message.operationID, role: message.roleRawValue,
        content: message.committedContent, draft: message.draftContent,
        deliveryState: message.deliveryStateRawValue, createdAt: message.createdAt)
    }

    private static func persisted(_ outcome: CodexOperationOutcome) -> ProcessOutcome {
      switch outcome {
      case .running: .running
      case .turnCompleted: .turnCompleted
      case .failed, .timedOut: .failed
      case .cancelled: .cancelled
      case .interrupted: .interrupted
      case .protocolFailure: .protocolFailure
      }
    }
  }
#endif
