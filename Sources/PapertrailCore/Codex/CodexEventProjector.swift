import Foundation

public enum CodexProjectionError: Error, Equatable {
  case conflictingThreadIDs
  case missingAgentMessageFields
  case conflictingTurnIDs
  case terminalTurnIDWithoutStartedTurnID
  case terminalMissingBoundTurnID
}

public struct CodexEventProjector: Sendable {
  private(set) public var state = CodexProjectedState()
  private var seen = Set<String>()
  private var boundTurnID: String?

  public init() {}

  public mutating func project(_ event: CodexEvent) throws {
    guard seen.insert(event.deduplicationKey).inserted else { return }

    switch event.type {
    case "thread.started":
      guard let threadID = event.threadID, !threadID.isEmpty else {
        throw CodexEventError.missingRequiredField("thread_id")
      }
      if let existing = state.externalThreadID, existing != threadID {
        throw CodexProjectionError.conflictingThreadIDs
      }
      state.externalThreadID = threadID

    case "turn.started":
      if let turnID = event.turnID {
        if let existing = boundTurnID, existing != turnID {
          throw CodexProjectionError.conflictingTurnIDs
        }
        boundTurnID = turnID
      }

    case "item.started", "item.updated", "item.completed":
      guard event.itemType == "agent_message" else { return }
      guard let itemID = event.itemID, let text = event.text else {
        throw CodexProjectionError.missingAgentMessageFields
      }
      let index: Int
      if let existing = state.messages.firstIndex(where: { $0.itemID == itemID }) {
        index = existing
      } else {
        state.messages.append(ProjectedMessage(itemID: itemID, draft: nil, committed: nil))
        index = state.messages.count - 1
      }
      if event.type == "item.completed" {
        state.messages[index].committed = text
        state.messages[index].draft = nil
      } else if state.messages[index].committed == nil {
        state.messages[index].draft = text
      }

    case "turn.completed", "turn.failed":
      if let terminalTurnID = event.turnID {
        guard let boundTurnID else {
          throw CodexProjectionError.terminalTurnIDWithoutStartedTurnID
        }
        guard boundTurnID == terminalTurnID else {
          throw CodexProjectionError.conflictingTurnIDs
        }
      } else if boundTurnID != nil {
        throw CodexProjectionError.terminalMissingBoundTurnID
      }
      state.terminalEvents.append(event.type + (event.turnID.map { ":\($0)" } ?? ""))

    case "error":
      if let message = event.message { state.diagnostics.append(message) }

    default:
      break
    }
  }

  public mutating func reconcile(
    exitStatus: Int32,
    terminationReason: Process.TerminationReason = .exit,
    cancellationRequested: Bool,
    timedOut: Bool = false,
    expectedTurnID: String? = nil,
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
    let completed = state.terminalEvents.filter { $0.hasPrefix("turn.completed") }
    let failed = state.terminalEvents.filter { $0.hasPrefix("turn.failed") }
    if !failed.isEmpty {
      state.outcome = completed.isEmpty ? .failed : .protocolFailure
      return
    }
    guard completed.count == 1, exitStatus == 0 else {
      state.outcome = .protocolFailure
      return
    }
    if let expectedTurnID, completed[0] != "turn.completed:\(expectedTurnID)" {
      state.outcome = .protocolFailure
      return
    }
    state.outcome = .turnCompleted
  }
}
