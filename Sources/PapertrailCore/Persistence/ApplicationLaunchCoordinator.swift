import Foundation

public enum ApplicationLaunchCoordinator {
  #if !PPR_PORTABLE_SCHEMA
    public static func reconcile(
      container: ModelContainer, paths: LibraryPaths, fileManager: FileManager = .default
    ) throws -> [LibraryRecoveryIssue] {
      let context = ModelContext(container)
      var papers = try context.fetch(FetchDescriptor<Paper>())
      let sessions = try context.fetch(FetchDescriptor<CodexSession>())
      let generations = try context.fetch(FetchDescriptor<ReviewGeneration>())
      let legacy = LegacyCurrentChatImporter().load(paths: paths, fileManager: fileManager)
      var issues = try PDFImportRecovery(paths: paths).reconcile(existingPapers: papers) { paper in
        context.insert(paper)
        try context.save()
        papers.append(paper)
      }
      issues += try reconcileRecords(
        context: context, paths: paths, papers: papers, sessions: sessions, legacy: legacy,
        fileManager: fileManager)
      issues += legacy.issue.map { [$0] } ?? []
      issues += try inspectStorage(
        paths: paths, papers: papers, generations: generations, fileManager: fileManager)
      try context.save()
      return issues
    }
  #else
    public static func reconcile(
      store: DurableModelStore, paths: LibraryPaths, fileManager: FileManager = .default
    ) throws -> [LibraryRecoveryIssue] {
      let existingPapers = try store.read { $0.papers }
      let importIssues = try PDFImportRecovery(paths: paths).reconcile(
        existingPapers: existingPapers
      ) { paper in
        try store.transaction { snapshot in
          if !snapshot.papers.contains(where: { $0.id == paper.id }) {
            snapshot.papers.append(paper)
          }
        }
      }
      return try store.transaction { snapshot in
        let reconciler = LaunchReconciler()
        let legacy = LegacyCurrentChatImporter().load(paths: paths, fileManager: fileManager)
        var issues = importIssues + (legacy.issue.map { [$0] } ?? [])
        for index in snapshot.papers.indices {
          let paperID = snapshot.papers[index].id
          let sessionSnapshots = snapshot.sessions.map {
            SessionSnapshot(id: $0.id, paperID: $0.paperID, purpose: $0.purpose)
          }
          let result = reconciler.reconcileCurrentChat(
            paperID: paperID, currentPointer: snapshot.papers[index].currentChatSessionID,
            sessions: sessionSnapshots, legacyMigrationRequested: legacy.document != nil,
            legacyCurrentSessionIDs: legacy.document?.flaggedSessionIDs(for: paperID) ?? [])
          snapshot.papers[index].currentChatSessionID = result.currentChatSessionID
          snapshot.papers[index].repairState = result.repairState
          if let current = result.currentChatSessionID,
            let sessionIndex = snapshot.sessions.firstIndex(where: { $0.id == current })
          {
            snapshot.sessions[sessionIndex].lifecycle = .active
          }
          for sessionIndex in snapshot.sessions.indices
          where result.historicalSessionIDs.contains(snapshot.sessions[sessionIndex].id)
            && snapshot.sessions[sessionIndex].lifecycle == .active
          {
            snapshot.sessions[sessionIndex].lifecycle = .historical
          }
        }
        for operationIndex in snapshot.operations.indices
        where snapshot.operations[operationIndex].processOutcomeRawValue
          == ProcessOutcome.running.rawValue
        {
          let operation = snapshot.operations[operationIndex]
          var recovery = ChatJournalRecovery(
            externalThreadID: nil, messages: [], corruptTail: false, operationResult: nil)
          if let session = snapshot.sessions.first(where: { $0.id == operation.sessionID }) {
            let journal = try paths.url(forRelativePath: operation.journalRelativePath)
            do {
              recovery = try ChatLaunchRecovery.replayWithReport(
                operationID: operation.id, journalDirectoryURL: journal, fileManager: fileManager)
            } catch {
              recovery = ChatJournalRecovery(
                externalThreadID: nil, messages: [], corruptTail: true, operationResult: nil)
            }
            if recovery.corruptTail {
              issues.append(
                .corruptOperationJournal(
                  operationID: operation.id, relativePath: operation.journalRelativePath))
            }
            if snapshot.sessions.first(where: { $0.id == session.id })?.externalThreadID == nil,
              let externalThreadID = recovery.externalThreadID,
              let sessionIndex = snapshot.sessions.firstIndex(where: { $0.id == session.id })
            {
              snapshot.sessions[sessionIndex].externalThreadID = externalThreadID
            }
            for recovered in recovery.messages {
              if let existing = snapshot.messages.firstIndex(where: { $0.id == recovered.id }) {
                snapshot.messages[existing].committedContent = recovered.committed
                snapshot.messages[existing].draftContent = recovered.draft
                snapshot.messages[existing].deliveryStateRawValue =
                  recovered.draft == nil ? "committed" : "draft"
              } else {
                var message = ChatMessage(
                  id: recovered.id, paperID: session.paperID, sessionID: session.id,
                  operationID: operation.id, role: "assistant",
                  committedContent: recovered.committed,
                  deliveryState: recovered.draft == nil ? "committed" : "draft")
                message.draftContent = recovered.draft
                snapshot.messages.append(message)
              }
            }
          }
          let recoveredOutcome = recovery.operationResult?.outcome ?? .interrupted
          snapshot.operations[operationIndex].processOutcomeRawValue = recoveredOutcome.rawValue
          snapshot.operations[operationIndex].exitCode = recovery.operationResult.map {
            Int($0.exitStatus)
          }
          snapshot.operations[operationIndex].terminalEventRawValue =
            recovery.operationResult?.terminalEvent
          snapshot.operations[operationIndex].endedAt = Date()
          for messageIndex in snapshot.messages.indices
          where snapshot.messages[messageIndex].operationID == operation.id
            && snapshot.messages[messageIndex].roleRawValue == "user"
          {
            snapshot.messages[messageIndex].deliveryStateRawValue =
              recoveredOutcome == .turnCompleted ? "committed" : recoveredOutcome.rawValue
          }
        }
        let storageSnapshots = snapshot.papers.map { paper in
          let selectedGeneration = snapshot.generations.first {
            $0.paperID == paper.id && $0.reviewVersionID == paper.selectedReviewVersionID
          }
          return PaperStorageSnapshot(
            id: paper.id, sourceRelativePath: paper.sourceRelativePath,
            selectedReviewVersionID: paper.selectedReviewVersionID,
            selectedReviewRelativePath: selectedGeneration?.reviewRelativePath)
        }
        issues += try LibraryIntegrityReconciler().inspect(
          paths: paths, papers: storageSnapshots, fileManager: fileManager)
        for issue in issues {
          switch issue {
          case .missingSource(let paperID, _):
            if let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) {
              snapshot.papers[index].repairState = .sourceMissing
            }
          case .missingSelectedReview(let paperID, _):
            if let index = snapshot.papers.firstIndex(where: { $0.id == paperID }),
              snapshot.papers[index].repairState == .none
            {
              snapshot.papers[index].repairState = .selectedReviewMissing
            }
          case .recoverablePartial:
            break
          case .importRecoveryPending:
            break
          case .legacyImportInvalid:
            break
          case .corruptOperationJournal:
            break
          }
        }
        return issues
      }
    }
  #endif
}

