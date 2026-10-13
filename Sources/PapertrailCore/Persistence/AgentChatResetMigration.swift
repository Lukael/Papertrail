import Foundation

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

public struct AgentChatResetReceipt: Equatable, Sendable {
  public let deletedSessionCount: Int
  public let deletedOperationCount: Int
  public let deletedMessageCount: Int
  public let fileCleanupPending: Bool
}

/// One-time switch from Codex to Claude chat. Codex thread IDs cannot be resumed by Claude Code,
/// so paper-chat sessions, their turns, messages, and staged workspaces are removed. Papers,
/// review generations, review versions, and their review-session records are preserved.
///
/// The store change commits first and the marker is written last, so an interrupted run repeats
/// safely: the store step then finds nothing and only the file cleanup is retried.
public enum AgentChatResetMigration {
  public static let markerName = "agent-provider-claude.json"

  public static func markerURL(paths: LibraryPaths) -> URL {
    paths.storeDirectory.appendingPathComponent(markerName)
  }

  public static func isComplete(paths: LibraryPaths, fileManager: FileManager = .default) -> Bool {
    fileManager.fileExists(atPath: markerURL(paths: paths).path)
  }

  #if !PPR_PORTABLE_SCHEMA
    @discardableResult
    public static func runIfNeeded(
      container: ModelContainer, paths: LibraryPaths, fileManager: FileManager = .default
    ) throws -> AgentChatResetReceipt? {
      guard !isComplete(paths: paths, fileManager: fileManager) else { return nil }
      let context = ModelContext(container)
      let chatSessions = try context.fetch(FetchDescriptor<CodexSession>()).filter {
        $0.purpose == .paperChat
      }
      let sessionIDs = Set(chatSessions.map(\.id))
      let operations = try context.fetch(FetchDescriptor<CodexOperation>()).filter {
        sessionIDs.contains($0.sessionID)
      }
      let messages = try context.fetch(FetchDescriptor<ChatMessage>()).filter {
        sessionIDs.contains($0.sessionID)
      }
      for paper in try context.fetch(FetchDescriptor<Paper>()) {
        paper.currentChatSessionID = nil
        if paper.repairState == .currentChatPointerInvalid
          || paper.repairState == .legacyCurrentChatAmbiguous
        {
          paper.repairState = .none
        }
      }
      messages.forEach(context.delete)
      operations.forEach(context.delete)
      chatSessions.forEach(context.delete)
      try context.save()
      let paperIDs = try context.fetch(FetchDescriptor<Paper>()).map(\.id)
      return finish(
        paths: paths, paperIDs: paperIDs, sessions: chatSessions.count,
        operations: operations.count, messages: messages.count, fileManager: fileManager)
    }
  #else
    @discardableResult
    public static func runIfNeeded(
      store: DurableModelStore, paths: LibraryPaths, fileManager: FileManager = .default
    ) throws -> AgentChatResetReceipt? {
      guard !isComplete(paths: paths, fileManager: fileManager) else { return nil }
      let counts = try store.transaction { snapshot -> (Int, Int, Int, [UUID]) in
        let sessionIDs = Set(snapshot.sessions.filter { $0.purpose == .paperChat }.map(\.id))
        let sessionCount = sessionIDs.count
        let operationCount = snapshot.operations.filter { sessionIDs.contains($0.sessionID) }.count
        let messageCount = snapshot.messages.filter { sessionIDs.contains($0.sessionID) }.count
        snapshot.messages.removeAll { sessionIDs.contains($0.sessionID) }
        snapshot.operations.removeAll { sessionIDs.contains($0.sessionID) }
        snapshot.sessions.removeAll { sessionIDs.contains($0.id) }
        for index in snapshot.papers.indices {
          snapshot.papers[index].currentChatSessionID = nil
          if snapshot.papers[index].repairState == .currentChatPointerInvalid
            || snapshot.papers[index].repairState == .legacyCurrentChatAmbiguous
          {
            snapshot.papers[index].repairState = .none
          }
        }
        return (sessionCount, operationCount, messageCount, snapshot.papers.map(\.id))
      }
      return finish(
        paths: paths, paperIDs: counts.3, sessions: counts.0, operations: counts.1,
        messages: counts.2, fileManager: fileManager)
    }
  #endif

  private static func finish(
    paths: LibraryPaths, paperIDs: [UUID], sessions: Int, operations: Int, messages: Int,
    fileManager: FileManager
  ) -> AgentChatResetReceipt {
    var cleanupPending = false
    // Chat workspaces live only under each paper's `chat` directory; reviews live elsewhere.
    for paperID in paperIDs {
      let chatDirectory = paths.paper(paperID).appendingPathComponent("chat", isDirectory: true)
      guard fileManager.fileExists(atPath: chatDirectory.path) else { continue }
      do {
        try makeWritable(chatDirectory, fileManager: fileManager)
        try fileManager.removeItem(at: chatDirectory)
      } catch {
        cleanupPending = true
      }
    }
    // The legacy pointer file only names Codex chat sessions that no longer exist.
    if fileManager.fileExists(atPath: paths.legacyCurrentChatV0URL.path) {
      do { try fileManager.removeItem(at: paths.legacyCurrentChatV0URL) } catch {
        cleanupPending = true
      }
    }
    if !cleanupPending {
      do {
        let marker = try JSONSerialization.data(
          withJSONObject: [
            "provider": "claude", "chatResetAt": ISO8601DateFormatter().string(from: Date()),
          ], options: [.sortedKeys])
        try fileManager.createDirectory(
          at: paths.storeDirectory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try marker.write(to: markerURL(paths: paths), options: .atomic)
      } catch {
        cleanupPending = true
      }
    }
    return AgentChatResetReceipt(
      deletedSessionCount: sessions, deletedOperationCount: operations,
      deletedMessageCount: messages, fileCleanupPending: cleanupPending)
  }

  /// Staged inputs are read-only (0400/0500); restore owner write access so removal succeeds.
  private static func makeWritable(_ root: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    guard let enumerator = fileManager.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return }
    for case let item as URL in enumerator {
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { continue }
      try fileManager.setAttributes(
        [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: item.path)
    }
  }
}
