import Foundation
import PapertrailCore

enum CodexModelSelection: String, CaseIterable, Identifiable {
  case automatic
  case gpt55 = "gpt-5.5"
  case gpt54 = "gpt-5.4"
  case gpt56Sol = "gpt-5.6-sol"
  case gpt56Terra = "gpt-5.6-terra"
  case gpt56Luna = "gpt-5.6-luna"

  static let defaultsKey = "selectedCodexModel"

  var id: String { rawValue }

  var commandLineValue: String? { self == .automatic ? nil : rawValue }

  var title: String {
    switch self {
    case .automatic: "Codex default"
    case .gpt55: "GPT-5.5"
    case .gpt54: "GPT-5.4"
    case .gpt56Sol: "GPT-5.6 Sol"
    case .gpt56Terra: "GPT-5.6 Terra"
    case .gpt56Luna: "GPT-5.6 Luna"
    }
  }

  static func load() -> Self {
    let value = UserDefaults.standard.string(forKey: defaultsKey)
    // Upgrade the initial preference from the former CLI-default mode so all new work uses
    // the requested stable model profile without requiring the user to reselect it.
    guard let value, value != automatic.rawValue else { return .gpt56Terra }
    return Self(rawValue: value) ?? .gpt56Terra
  }

  func save() { UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey) }
}

extension CodexReasoningEffort {
  private static let defaultsKey = "selectedCodexReasoningEffort"

  var title: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    }
  }

  static func load() -> Self {
    guard let value = UserDefaults.standard.string(forKey: defaultsKey) else { return .medium }
    return Self(rawValue: value) ?? .medium
  }

  func save() { UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey) }
}
