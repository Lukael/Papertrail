import Foundation
#if !PPR_PORTABLE_SCHEMA
import SwiftData
#endif

/// Completed paper chat captured when the user requests a document.
public struct ReviewConversationSnapshot: Codable, Equatable, Sendable {
  public static let maximumByteCount = 2 * 1024 * 1024
  public struct Message: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let createdAt: Date
  }
  public let paperID: UUID
  public let capturedAt: Date
  public let messages: [Message]

  public init(paperID: UUID, capturedAt: Date = Date(),
              records: [ChatMessageRecord] = [], paperChatSessionIDs: Set<UUID> = []) {
    self.paperID = paperID
    self.capturedAt = capturedAt
    messages = records.filter {
      $0.paperID == paperID && paperChatSessionIDs.contains($0.sessionID)
        && $0.deliveryState == "committed" && $0.draft == nil && ["user", "assistant"].contains($0.role)
        && $0.createdAt <= capturedAt && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.sorted {
      $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
    }.map { Message(id: $0.id.uuidString.lowercased(), role: $0.role,
                    content: $0.content, createdAt: $0.createdAt) }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumByteCount else {
      throw CocoaError(.fileReadTooLarge)
    }
    return data
  }

#if PPR_PORTABLE_SCHEMA
  public static func capture(paperID: UUID, store: DurableModelStore) throws -> Self {
    let state = try store.read { $0 }
    return make(paperID: paperID, sessions: state.sessions, messages: state.messages, operations: state.operations)
  }
#else
  @MainActor
  public static func capture(paperID: UUID, container: ModelContainer) throws -> Self {
    let context = ModelContext(container)
    return make(paperID: paperID,
                sessions: try context.fetch(FetchDescriptor<CodexSession>()),
                messages: try context.fetch(FetchDescriptor<ChatMessage>()),
                operations: try context.fetch(FetchDescriptor<CodexOperation>()))
  }
#endif

  private static func make(paperID: UUID, sessions: [CodexSession], messages: [ChatMessage],
                           operations: [CodexOperation]) -> Self {
    let completedOperations = Dictionary(operations.filter {
      $0.processOutcomeRawValue == ProcessOutcome.turnCompleted.rawValue
    }.map { ($0.id, $0.sessionID) }, uniquingKeysWith: { first, _ in first })
    // Legacy messages without operation IDs retain their committed-state semantics.
    // Modern messages require the whole turn to have completed successfully.
    let completedMessages = messages.filter {
      guard let operationID = $0.operationID else { return true }
      return completedOperations[operationID] == $0.sessionID
    }
    return Self(paperID: paperID, records: completedMessages.map {
      ChatMessageRecord(id: $0.id, paperID: $0.paperID, sessionID: $0.sessionID,
                        operationID: $0.operationID, role: $0.roleRawValue,
                        content: $0.committedContent, draft: $0.draftContent,
                        deliveryState: $0.deliveryStateRawValue, createdAt: $0.createdAt)
    }, paperChatSessionIDs: Set(sessions.filter {
      $0.paperID == paperID && $0.purpose == .paperChat
    }.map(\.id)))
  }
}
