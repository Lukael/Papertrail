import Foundation

public enum ChatOutcomePresentation {
  public static func message(
    outcome: AgentOperationOutcome, replacementCompleted: Bool = false
  ) -> String {
    switch outcome {
    case .turnCompleted:
      return replacementCompleted
        ? "The unavailable session was replaced and the retried turn completed; prior lineage was preserved."
        : "Claude turn completed."
    case .cancelled:
      return "The turn was cancelled. Its durable message can be retried."
    case .failed:
      return "Claude reported a failed turn. No success is claimed; retry is available. If Claude Code is logged out, run `claude auth login` in Terminal."
    case .interrupted:
      return "The child process was interrupted. Accepted journal data was preserved for recovery."
    case .protocolFailure:
      return "Claude Code output violated the supported protocol. The accepted journal prefix was preserved."
    case .timedOut:
      return "The bounded Claude operation timed out. No completion is claimed."
    case .running:
      return "Claude is still running."
    }
  }
}
