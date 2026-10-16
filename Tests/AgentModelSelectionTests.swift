import Foundation
import PapertrailCore

@main
enum AgentModelSelectionTests {
  static func main() throws {
    let suite = "AgentModelSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    precondition(AgentModelSelection.load(defaults: defaults) == .automatic)
    AgentModelSelection.automatic.save(defaults: defaults)
    precondition(AgentModelSelection.load(defaults: defaults) == .automatic)
    precondition(AgentModelSelection.load(defaults: defaults).commandLineValue == nil)
    precondition(
      AgentModelSelection.choices.map(\.rawValue) == ["automatic", "opus", "sonnet", "haiku"])

    let sonnet = AgentModelSelection.choices[2]
    sonnet.save(defaults: defaults)
    let restored = AgentModelSelection.load(defaults: defaults)
    precondition(restored == sonnet && restored.title == "Claude Sonnet")
    precondition(restored.commandLineValue == "sonnet")
    precondition(restored.supportedEfforts == [.low, .medium, .high, .xhigh, .max])
    AgentReasoningEffort.max.save(defaults: defaults)
    precondition(
      AgentReasoningEffort.load(defaults: defaults) == .max && AgentReasoningEffort.max.title == "Max")

    // Codex-era or tampered identifiers fall back to the Claude Code default and never reach --model.
    for stale in ["gpt-5.5", "gpt\"; invalid", "opus;rm", ""] {
      defaults.set(stale, forKey: AgentModelSelection.defaultsKey)
      precondition(AgentModelSelection.load(defaults: defaults) == .automatic)
    }
    print(
      "PASS model selection: fixed Claude families, effort persistence, stale identifiers fall back"
    )
  }
}
