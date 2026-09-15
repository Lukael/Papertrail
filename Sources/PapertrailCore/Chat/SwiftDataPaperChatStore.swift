#if !PPR_PORTABLE_SCHEMA
  import CryptoKit
  import Foundation
  import SwiftData

  /// Full-Xcode persistence adapter. The portable adapter exercises the same
  /// transaction boundaries on CommandLineTools hosts; this adapter keeps all
  /// authoritative pointer/lineage mutations inside one ModelContext save.
  public final class SwiftDataPaperChatStore: PaperChatStore, @unchecked Sendable {
    private let container: ModelContainer
    private let lock = NSLock()

    public init(container: ModelContainer) { self.container = container }

    public func paper(id: UUID) throws -> PaperChatRecord {
      try read { context in
        guard let value = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == id })
        else { throw ChatStoreError.paperNotFound }
        return Self.record(value)
      }
    }

    public func currentSession(paperID: UUID) throws -> ChatSessionRecord? {
      try read { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID })
        else { throw ChatStoreError.paperNotFound }
        guard let id = paper.currentChatSessionID else { return nil }
        guard let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == id })
        else { throw ChatStoreError.sessionNotFound }
        try Self.validate(session, paper)
        return Self.record(session)
      }
    }

    public func assertCurrentSession(
      paperID: UUID, sessionID: UUID, externalThreadID: String?
    ) throws {
      try read { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID }),
          let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == sessionID })
        else { throw ChatStoreError.sessionNotFound }
        try Self.validate(session, paper)
        if session.externalThreadID != externalThreadID {
          throw SessionOperationQueueError.externalThreadMismatch(
            expected: session.externalThreadID ?? "<unbound>",
            presented: externalThreadID ?? "<unbound>")
        }
      }
    }

    public func messages(paperID: UUID) throws -> [ChatMessageRecord] {
      try read { context in
        try context.fetch(FetchDescriptor<ChatMessage>(
          predicate: #Predicate { $0.paperID == paperID },
          sortBy: [SortDescriptor(\.createdAt)]))
          .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
          .map(Self.record)
      }
    }

    public func selectedReviewContext(paperID: UUID) throws -> SelectedReviewChatContext? {
      try read { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID })
        else { throw ChatStoreError.paperNotFound }
        guard let versionID = paper.selectedReviewVersionID,
          let generation = try context.fetch(FetchDescriptor<ReviewGeneration>()).first(where: {
            $0.paperID == paperID && $0.reviewVersionID == versionID && $0.isSelectable
          }), let relative = generation.reviewRelativePath
        else { return nil }
        let evidence = try context.fetch(FetchDescriptor<ReviewEvidenceReport>()).first {
          $0.reviewVersionID == versionID
        }
        return SelectedReviewChatContext(
          relativePath: relative,
          qualityNote: evidence?.independentlyVerified == true
            ? "structurally valid; evidence separately verified"
            : "Generated · structure checked; generator evidence is not independently verified")
      }
    }

    public func predecessorTranscript(sessionID: UUID) throws -> [TranscriptMessage] {
      try read { context in
        let sessions = try context.fetch(FetchDescriptor<CodexSession>())
        guard sessions.contains(where: { $0.id == sessionID }) else { throw ChatStoreError.sessionNotFound }
        var chain = Set<UUID>(), cursor: UUID? = sessionID
        while let id = cursor, chain.insert(id).inserted {
          cursor = sessions.first(where: { $0.id == id })?.predecessorSessionID
        }
        return try context.fetch(FetchDescriptor<ChatMessage>()).filter { chain.contains($0.sessionID) }.map {
          TranscriptMessage(
            id: $0.id.uuidString.lowercased(),
            role: TranscriptMessage.Role(rawValue: $0.roleRawValue) ?? .error,
            content: $0.committedContent, createdAt: $0.createdAt,
            committed: $0.draftContent == nil && $0.deliveryStateRawValue == "committed")
        }
      }
    }

    public func createInitialSession(paperID: UUID, sessionID: UUID, workspaceRelativePath: String) throws -> ChatSessionRecord {
      try write { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID })
        else { throw ChatStoreError.paperNotFound }
        guard paper.currentChatSessionID == nil else { throw ChatStoreError.invalidReplacement }
        let session = CodexSession(
          id: sessionID, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: workspaceRelativePath, lifecycle: .active)
        context.insert(session)
        paper.currentChatSessionID = sessionID
        paper.repairState = .none
        paper.updatedAt = Date()
        return Self.record(session)
      }
    }

    public func commitReplacement(
      paperID: UUID, predecessorSessionID: UUID, successorSessionID: UUID,
      workspaceRelativePath: String, reason: String
    ) throws -> ChatSessionRecord {
      try write { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID }),
          paper.currentChatSessionID == predecessorSessionID,
          let predecessor = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == predecessorSessionID }),
          predecessor.paperID == paperID, predecessor.purpose == .paperChat
        else { throw ChatStoreError.invalidReplacement }
        let now = Date()
        let successor = CodexSession(
          id: successorSessionID, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: workspaceRelativePath, lifecycle: .active, createdAt: now)
        successor.predecessorSessionID = predecessorSessionID
        predecessor.replacementSessionID = successorSessionID
        predecessor.replacementReason = String(reason.prefix(1_024))
        predecessor.replacedAt = now
        predecessor.lifecycle = .historical
        context.insert(successor)
        paper.currentChatSessionID = successorSessionID
        paper.repairState = .none
        paper.updatedAt = now
        return Self.record(successor)
      }
    }

    public func prepareTurn(
      paperID: UUID, sessionID: UUID, prompt: String, operationID: UUID,
      userMessageID: UUID, journalRelativePath: String, retryPredecessorID: UUID?
    ) throws -> PreparedChatTurn {
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        prompt.utf8.count <= PortableLimits.maximumUserMessageBytes
      else { throw ChatStoreError.messageTooLarge }
      return try write { context in
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: { $0.id == paperID }),
          let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == sessionID })
        else { throw ChatStoreError.sessionNotFound }
        try Self.validate(session, paper)
        if let retryPredecessorID {
          guard let prior = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == retryPredecessorID }),
            prior.processOutcomeRawValue != ProcessOutcome.running.rawValue,
            prior.processOutcomeRawValue != ProcessOutcome.turnCompleted.rawValue,
            prior.sessionID == sessionID || session.predecessorSessionID == prior.sessionID
          else { throw ChatStoreError.retryNotAllowed }
        }
        let hash = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        let operation = CodexOperation(
          id: operationID, clientOperationID: operationID, sessionID: sessionID,
          kind: "chatTurn", promptSHA256: hash, journalRelativePath: journalRelativePath)
        operation.startedAt = Date()
        operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
        operation.retryPredecessorID = retryPredecessorID
        let message = ChatMessage(
          id: userMessageID, paperID: paperID, sessionID: sessionID, operationID: operationID,
          role: "user", committedContent: prompt, deliveryState: "queued")
        context.insert(operation)
        context.insert(message)
        return PreparedChatTurn(
          paper: Self.record(paper), session: Self.record(session), operationID: operationID,
          userMessageID: userMessageID, prompt: prompt, journalRelativePath: journalRelativePath)
      }
    }

    public func applyTransportResult(operationID: UUID, result: CodexTransportResult) throws {
      let committedError: Error? = try write { context in
        guard let operation = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == operationID }),
          let session = try context.fetch(FetchDescriptor<CodexSession>()).first(where: { $0.id == operation.sessionID })
        else { throw ChatStoreError.operationNotFound }
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
          $0.id == session.paperID
        }), paper.currentChatSessionID == session.id, session.purpose == .paperChat,
          session.lifecycle == .active
        else {
          operation.processOutcomeRawValue = ProcessOutcome.interrupted.rawValue
          operation.endedAt = Date()
          for message in try context.fetch(FetchDescriptor<ChatMessage>())
          where message.operationID == operationID {
            message.deliveryStateRawValue = ProcessOutcome.interrupted.rawValue
            message.updatedAt = Date()
          }
          return ChatStoreError.sessionNotCurrent
        }
        if let thread = result.state.externalThreadID {
          if let existing = session.externalThreadID, existing != thread {
            operation.processOutcomeRawValue = ProcessOutcome.protocolFailure.rawValue
            operation.endedAt = Date()
            for message in try context.fetch(FetchDescriptor<ChatMessage>())
            where message.operationID == operationID {
              message.deliveryStateRawValue = ProcessOutcome.protocolFailure.rawValue
              message.updatedAt = Date()
            }
            return SessionOperationQueueError.externalThreadMismatch(
              expected: existing, presented: thread)
          }
          session.externalThreadID = thread
        }
        operation.processOutcomeRawValue = Self.persisted(result.state.outcome).rawValue
        operation.exitCode = Int(result.exitStatus)
        operation.terminalEventRawValue = result.state.terminalEvents.last
        operation.endedAt = Date()
        let existing = try context.fetch(FetchDescriptor<ChatMessage>())
        for message in existing where message.operationID == operationID && message.roleRawValue == "user" {
          message.deliveryStateRawValue = result.state.outcome == .turnCompleted ? "committed" : result.state.outcome.rawValue
          message.updatedAt = Date()
        }
        for projected in result.state.messages {
          let id = ChatMessageIdentity.assistant(operationID: operationID, itemID: projected.itemID)
          let message = existing.first(where: { $0.id == id }) ?? ChatMessage(
            id: id, paperID: session.paperID, sessionID: session.id, operationID: operationID,
            role: "assistant", committedContent: "", deliveryState: "draft")
          if message.modelContext == nil { context.insert(message) }
          message.committedContent = projected.committed ?? ""
          message.draftContent = projected.draft
          message.deliveryStateRawValue = projected.committed == nil ? "draft" : "committed"
          message.updatedAt = Date()
        }
        return nil
      }
      if let committedError { throw committedError }
    }

    public func recordOperationFailure(operationID: UUID, outcome: ProcessOutcome) throws {
      try write { context in
        guard let operation = try context.fetch(FetchDescriptor<CodexOperation>()).first(where: { $0.id == operationID })
        else { throw ChatStoreError.operationNotFound }
        guard operation.processOutcomeRawValue == ProcessOutcome.pending.rawValue
          || operation.processOutcomeRawValue == ProcessOutcome.running.rawValue
        else { return () }
        operation.processOutcomeRawValue = outcome.rawValue
        operation.endedAt = Date()
        for message in try context.fetch(FetchDescriptor<ChatMessage>()) where message.operationID == operationID {
          message.deliveryStateRawValue = outcome.rawValue
          message.updatedAt = Date()
        }
        return ()
      }
    }

    private func read<T>(_ body: (ModelContext) throws -> T) throws -> T {
      try lock.withLock { try body(ModelContext(container)) }
    }
    private func write<T>(_ body: (ModelContext) throws -> T) throws -> T {
      try lock.withLock {
        let context = ModelContext(container)
        let result = try body(context)
        try context.save()
        return result
      }
    }

    private enum PortableLimits { static let maximumUserMessageBytes = 16_384 }
    private static func validate(_ session: CodexSession, _ paper: Paper) throws {
      guard session.paperID == paper.id, session.purpose == .paperChat else { throw ChatStoreError.crossPaperReference }
      guard session.lifecycle == .active else { throw ChatStoreError.historicalSession }
      guard paper.currentChatSessionID == session.id else { throw ChatStoreError.sessionNotCurrent }
    }
    private static func record(_ p: Paper) -> PaperChatRecord { .init(
      paperID: p.id, title: p.canonicalTitle, sourceRelativePath: p.sourceRelativePath,
      sourceSHA256: p.sourceSHA256, selectedReviewVersionID: p.selectedReviewVersionID,
      currentSessionID: p.currentChatSessionID) }
    private static func record(_ s: CodexSession) -> ChatSessionRecord { .init(
      id: s.id, paperID: s.paperID, workspaceRelativePath: s.workspaceRelativePath,
      externalThreadID: s.externalThreadID, predecessorSessionID: s.predecessorSessionID,
      lifecycle: s.lifecycle) }
    private static func record(_ m: ChatMessage) -> ChatMessageRecord { .init(
      id: m.id, paperID: m.paperID, sessionID: m.sessionID, operationID: m.operationID,
      role: m.roleRawValue, content: m.committedContent, draft: m.draftContent,
      deliveryState: m.deliveryStateRawValue, createdAt: m.createdAt) }
    private static func persisted(_ value: CodexOperationOutcome) -> ProcessOutcome {
      switch value { case .running: .running; case .turnCompleted: .turnCompleted; case .failed,.timedOut: .failed; case .cancelled: .cancelled; case .interrupted: .interrupted; case .protocolFailure: .protocolFailure }
    }
  }
#endif
