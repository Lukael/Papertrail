import Foundation

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

public struct PaperDeletionReceipt: Equatable, Sendable {
  public let paperID: UUID
  public let deletedSessionCount: Int
  public let deletedOperationCount: Int
  public let deletedMessageCount: Int
  public let deletedGenerationCount: Int
  public let deletedEvidenceCount: Int
  public let deletedQualityVerificationCount: Int
  public let fileCleanupPending: Bool
  public let automaticRequestCleanupPending: Bool
}

public enum PaperDeletionError: Error, Equatable {
  case paperNotFound(UUID)
}

/// Removes one paper's complete durable object graph and its UUID-scoped library directory.
/// The directory is first moved to a private sibling staging name so a model-save failure can
/// restore it without ever risking another paper's files.
public struct PaperDeletionService {
  private let paths: LibraryPaths
  private let automaticRequests: DurableAutomaticReviewRequestStore

  #if PPR_PORTABLE_SCHEMA
    private let store: DurableModelStore

    public init(paths: LibraryPaths, store: DurableModelStore) {
      self.paths = paths
      self.store = store
      self.automaticRequests = DurableAutomaticReviewRequestStore(
        url: paths.automaticReviewRequestsURL)
    }
  #else
    private let container: ModelContainer

    public init(paths: LibraryPaths, container: ModelContainer) {
      self.paths = paths
      self.container = container
      self.automaticRequests = DurableAutomaticReviewRequestStore(
        url: paths.automaticReviewRequestsURL)
    }
  #endif

