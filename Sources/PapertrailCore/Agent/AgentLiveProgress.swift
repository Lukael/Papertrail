import Foundation

public enum AgentLiveProgressKind: String, Equatable, Sendable {
  case status
  case reasoning
  case response
}

public struct AgentLiveProgress: Equatable, Sendable {
  public let kind: AgentLiveProgressKind
  public let itemID: String?
  public let text: String

  public init(kind: AgentLiveProgressKind, itemID: String? = nil, text: String) {
    self.kind = kind
    self.itemID = itemID
    self.text = text
  }

  static func visibleUpdate(for event: AgentEvent) -> AgentLiveProgress? {
    switch event.type {
    case "system" where event.subtype == "init":
      return .init(kind: .status, text: "Claude session started")
    case "assistant" where !event.isSynthetic:
      if let text = boundedVisibleText(
        event.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n\n"))
      {
        return .init(kind: .response, itemID: event.messageID, text: text)
      }
      if event.content.contains(where: { $0.type.hasSuffix("thinking") }) {
        // Current models omit thinking text by default; show the summary only when present.
        let summary = boundedVisibleText(
          event.content.filter { $0.type == "thinking" }.compactMap(\.text).joined())
        return .init(
          kind: .reasoning, itemID: event.messageID.map { "\($0):thinking" },
          text: summary ?? "Thinking…")
      }
      return nil
    case "result":
      return event.isError == true
        ? .init(kind: .status, text: "Claude reported that the turn failed")
        : .init(kind: .status, text: "Claude finished the response")
    default:
      // Tool, retry, and diagnostic records are deliberately excluded. Only bounded
      // Claude-authored text reaches the UI.
      return nil
    }
  }

  /// Reports thinking progress at most once per 500 estimated tokens so a long turn does not
  /// flood the UI with per-chunk counters.
  static func thinkingUpdate(estimatedTokens: Int, previouslyReported: inout Int)
    -> AgentLiveProgress?
  {
    guard estimatedTokens > 0,
      previouslyReported == 0 || estimatedTokens >= previouslyReported + 500
    else { return nil }
    previouslyReported = estimatedTokens
    return .init(
      kind: .reasoning, itemID: "thinking-tokens",
      text: "Thinking… (about \(estimatedTokens.formatted()) tokens)")
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
