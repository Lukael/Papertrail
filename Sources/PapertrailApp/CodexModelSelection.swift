import Foundation
import PapertrailCore

struct CodexModelSelection: Identifiable, Equatable, Sendable {
  let rawValue: String
  let title: String
  let supportedEfforts: [CodexReasoningEffort]

  static let automatic = Self(rawValue: "automatic", title: "Codex default", supportedEfforts: [])
  static let defaultsKey = "selectedCodexModel"
  private static let cacheKey = "codexModelCatalog"

  var id: String { rawValue }
  var commandLineValue: String? { self == .automatic ? nil : rawValue }

  init(model: CodexModelDescriptor) {
    rawValue = model.model
    title = model.displayName
    supportedEfforts = model.supportedReasoningEfforts.filter { $0 != .automatic }
  }

  private init(rawValue: String, title: String, supportedEfforts: [CodexReasoningEffort]) {
    self.rawValue = rawValue
    self.title = title
    self.supportedEfforts = supportedEfforts
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

  static func load(defaults: UserDefaults = .standard) -> Self {
    guard let value = defaults.string(forKey: defaultsKey), value != automatic.rawValue,
      CodexInvocation.isValidModelIdentifier(value)
    else { return .automatic }
    return cachedModels(defaults: defaults).first(where: { $0.model == value }).map(Self.init)
      ?? Self(rawValue: value, title: value, supportedEfforts: [])
  }

  static func initialChoices(defaults: UserDefaults = .standard) -> [Self] {
    var models = [Self.automatic] + cachedModels(defaults: defaults).map(Self.init)
    let selected = load(defaults: defaults)
    if !models.contains(selected) { models.append(selected) }
    return models
  }

  static func cachedModels(defaults: UserDefaults = .standard) -> [CodexModelDescriptor] {
    guard let data = defaults.data(forKey: cacheKey), data.count <= 4_194_304,
      let models = try? JSONDecoder().decode([CodexModelDescriptor].self, from: data)
    else { return [] }
    return models.filter { !$0.hidden }
  }

  static func cache(_ models: [CodexModelDescriptor], defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(models), data.count <= 4_194_304 else { return }
    defaults.set(data, forKey: cacheKey)
  }

  func save(defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

extension CodexReasoningEffort {
  private static let defaultsKey = "selectedCodexReasoningEffort"

  var title: String {
    switch self {
    case .automatic: "Model default"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  static func load(defaults: UserDefaults = .standard) -> Self {
    guard let value = defaults.string(forKey: defaultsKey) else { return .automatic }
    return Self(rawValue: value) ?? .automatic
  }

  func save(defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}
