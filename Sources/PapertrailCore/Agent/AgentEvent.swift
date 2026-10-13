import CryptoKit
import Foundation

public enum AgentEventError: Error, Equatable {
  case invalidJSON
  case missingRequiredField(String)
}

public struct AgentContentBlock: Equatable, Sendable {
  public let type: String
  public let text: String?
  public let toolName: String?
}

/// One Claude Code `--output-format stream-json` record. Only the fields Papertrail projects
/// are decoded; the canonical bytes are journaled unchanged before projection.
public struct AgentEvent: Equatable, Sendable {
  /// Claude Code labels locally generated error messages (authentication, API failures)
  /// with this model name. They are diagnostics, never assistant answers.
  public static let syntheticModel = "<synthetic>"

  public let type: String
  public let subtype: String?
  public let sessionID: String?
  public let messageID: String?
  public let model: String?
  public let content: [AgentContentBlock]
  public let tools: [String]?
  public let isError: Bool?
  public let resultText: String?
  public let terminalReason: String?
  public let canonicalRaw: Data

  public init(raw: Data) throws {
    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let type = object["type"] as? String
    else {
      throw AgentEventError.invalidJSON
    }
    self.type = type
    subtype = object["subtype"] as? String
    sessionID = object["session_id"] as? String
    tools = (object["tools"] as? [Any])?.map { ($0 as? String) ?? String(describing: $0) }
    isError = object["is_error"] as? Bool
    resultText = object["result"] as? String
    terminalReason = object["terminal_reason"] as? String
    if let message = object["message"] as? [String: Any] {
      messageID = message["id"] as? String
      model = message["model"] as? String
      content = (message["content"] as? [Any] ?? []).compactMap { element in
        guard let block = element as? [String: Any], let blockType = block["type"] as? String
        else { return nil }
        return AgentContentBlock(
          type: blockType,
          text: (block["text"] as? String) ?? (block["thinking"] as? String),
          toolName: block["name"] as? String)
      }
    } else {
      messageID = nil
      model = nil
      content = []
    }
    canonicalRaw = raw
  }

  public var isSynthetic: Bool { model == Self.syntheticModel }

  public var deduplicationKey: String {
    let digest = SHA256.hash(data: canonicalRaw).map { String(format: "%02x", $0) }.joined()
    if let messageID { return "\(type):message:\(messageID):\(digest)" }
    if let sessionID { return "\(type):session:\(sessionID):\(digest)" }
    return "\(type):raw:\(digest)"
  }
}

public enum AgentOperationOutcome: String, Codable, Equatable, Sendable {
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

public struct AgentProjectedState: Codable, Equatable, Sendable {
  /// Claude Code session ID reported by the `init` event; persisted as the external thread.
  public var externalThreadID: String?
  public var messages: [ProjectedMessage]
  public var diagnostics: [String]
  public var terminalEvents: [String]
  public var outcome: AgentOperationOutcome
  /// Final text of a successful `result` event; review generation parses its JSON document.
  public var resultText: String?

  public init(
    externalThreadID: String? = nil,
    messages: [ProjectedMessage] = [],
    diagnostics: [String] = [],
    terminalEvents: [String] = [],
    outcome: AgentOperationOutcome = .running,
    resultText: String? = nil
  ) {
    self.externalThreadID = externalThreadID
    self.messages = messages
    self.diagnostics = diagnostics
    self.terminalEvents = terminalEvents
    self.outcome = outcome
    self.resultText = resultText
  }

  public func stableBytes() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}
