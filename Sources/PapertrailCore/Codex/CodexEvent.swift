import CryptoKit
import Foundation

public enum CodexEventError: Error, Equatable {
  case invalidJSON
  case missingRequiredField(String)
}

public struct CodexEvent: Equatable, Sendable {
  public let type: String
  public let threadID: String?
  public let turnID: String?
  public let itemID: String?
  public let itemType: String?
  public let text: String?
  public let message: String?
  public let canonicalRaw: Data

  public init(raw: Data) throws {
    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let type = object["type"] as? String
    else {
      throw CodexEventError.invalidJSON
    }
    self.type = type
    threadID = object["thread_id"] as? String
    turnID = object["turn_id"] as? String
    message = object["message"] as? String
    if let item = object["item"] as? [String: Any] {
      itemID = item["id"] as? String
      itemType = item["type"] as? String
      text = item["text"] as? String
    } else {
      itemID = nil
      itemType = nil
      text = nil
    }
    canonicalRaw = raw
  }

  public var deduplicationKey: String {
    let digest = SHA256.hash(data: canonicalRaw).map { String(format: "%02x", $0) }.joined()
    if let itemID { return "\(type):item:\(itemID):\(digest)" }
    if let threadID { return "\(type):thread:\(threadID):\(digest)" }
    if let turnID { return "\(type):turn:\(turnID):\(digest)" }
    return "\(type):raw:\(digest)"
  }
}

public enum CodexOperationOutcome: String, Codable, Equatable, Sendable {
  case running
  case turnCompleted
  case failed
  case cancelled
  case timedOut
  case interrupted
  case protocolFailure
}

public struct ProjectedMessage: Codable, Equatable, Sendable {
  public let itemID: String
  public var draft: String?
  public var committed: String?

  public init(itemID: String, draft: String?, committed: String?) {
    self.itemID = itemID
    self.draft = draft
    self.committed = committed
  }
}

public struct CodexProjectedState: Codable, Equatable, Sendable {
  public var externalThreadID: String?
  public var messages: [ProjectedMessage]
  public var diagnostics: [String]
  public var terminalEvents: [String]
  public var outcome: CodexOperationOutcome

  public init(
    externalThreadID: String? = nil,
    messages: [ProjectedMessage] = [],
    diagnostics: [String] = [],
    terminalEvents: [String] = [],
    outcome: CodexOperationOutcome = .running
  ) {
    self.externalThreadID = externalThreadID
    self.messages = messages
    self.diagnostics = diagnostics
    self.terminalEvents = terminalEvents
    self.outcome = outcome
  }

  public func stableBytes() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}
