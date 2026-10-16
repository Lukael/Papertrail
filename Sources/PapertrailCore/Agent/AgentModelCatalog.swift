import Foundation

public struct AgentModelDescriptor: Codable, Equatable, Sendable, Identifiable {
  public var id: String { model }
  /// Value passed to `claude --model`. Family aliases follow the newest model the account can use.
  public let model: String
  public let displayName: String
  public let supportedReasoningEfforts: [AgentReasoningEffort]

  public init(
    model: String, displayName: String, supportedReasoningEfforts: [AgentReasoningEffort]
  ) {
    self.model = model
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
  }
}

/// Claude Code has no model-listing command, so Papertrail offers the family aliases the CLI
/// resolves itself. Current Opus, Sonnet, and Haiku models accept every `--effort` level.
public enum AgentModelCatalog {
  public static let allEfforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh, .max]

  public static let models: [AgentModelDescriptor] = [
    .init(model: "opus", displayName: "Claude Opus", supportedReasoningEfforts: allEfforts),
    .init(model: "sonnet", displayName: "Claude Sonnet", supportedReasoningEfforts: allEfforts),
    .init(model: "haiku", displayName: "Claude Haiku", supportedReasoningEfforts: allEfforts),
  ]

  public static func descriptor(for model: String) -> AgentModelDescriptor? {
    models.first(where: { $0.model == model })
  }
}
