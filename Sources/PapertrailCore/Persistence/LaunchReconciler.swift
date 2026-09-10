import Foundation

public struct SessionSnapshot: Equatable, Sendable {
  public let id: UUID
  public let paperID: UUID
  public let purpose: SessionPurpose

  public init(id: UUID, paperID: UUID, purpose: SessionPurpose) {
    self.id = id
    self.paperID = paperID
    self.purpose = purpose
  }
}

public struct CurrentChatReconciliation: Equatable, Sendable {
  public let currentChatSessionID: UUID?
  public let repairState: PaperRepairState
  public let historicalSessionIDs: Set<UUID>
}

public struct LaunchReconciler: Sendable {
  public init() {}

  public func reconcileCurrentChat(
    paperID: UUID, currentPointer: UUID?, sessions: [SessionSnapshot],
    legacyMigrationRequested: Bool = false, legacyCurrentSessionIDs: Set<UUID> = []
  ) -> CurrentChatReconciliation {
    let validChats = sessions.filter { $0.paperID == paperID && $0.purpose == .paperChat }
    let validIDs = Set(validChats.map(\.id))
    let resolved: UUID?
    let repair: PaperRepairState

    if let currentPointer {
      if validIDs.contains(currentPointer) {
        resolved = currentPointer
        repair = .none
      } else {
        resolved = nil
        repair = .currentChatPointerInvalid
      }
    } else if legacyMigrationRequested {
      let candidates = validIDs.intersection(legacyCurrentSessionIDs)
      if candidates.count == 1, let candidate = candidates.first {
        resolved = candidate
        repair = .none
      } else {
        resolved = nil
        repair = .legacyCurrentChatAmbiguous
      }
    } else {
      resolved = nil
      repair = .none
    }

    return CurrentChatReconciliation(
      currentChatSessionID: resolved,
      repairState: repair,
      historicalSessionIDs: validIDs.subtracting(resolved.map { [$0] } ?? []))
  }
}

public enum LibraryRecoveryIssue: Equatable, Sendable {
  case missingSource(paperID: UUID, relativePath: String)
  case missingSelectedReview(paperID: UUID, versionID: UUID)
  case recoverablePartial(relativePath: String)
  case importRecoveryPending(relativePath: String, reason: String)
  case legacyImportInvalid(relativePath: String, reason: String)
  case corruptOperationJournal(operationID: UUID, relativePath: String)
}

public struct PaperStorageSnapshot: Sendable {
  public let id: UUID
  public let sourceRelativePath: String
  public let selectedReviewVersionID: UUID?
  public let selectedReviewRelativePath: String?

  public init(
    id: UUID, sourceRelativePath: String, selectedReviewVersionID: UUID? = nil,
    selectedReviewRelativePath: String? = nil
  ) {
    self.id = id
    self.sourceRelativePath = sourceRelativePath
    self.selectedReviewVersionID = selectedReviewVersionID
    self.selectedReviewRelativePath = selectedReviewRelativePath
  }
}

public struct LibraryIntegrityReconciler: Sendable {
  public init() {}

  public func inspect(
    paths: LibraryPaths, papers: [PaperStorageSnapshot], fileManager: FileManager = .default
  ) throws -> [LibraryRecoveryIssue] {
    var issues: [LibraryRecoveryIssue] = []
    for paper in papers {
      let source = paths.root.appendingPathComponent(paper.sourceRelativePath)
      if !fileManager.fileExists(atPath: source.path) {
        issues.append(.missingSource(paperID: paper.id, relativePath: paper.sourceRelativePath))
      }
      if let versionID = paper.selectedReviewVersionID {
        guard let relative = paper.selectedReviewRelativePath else {
          issues.append(.missingSelectedReview(paperID: paper.id, versionID: versionID))
          continue
        }
        if !fileManager.fileExists(atPath: paths.root.appendingPathComponent(relative).path) {
          issues.append(.missingSelectedReview(paperID: paper.id, versionID: versionID))
        }
      }
    }
    if fileManager.fileExists(atPath: paths.root.path),
      let enumerator = fileManager.enumerator(
        at: paths.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    {
      for case let file as URL in enumerator where file.lastPathComponent.hasPrefix(".partial-") {
        issues.append(.recoverablePartial(relativePath: try paths.relativePath(for: file)))
      }
    }
    return issues
  }
}
