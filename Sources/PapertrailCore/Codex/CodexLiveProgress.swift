import Foundation

public enum CodexLiveProgressKind: String, Equatable, Sendable {
  case status
  case reasoning
  case response
}

public struct CodexLiveProgress: Equatable, Sendable {
  public let kind: CodexLiveProgressKind
  public let itemID: String?
  public let text: String

  public init(kind: CodexLiveProgressKind, itemID: String? = nil, text: String) {
    self.kind = kind
    self.itemID = itemID
    self.text = text
  }

  static func visibleUpdate(for event: CodexEvent) -> CodexLiveProgress? {
    switch event.type {
    case "thread.started":
      return .init(kind: .status, text: "Codex review session started")
    case "turn.started":
      return .init(kind: .status, text: "Reading and analyzing the paper…")
    case "item.started" where event.itemType == "reasoning":
      return .init(kind: .reasoning, itemID: event.itemID, text: "Thinking…")
    case "item.updated", "item.completed", "reasoning.completed":
      guard let text = boundedVisibleText(event.text), !text.isEmpty else { return nil }
      switch event.itemType {
      case "reasoning":
        return .init(kind: .reasoning, itemID: event.itemID, text: text)
      case "agent_message":
        return .init(kind: .response, itemID: event.itemID, text: text)
      default:
        return nil
      }
    case "turn.completed":
      return .init(kind: .status, text: "Codex response completed; validating review files…")
    case "turn.failed":
      return .init(kind: .status, text: "Codex reported that the review turn failed")
    default:
      // Raw reasoning deltas, command output, paths, and diagnostics are deliberately
      // excluded. Only bounded Codex-authored summaries/messages reach the UI.
      return nil
    }
  }

  private static func boundedVisibleText(_ value: String?) -> String? {
    guard let value else { return nil }
    let filtered = value.unicodeScalars.filter {
      $0.value == 0x0A || $0.value == 0x09 || $0.value >= 0x20
    }
    let normalized = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(4_000))
  }
}
