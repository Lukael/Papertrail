import Foundation
import PapertrailCore

struct AgentModelSelection: Identifiable, Equatable, Sendable {
  let rawValue: String
  let title: String
  let supportedEfforts: [AgentReasoningEffort]

  static let automatic = Self(rawValue: "automatic", title: "Claude default", supportedEfforts: [])
  static let defaultsKey = "selectedClaudeModel"
  static let reviewDefaultsKey = "selectedClaudeReviewModel"

  var id: String { rawValue }
  var commandLineValue: String? { self == .automatic ? nil : rawValue }

  init(model: AgentModelDescriptor) {
    rawValue = model.model
    title = model.displayName
    supportedEfforts = model.supportedReasoningEfforts.filter { $0 != .automatic }
  }

  private init(rawValue: String, title: String, supportedEfforts: [AgentReasoningEffort]) {
    self.rawValue = rawValue
    self.title = title
    self.supportedEfforts = supportedEfforts
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

  static let choices = [automatic] + AgentModelCatalog.models.map(Self.init)

  /// A saved value outside the fixed catalog (for example a stale identifier) falls back to the
  /// Claude Code default instead of being passed to `--model`.
  static func load(defaults: UserDefaults = .standard, key: String = defaultsKey) -> Self {
    guard let value = defaults.string(forKey: key) else { return .automatic }
    return choices.first(where: { $0.rawValue == value }) ?? .automatic
  }

  func save(defaults: UserDefaults = .standard, key: String = Self.defaultsKey) {
    defaults.set(rawValue, forKey: key)
  }
}

extension AgentReasoningEffort {
  static let chatDefaultsKey = "selectedClaudeReasoningEffort"
  static let reviewDefaultsKey = "selectedClaudeReviewReasoningEffort"

  var title: String {
    switch self {
    case .automatic: "Model default"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  static func load(defaults: UserDefaults = .standard, key: String = chatDefaultsKey) -> Self {
    guard let value = defaults.string(forKey: key) else { return .automatic }
    return Self(rawValue: value) ?? .automatic
  }

  func save(defaults: UserDefaults = .standard, key: String = Self.chatDefaultsKey) {
    defaults.set(rawValue, forKey: key)
  }
}