  public func delete(paperID: UUID, fileManager: FileManager = .default) throws
    -> PaperDeletionReceipt
  {
    let paperDirectory = paths.paper(paperID)
    let stagedDirectory = paths.papersDirectory.appendingPathComponent(
      ".deleting-\(paperID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    var stagedFiles = false

    if fileManager.fileExists(atPath: paperDirectory.path) {
      try fileManager.moveItem(at: paperDirectory, to: stagedDirectory)
      stagedFiles = true
    }

    let receipt: RecordCounts
    do {
      receipt = try deleteRecords(paperID: paperID)
    } catch {
      if stagedFiles, fileManager.fileExists(atPath: stagedDirectory.path),
        !fileManager.fileExists(atPath: paperDirectory.path)
      {
        try? fileManager.moveItem(at: stagedDirectory, to: paperDirectory)
      }
      throw error
    }

    // Once the authoritative model commit succeeds, never restore the directory. Retry owner-only
    // trees after making their directories writable, and also remove leftovers from an earlier
    // interrupted delete for this exact paper UUID.
    var automaticRequestCleanupPending = false
    do {
      _ = try automaticRequests.reconcile(
        paperID: paperID, automaticReviewRequired: false)
    } catch { automaticRequestCleanupPending = true }
    let deletionPrefix = ".deleting-\(paperID.uuidString.lowercased())-"
    var cleanupTargets: [URL] = stagedFiles ? [stagedDirectory] : []
    if let siblings = try? fileManager.contentsOfDirectory(
      at: paths.papersDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
    {
      cleanupTargets.append(contentsOf: siblings.filter { $0.lastPathComponent.hasPrefix(deletionPrefix) })
    }
    for target in Set(cleanupTargets.map(\.standardizedFileURL)) {
      try? Self.removeOwnedTree(at: target, fileManager: fileManager)
    }
    let cleanupPending = fileManager.fileExists(atPath: paperDirectory.path)
      || ((try? fileManager.contentsOfDirectory(
        at: paths.papersDirectory, includingPropertiesForKeys: nil)) ?? [])
        .contains { $0.lastPathComponent.hasPrefix(deletionPrefix) }
    return PaperDeletionReceipt(
      paperID: paperID,
      deletedSessionCount: receipt.sessions,
      deletedOperationCount: receipt.operations,
      deletedMessageCount: receipt.messages,
      deletedGenerationCount: receipt.generations,
      deletedEvidenceCount: receipt.evidence,
      deletedQualityVerificationCount: receipt.quality,
      fileCleanupPending: cleanupPending,
      automaticRequestCleanupPending: automaticRequestCleanupPending)
  }

  private static func removeOwnedTree(at url: URL, fileManager: FileManager) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      try fileManager.removeItem(at: url)
      return
    } catch {
      // Promoted reviews are intentionally read-only. Only relax permissions inside the exact
      // UUID-scoped staging tree after the first removal attempt fails.
      if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink != true
      {
        try? fileManager.setAttributes(
          [.posixPermissions: 0o700, .immutable: false, .appendOnly: false],
          ofItemAtPath: url.path)
        if let enumerator = fileManager.enumerator(
          at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
          for case let item as URL in enumerator {
            guard let itemValues = try? item.resourceValues(
              forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              itemValues.isSymbolicLink != true
            else { continue }
            let mode = itemValues.isDirectory == true ? 0o700 : 0o600
            try? fileManager.setAttributes(
              [.posixPermissions: mode, .immutable: false, .appendOnly: false],
              ofItemAtPath: item.path)
          }
        }
      }
      try fileManager.removeItem(at: url)
    }
  }

  private typealias RecordCounts = (
    sessions: Int, operations: Int, messages: Int, generations: Int, evidence: Int,
    quality: Int
  )

  #if PPR_PORTABLE_SCHEMA
    private func deleteRecords(paperID: UUID) throws -> RecordCounts {
      try store.transaction { snapshot in
        guard snapshot.papers.contains(where: { $0.id == paperID }) else {
          throw PaperDeletionError.paperNotFound(paperID)
        }
        let sessionIDs = Set(snapshot.sessions.filter { $0.paperID == paperID }.map(\.id))
        let generationIDs = Set(snapshot.generations.filter { $0.paperID == paperID }.map(\.id))
        let operationIDs = Set(snapshot.operations.filter { sessionIDs.contains($0.sessionID) }.map(\.id))
        let counts: RecordCounts = (
          sessionIDs.count,
          operationIDs.count,
          snapshot.messages.filter { $0.paperID == paperID || sessionIDs.contains($0.sessionID) }.count,
          generationIDs.count,
          snapshot.evidenceReports.filter { generationIDs.contains($0.generationID) }.count,
          snapshot.qualityVerifications.filter { generationIDs.contains($0.generationID) }.count)

        snapshot.papers.removeAll { $0.id == paperID }
        snapshot.sessions.removeAll { sessionIDs.contains($0.id) }
        snapshot.operations.removeAll { operationIDs.contains($0.id) }
        snapshot.messages.removeAll { $0.paperID == paperID || sessionIDs.contains($0.sessionID) }
        snapshot.generations.removeAll { generationIDs.contains($0.id) }
        snapshot.evidenceReports.removeAll { generationIDs.contains($0.generationID) }
        snapshot.qualityVerifications.removeAll { generationIDs.contains($0.generationID) }
        return counts
      }
    }
  #else
    private func deleteRecords(paperID: UUID) throws -> RecordCounts {
      let context = ModelContext(container)
      let papers = try context.fetch(FetchDescriptor<Paper>())
      guard let paper = papers.first(where: { $0.id == paperID }) else {
        throw PaperDeletionError.paperNotFound(paperID)
      }
      let sessions = try context.fetch(FetchDescriptor<CodexSession>()).filter {
        $0.paperID == paperID
      }
      let sessionIDs = Set(sessions.map(\.id))
      let operations = try context.fetch(FetchDescriptor<CodexOperation>()).filter {
        sessionIDs.contains($0.sessionID)
      }
      let messages = try context.fetch(FetchDescriptor<ChatMessage>()).filter {
        $0.paperID == paperID || sessionIDs.contains($0.sessionID)
      }
      let generations = try context.fetch(FetchDescriptor<ReviewGeneration>()).filter {
        $0.paperID == paperID
      }
      let generationIDs = Set(generations.map(\.id))
      let evidence = try context.fetch(FetchDescriptor<ReviewEvidenceReport>()).filter {
        generationIDs.contains($0.generationID)
      }
      let quality = try context.fetch(FetchDescriptor<QualityVerification>()).filter {
        generationIDs.contains($0.generationID)
      }

      for record in evidence { context.delete(record) }
      for record in quality { context.delete(record) }
      for record in messages { context.delete(record) }
      for record in operations { context.delete(record) }
      for record in generations { context.delete(record) }
      for record in sessions { context.delete(record) }
      context.delete(paper)
      try context.save()
      return (
        sessions.count, operations.count, messages.count, generations.count, evidence.count,
        quality.count)
    }
  #endif
}
