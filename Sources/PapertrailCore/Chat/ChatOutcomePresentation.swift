import Foundation

public enum ChatOutcomePresentation {
  public static func message(
    outcome: CodexOperationOutcome, replacementCompleted: Bool = false
  ) -> String {
    switch outcome {
    case .turnCompleted:
      return replacementCompleted
        ? "The unavailable thread was replaced and the retried turn completed; prior lineage was preserved."
        : "Codex turn completed."
    case .cancelled:
      return "The turn was cancelled. Its durable message can be retried."
    case .failed:
      return "Codex reported a failed turn. No success is claimed; retry is available."
    case .interrupted:
      return "The child process was interrupted. Accepted journal data was preserved for recovery."
    case .protocolFailure:
      return "Codex output violated the supported protocol. The accepted journal prefix was preserved."
    case .timedOut:
      return "The bounded Codex operation timed out. No completion is claimed."
    case .running:
      return "Codex is still running."
    }
  }
}
