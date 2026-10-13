import Foundation

public enum AgentProjectionError: Error, Equatable {
  case conflictingSessionIDs
  case missingAssistantMessageFields
  /// The `init` event listed tools although every invocation passes `--tools ""`.
  case toolsEnabled([String])
  /// The model emitted a tool call although it was given no tools.
  case unexpectedToolUse
}

public struct AgentEventProjector: Sendable {
  private(set) public var state = AgentProjectedState()
  private var seen = Set<String>()

  public init() {}

  public mutating func project(_ event: AgentEvent) throws {
    guard seen.insert(event.deduplicationKey).inserted else { return }

    switch event.type {
    case "system" where event.subtype == "init":
      guard let sessionID = event.sessionID, !sessionID.isEmpty else {
        throw AgentEventError.missingRequiredField("session_id")
      }
      try bind(sessionID)
      if let tools = event.tools, !tools.isEmpty {
        throw AgentProjectionError.toolsEnabled(tools)
      }

    case "assistant":
      if event.content.contains(where: { $0.type.hasSuffix("tool_use") }) {
        throw AgentProjectionError.unexpectedToolUse
      }
      let text = event.content.filter { $0.type == "text" }.compactMap(\.text)
        .joined(separator: "\n\n")
      if event.isSynthetic {
        if !text.isEmpty { state.diagnostics.append(String(text.prefix(2_048))) }
        return
      }
      guard !text.isEmpty else { return }
      guard let messageID = event.messageID, !messageID.isEmpty else {
        throw AgentProjectionError.missingAssistantMessageFields
      }
      // Without partial-message streaming every assistant record carries complete blocks of
      // one API message, so each record extends that message's committed text.
      if let index = state.messages.firstIndex(where: { $0.itemID == messageID }) {
        let prior = state.messages[index].committed ?? ""
        state.messages[index].committed = prior.isEmpty ? text : prior + "\n\n" + text
      } else {
        state.messages.append(ProjectedMessage(itemID: messageID, draft: nil, committed: text))
      }

    case "user":
      if event.content.contains(where: { $0.type == "tool_result" }) {
        throw AgentProjectionError.unexpectedToolUse
      }

    case "result":
      if let sessionID = event.sessionID, !sessionID.isEmpty { try bind(sessionID) }
      if event.isError == true {
        state.terminalEvents.append("result.error:\(event.subtype ?? "unknown")")
        if let text = event.resultText, !text.isEmpty {
          state.diagnostics.append(String(text.prefix(2_048)))
        } else if let reason = event.terminalReason {
          state.diagnostics.append(reason)
        }
      } else {
        state.terminalEvents.append("result.success")
        state.resultText = event.resultText
      }

    default:
      break
    }
  }

  private mutating func bind(_ sessionID: String) throws {
    if let existing = state.externalThreadID, existing != sessionID {
      throw AgentProjectionError.conflictingSessionIDs
    }
    state.externalThreadID = sessionID
  }

  public mutating func reconcile(
    exitStatus: Int32,
    terminationReason: Process.TerminationReason = .exit,
    cancellationRequested: Bool,
    timedOut: Bool = false,
    framingCompleted: Bool = true
  ) {
    if timedOut {
      state.outcome = .timedOut
      return
    }
    if cancellationRequested {
      state.outcome = .cancelled
      return
    }
    if terminationReason == .uncaughtSignal {
      state.outcome = .interrupted
      return
    }
    guard framingCompleted else {
      state.outcome = .protocolFailure
      return
    }
    switch state.terminalEvents.count {
    case 0:
      // The CLI rejected the invocation before streaming (bad option, missing login, crash).
      state.outcome = exitStatus == 0 ? .protocolFailure : .failed
    case 1 where state.terminalEvents[0].hasPrefix("result.error"):
      state.outcome = .failed
    case 1 where exitStatus == 0:
      state.outcome = .turnCompleted
    default:
      state.outcome = .protocolFailure
    }
  }
}