#if !PPR_PORTABLE_SCHEMA
  import SwiftData

  extension ApplicationLaunchCoordinator {
    fileprivate static func reconcileRecords(
      context: ModelContext, paths: LibraryPaths, papers: [Paper], sessions: [CodexSession],
      legacy: LegacyCurrentChatLoad, fileManager: FileManager
    ) throws -> [LibraryRecoveryIssue] {
      let reconciler = LaunchReconciler()
      var issues: [LibraryRecoveryIssue] = []
      let snapshots = sessions.map {
        SessionSnapshot(id: $0.id, paperID: $0.paperID, purpose: $0.purpose)
      }
      for paper in papers {
        let result = reconciler.reconcileCurrentChat(
          paperID: paper.id, currentPointer: paper.currentChatSessionID, sessions: snapshots,
          legacyMigrationRequested: legacy.document != nil,
          legacyCurrentSessionIDs: legacy.document?.flaggedSessionIDs(for: paper.id) ?? [])
        paper.currentChatSessionID = result.currentChatSessionID
        paper.repairState = result.repairState
        if let current = result.currentChatSessionID,
          let currentSession = sessions.first(where: { $0.id == current })
        {
          currentSession.lifecycle = .active
        }
        for session in sessions
        where result.historicalSessionIDs.contains(session.id) && session.lifecycle == .active {
          session.lifecycle = .historical
        }
      }
      let operations = try context.fetch(FetchDescriptor<CodexOperation>())
      let messages = try context.fetch(FetchDescriptor<ChatMessage>())
      for operation in operations
      where operation.processOutcomeRawValue == ProcessOutcome.running.rawValue {
        var recovery = ChatJournalRecovery(
          externalThreadID: nil, messages: [], corruptTail: false, operationResult: nil)
        if let session = sessions.first(where: { $0.id == operation.sessionID }) {
          let journal = try paths.url(forRelativePath: operation.journalRelativePath)
          do {
            recovery = try ChatLaunchRecovery.replayWithReport(
              operationID: operation.id, journalDirectoryURL: journal, fileManager: fileManager)
          } catch {
            recovery = ChatJournalRecovery(
              externalThreadID: nil, messages: [], corruptTail: true, operationResult: nil)
          }
          if recovery.corruptTail {
            issues.append(
              .corruptOperationJournal(
                operationID: operation.id, relativePath: operation.journalRelativePath))
          }
          if session.externalThreadID == nil, let externalThreadID = recovery.externalThreadID {
            session.externalThreadID = externalThreadID
          }
          for recovered in recovery.messages {
            let message =
              messages.first(where: { $0.id == recovered.id })
              ?? ChatMessage(
                id: recovered.id, paperID: session.paperID, sessionID: session.id,
                operationID: operation.id, role: "assistant", committedContent: recovered.committed,
                deliveryState: recovered.draft == nil ? "committed" : "draft")
            if message.modelContext == nil { context.insert(message) }
            message.committedContent = recovered.committed
            message.draftContent = recovered.draft
            message.deliveryStateRawValue = recovered.draft == nil ? "committed" : "draft"
            message.updatedAt = Date()
          }
        }
        let recoveredOutcome = recovery.operationResult?.outcome ?? .interrupted
        operation.processOutcomeRawValue = recoveredOutcome.rawValue
        operation.exitCode = recovery.operationResult.map { Int($0.exitStatus) }
        operation.terminalEventRawValue = recovery.operationResult?.terminalEvent
        operation.endedAt = Date()
        for message in messages
        where message.operationID == operation.id && message.roleRawValue == "user" {
          message.deliveryStateRawValue =
            recoveredOutcome == .turnCompleted ? "committed" : recoveredOutcome.rawValue
          message.updatedAt = Date()
        }
      }
      return issues
    }

    fileprivate static func inspectStorage(
      paths: LibraryPaths, papers: [Paper], generations: [ReviewGeneration],
      fileManager: FileManager
    ) throws -> [LibraryRecoveryIssue] {
      let snapshots = papers.map { paper in
        let generation = generations.first {
          $0.paperID == paper.id && $0.reviewVersionID == paper.selectedReviewVersionID
        }
        return PaperStorageSnapshot(
          id: paper.id, sourceRelativePath: paper.sourceRelativePath,
          selectedReviewVersionID: paper.selectedReviewVersionID,
          selectedReviewRelativePath: generation?.reviewRelativePath)
      }
      let issues = try LibraryIntegrityReconciler().inspect(
        paths: paths, papers: snapshots, fileManager: fileManager)
      for issue in issues {
        switch issue {
        case .missingSource(let paperID, _):
          papers.first(where: { $0.id == paperID })?.repairState = .sourceMissing
        case .missingSelectedReview(let paperID, _):
          guard let paper = papers.first(where: { $0.id == paperID }), paper.repairState == .none
          else { continue }
          paper.repairState = .selectedReviewMissing
        case .recoverablePartial:
          break
        case .importRecoveryPending:
          break
        case .legacyImportInvalid:
          break
        case .corruptOperationJournal:
          break
        }
      }
      return issues
    }
  }
#endif

extension LegacyCurrentChatLoad {
  fileprivate var document: LegacyCurrentChatDocumentV0? {
    guard case .loaded(let document) = self else { return nil }
    return document
  }

  fileprivate var issue: LibraryRecoveryIssue? {
    guard case .invalid(let relativePath, let reason) = self else { return nil }
    return .legacyImportInvalid(relativePath: relativePath, reason: reason)
  }
}
