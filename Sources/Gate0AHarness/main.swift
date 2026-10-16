import Foundation
import PapertrailCore

struct Gate0AEvidence: Codable {
  let generatedAt: String
  let profile: String
  let capability: AgentCapabilityReport
  let newArguments: [String]
  let resumeArguments: [String]
  let promptIsStandardInput: Bool
  let prohibitedFlagsAbsent: Bool
  let notes: [String]
  let liveProbe: LiveProbeEvidence?
}

struct LiveProbeEvidence: Codable {
  let outcome: AgentOperationOutcome
  let threadID: String?
  let committedMessages: [String]
  let resultText: String?
  let diagnostics: [String]
  let exitStatus: Int32
  let journalPath: String
}

@main
enum Gate0AHarness {
  static func main() throws {
    let arguments = CommandLine.arguments
    let preferred = value(after: "--claude", in: arguments)
    let outputPath = value(after: "--output", in: arguments) ?? "gate-0a-capability.json"
    let workspacePath =
      value(after: "--workspace", in: arguments) ?? FileManager.default.currentDirectoryPath
    let executable = try AgentExecutableResolver().resolve(preferredPath: preferred)
    let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
    let prompt =
      "Gate 0A prompt with hostile shell-looking text: '; $(touch outside) --dangerously-skip-permissions"
    let newInvocation = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: systemPrompt, prompt: prompt,
      workingDirectory: workspace)
    let resumeInvocation = try AgentInvocation(
      executableURL: executable, kind: .resume(sessionID: "019TEST-session"),
      systemPrompt: systemPrompt, prompt: prompt, workingDirectory: workspace)
    let liveProbe = try runLiveProbeIfRequested(
      arguments: arguments, executable: executable, workspace: workspace)
    let report = Gate0AEvidence(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      profile: "private local/ad-hoc non-sandboxed harness",
      capability: AgentCapabilityChecker().check(executableURL: executable),
      newArguments: newInvocation.arguments,
      resumeArguments: resumeInvocation.arguments,
      promptIsStandardInput: newInvocation.standardInput == Data(prompt.utf8)
        && !newInvocation.arguments.contains(where: { $0.contains("touch outside") }),
      prohibitedFlagsAbsent: !newInvocation.arguments.contains(where: {
        $0.hasPrefix("--dangerously")
      }) && newInvocation.arguments.starts(with: ["-p", "--output-format", "stream-json"]),
      notes: [
        "This report does not claim notarization, Developer-ID distribution, App Store compatibility, or sandbox containment.",
        "Capability checks invoke the CLI only; authentication state comes from `claude auth status`, and Papertrail reads no credential file.",
      ],
      liveProbe: liveProbe
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    print("Gate 0A capability report written to \(outputPath)")
  }

  private static let systemPrompt =
    "PAPERTRAIL_GATE0A_HARNESS: You are a test probe. Answer exactly as instructed and briefly."

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func runLiveProbeIfRequested(
    arguments: [String], executable: URL, workspace: URL
  ) throws -> LiveProbeEvidence? {
    guard let prompt = value(after: "--live-prompt", in: arguments) else { return nil }
    let kind: AgentInvocation.Kind
    if let sessionID = value(after: "--resume-session", in: arguments) {
      kind = .resume(sessionID: sessionID)
    } else if arguments.contains("--ephemeral") {
      kind = .ephemeral
    } else {
      kind = .new
    }
    let invocation = try AgentInvocation(
      executableURL: executable, kind: kind, systemPrompt: systemPrompt, prompt: prompt,
      workingDirectory: workspace,
      model: value(after: "--model", in: arguments),
      reasoningEffort: value(after: "--effort", in: arguments).flatMap(AgentReasoningEffort.init))
    let journalPath =
      value(after: "--journal", in: arguments)
      ?? workspace.appendingPathComponent("gate0a-live-operation").path
    let journal = try OperationJournal(directoryURL: URL(fileURLWithPath: journalPath))
    let cancellation = AgentCancellationToken()
    if let milliseconds = value(after: "--cancel-after-ms", in: arguments).flatMap(Int.init) {
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
        cancellation.cancel()
      }
    }
    let result = try DirectProcessAgentTransport().execute(
      invocation, journal: journal, cancellation: cancellation)
    try DiagnosticExporter().writeRedactedStderr(
      result.stderr, to: URL(fileURLWithPath: journalPath).appendingPathComponent("stderr.log"))
    return LiveProbeEvidence(
      outcome: result.state.outcome,
      threadID: result.state.externalThreadID,
      committedMessages: result.state.messages.compactMap(\.committed),
      resultText: result.state.resultText,
      diagnostics: result.state.diagnostics,
      exitStatus: result.exitStatus,
      journalPath: journal.eventsURL.path)
  }
}
