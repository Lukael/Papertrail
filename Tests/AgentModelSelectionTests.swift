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

    // Review documents keep their own selection, so changing one never moves the other.
    let haiku = AgentModelSelection.choices[3]
    haiku.save(defaults: defaults, key: AgentModelSelection.reviewDefaultsKey)
    AgentReasoningEffort.high.save(defaults: defaults, key: AgentReasoningEffort.reviewDefaultsKey)
    precondition(
      AgentModelSelection.load(defaults: defaults, key: AgentModelSelection.reviewDefaultsKey)
        == haiku && AgentModelSelection.load(defaults: defaults) == sonnet)
    precondition(
      AgentReasoningEffort.load(defaults: defaults, key: AgentReasoningEffort.reviewDefaultsKey)
        == .high && AgentReasoningEffort.load(defaults: defaults) == .max)

    // Codex-era or tampered identifiers fall back to the Claude Code default and never reach --model.
    for stale in ["gpt-5.5", "gpt\"; invalid", "opus;rm", ""] {
      defaults.set(stale, forKey: AgentModelSelection.defaultsKey)
      precondition(AgentModelSelection.load(defaults: defaults) == .automatic)
    }
    print(
      "PASS model selection: fixed Claude families, separate chat/review choices, stale identifiers fall back"
    )
  }
}
