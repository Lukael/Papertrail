import Foundation
import PapertrailCore

@main
enum CodexModelSelectionTests {
  static func main() throws {
    let suite = "CodexModelSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    precondition(CodexModelSelection.load(defaults: defaults) == .automatic)
    CodexModelSelection.automatic.save(defaults: defaults)
    precondition(CodexModelSelection.load(defaults: defaults) == .automatic)
    precondition(CodexModelSelection.load(defaults: defaults).commandLineValue == nil)

    let ultra = CodexReasoningEffort(rawValue: "ultra")!
    let model = CodexModelDescriptor(
      model: "gpt-future", displayName: "Future Model", hidden: false, isDefault: true,
      defaultReasoningEffort: .medium, supportedReasoningEfforts: [.medium, ultra])
    let selection = CodexModelSelection(model: model)
    selection.save(defaults: defaults)
    precondition(CodexModelSelection.load(defaults: defaults).commandLineValue == "gpt-future")
    precondition(
      CodexModelSelection.initialChoices(defaults: defaults).map(\.rawValue) == [
        "automatic", "gpt-future",
      ])

    CodexModelSelection.cache([model], defaults: defaults)
    let restored = CodexModelSelection.load(defaults: defaults)
    precondition(restored == selection && restored.title == "Future Model")
    precondition(restored.supportedEfforts == [.medium, ultra])
    precondition(CodexModelSelection.cachedModels(defaults: defaults) == [model])
    precondition(CodexModelSelection.initialChoices(defaults: defaults).count == 2)
    ultra.save(defaults: defaults)
    precondition(CodexReasoningEffort.load(defaults: defaults) == ultra && ultra.title == "Ultra")

    defaults.set(Data("broken cache".utf8), forKey: "codexModelCatalog")
    precondition(CodexModelSelection.cachedModels(defaults: defaults).isEmpty)
    precondition(CodexModelSelection.load(defaults: defaults) == selection)
    defaults.set("gpt\"; invalid", forKey: CodexModelSelection.defaultsKey)
    precondition(CodexModelSelection.load(defaults: defaults) == .automatic)
    print(
      "PASS model selection: dynamic models/efforts, default persistence, offline selection, cache corruption"
    )
    let arguments = ProcessInfo.processInfo.arguments
    if let flag = arguments.firstIndex(of: "--codex"), arguments.indices.contains(flag + 1) {
      let models = try CodexModelCatalog().fetch(
        executableURL: URL(fileURLWithPath: arguments[flag + 1]))
      precondition(!models.isEmpty && models.allSatisfy { !$0.hidden })
      print(
        "PASS live Codex catalog: \(models.count) models, \(Set(models.flatMap(\.supportedReasoningEfforts)).count) reasoning efforts"
      )
    }
  }
}
