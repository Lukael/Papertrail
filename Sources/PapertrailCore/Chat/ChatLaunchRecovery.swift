import CryptoKit
import Foundation

public enum ChatMessageIdentity {
  public static func reviewRequest(operationID: UUID) -> UUID {
    derived(operationID: operationID, discriminator: "papertrail-review-request")
  }

  public static func assistant(operationID: UUID, itemID: String) -> UUID {
    derived(operationID: operationID, discriminator: itemID)
  }

  private static func derived(operationID: UUID, discriminator: String) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data("\(operationID.uuidString):\(discriminator)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

public struct RecoveredAssistantMessage: Sendable {
  public let id: UUID
  public let itemID: String
  public let committed: String
  public let draft: String?
}

public struct ChatJournalRecovery: Sendable {
  public let externalThreadID: String?
  public let messages: [RecoveredAssistantMessage]
  public let corruptTail: Bool
  public let operationResult: CodexOperationResultV1?
}

public enum ChatLaunchRecovery {
  /// A journal can restore accepted message bytes, but without the supervised
  /// child exit status an operation left `running` is truthfully interrupted.
  public static func replay(
    operationID: UUID, journalDirectoryURL: URL, fileManager: FileManager = .default
  ) throws -> [RecoveredAssistantMessage] {
    try replayWithReport(
      operationID: operationID, journalDirectoryURL: journalDirectoryURL,
      fileManager: fileManager
    ).messages
  }

  public static func replayWithReport(
    operationID: UUID, journalDirectoryURL: URL, fileManager: FileManager = .default
  ) throws -> ChatJournalRecovery {
    guard
      fileManager.fileExists(
        atPath: journalDirectoryURL.appendingPathComponent("events.jsonl").path)
    else {
      return ChatJournalRecovery(
        externalThreadID: nil, messages: [], corruptTail: false, operationResult: nil)
    }
    let recovered = try OperationJournal(directoryURL: journalDirectoryURL).replayAcceptedPrefix()
    let messages = recovered.projector.state.messages.map {
      RecoveredAssistantMessage(
        id: ChatMessageIdentity.assistant(operationID: operationID, itemID: $0.itemID),
        itemID: $0.itemID, committed: $0.committed ?? "", draft: $0.draft)
    }
    let operationResult: CodexOperationResultV1?
    var resultCorrupt = false
    do {
      operationResult = try CodexOperationResultStore(directoryURL: journalDirectoryURL).read(
        expectedOperationID: operationID,
        expectedJournalByteCount: OperationJournal(directoryURL: journalDirectoryURL).sizeBytes)
    } catch {
      operationResult = nil
      resultCorrupt = true
    }
    return ChatJournalRecovery(
      externalThreadID: recovered.projector.state.externalThreadID,
      messages: messages, corruptTail: recovered.error != nil || resultCorrupt,
      operationResult: operationResult)
  }
}
