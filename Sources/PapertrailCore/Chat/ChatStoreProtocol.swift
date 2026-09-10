import Foundation

public enum ChatStoreError: Error, Equatable {
  case paperNotFound
  case sessionNotFound
  case sessionNotCurrent
  case crossPaperReference
  case historicalSession
  case operationNotFound
  case retryNotAllowed
  case invalidReplacement
  case messageTooLarge
  case operationAlreadyRunning
}

public struct PaperChatRecord: Equatable, Sendable {
  public let paperID: UUID
  public let title: String
  public let sourceRelativePath: String
  public let sourceSHA256: String
  public let selectedReviewVersionID: UUID?
  public let currentSessionID: UUID?
}

public struct ChatSessionRecord: Equatable, Sendable {
  public let id: UUID
  public let paperID: UUID
  public let workspaceRelativePath: String
  public let externalThreadID: String?
  public let predecessorSessionID: UUID?
  public let lifecycle: SessionLifecycle
}

public struct SelectedReviewChatContext: Equatable, Sendable {
  public let relativePath: String
  public let qualityNote: String
  public init(relativePath: String, qualityNote: String) {
    self.relativePath = relativePath
    self.qualityNote = qualityNote
  }
}

public struct ChatMessageRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let paperID: UUID
  public let sessionID: UUID
  public let operationID: UUID?
  public let role: String
  public let content: String
  public let draft: String?
  public let deliveryState: String
  public let createdAt: Date

  public init(
    id: UUID, paperID: UUID, sessionID: UUID, operationID: UUID?, role: String,
    content: String, draft: String?, deliveryState: String, createdAt: Date
  ) {
    self.id = id
    self.paperID = paperID
    self.sessionID = sessionID
    self.operationID = operationID
    self.role = role
    self.content = content
    self.draft = draft
    self.deliveryState = deliveryState
    self.createdAt = createdAt
  }
}

public struct PreparedChatTurn: Equatable, Sendable {
  public let paper: PaperChatRecord
  public let session: ChatSessionRecord
  public let operationID: UUID
  public let userMessageID: UUID
  public let prompt: String
  public let journalRelativePath: String
}

public protocol PaperChatStore: Sendable {
  func paper(id: UUID) throws -> PaperChatRecord
  func currentSession(paperID: UUID) throws -> ChatSessionRecord?
  func assertCurrentSession(
    paperID: UUID, sessionID: UUID, externalThreadID: String?
  ) throws
  func selectedReviewContext(paperID: UUID) throws -> SelectedReviewChatContext?
  func messages(paperID: UUID) throws -> [ChatMessageRecord]
  func predecessorTranscript(sessionID: UUID) throws -> [TranscriptMessage]
  func createInitialSession(
    paperID: UUID, sessionID: UUID, workspaceRelativePath: String
  ) throws -> ChatSessionRecord
  func commitReplacement(
    paperID: UUID, predecessorSessionID: UUID, successorSessionID: UUID,
    workspaceRelativePath: String, reason: String
  ) throws -> ChatSessionRecord
  func prepareTurn(
    paperID: UUID, sessionID: UUID, prompt: String, operationID: UUID,
    userMessageID: UUID, journalRelativePath: String, retryPredecessorID: UUID?
  ) throws -> PreparedChatTurn
  func applyTransportResult(operationID: UUID, result: CodexTransportResult) throws
  func recordOperationFailure(operationID: UUID, outcome: ProcessOutcome) throws
}
