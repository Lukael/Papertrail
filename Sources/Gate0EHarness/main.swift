import Foundation
import PapertrailCore

struct Gate0EOperationEvidence: Codable {
  let name: String
  let invocationArguments: [String]
  let inputThreadID: String?
  let projectedThreadID: String?
  let outcome: String
  let exitStatus: Int32
  let terminationReason: String
  let committedMessages: [String]
  let journalPath: String
  let journalSHA256: String
  let journalBytes: Int
  let retryDisposition: String
}

struct Gate0ELiveEvidence: Codable {
  let generatedAt: String
  let profile: String
  let capability: AgentCapabilityReport
  let operations: [Gate0EOperationEvidence]
  let assertions: [String: Bool]
  let residualAuthorityNote: String
}

@main
enum Gate0EHarness {
  static func main() throws {
    let args = CommandLine.arguments
    let executable = try AgentExecutableResolver().resolve(preferredPath: value("--claude", args))
    let workspace = URL(
      fileURLWithPath: value("--workspace", args) ?? FileManager.default.currentDirectoryPath,
      isDirectory: true)
    let output = URL(fileURLWithPath: value("--output", args) ?? "gate-0e-live.json")
    let evidenceRoot = output.deletingLastPathComponent().appendingPathComponent(
      "live-operations", isDirectory: true
    ).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(
      at: evidenceRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let capability = AgentCapabilityChecker().check(executableURL: executable)
    guard capability.status == .usable else {
      let evidence = capability.capabilityEvidence.joined(separator: ",")
      throw NSError(
        domain: "Gate0E", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(capability.detail) executable=\(capability.executablePath) version=\(capability.versionOutput) evidence=\(evidence)"
        ])
    }

    let new = try run(
      name: "new", executable: executable, workspace: workspace, evidenceRoot: evidenceRoot,
      kind: .new,
      prompt: "Name one primary color in a single short sentence, then end with the marker GATE0E_NEW_OK.")
    guard new.outcome == AgentOperationOutcome.turnCompleted.rawValue,
      let threadID = new.projectedThreadID
    else { throw failure("real new operation did not complete") }
    let resumed = try run(
      name: "resume", executable: executable, workspace: workspace, evidenceRoot: evidenceRoot,
      kind: .resume(sessionID: threadID),
      prompt: "Which color did you name in your previous answer? Answer in one short sentence, then end with the marker GATE0E_RESUME_OK.")
    guard resumed.outcome == AgentOperationOutcome.turnCompleted.rawValue else {
      throw failure("real resume operation did not complete")
    }
    let cancelled = try run(
      name: "cancel", executable: executable, workspace: workspace, evidenceRoot: evidenceRoot,
      kind: .new,
      prompt: "Write a detailed 3000-word essay on the history of measurement units, then reply GATE0E_CANCEL_TOO_LATE.",
      cancelAfterMilliseconds: 500)
    guard cancelled.outcome == AgentOperationOutcome.cancelled.rawValue else {
      throw failure("real cancellation did not reconcile as cancelled")
    }
    let retry = try run(
      name: "retry-after-cancel", executable: executable, workspace: workspace,
      evidenceRoot: evidenceRoot, kind: .new,
      prompt: "Give one sentence about why units of measurement matter, then end with the marker GATE0E_RETRY_OK.")
    guard retry.outcome == AgentOperationOutcome.turnCompleted.rawValue else {
      throw failure("real retry did not complete")
    }
    let operations = [new, resumed, cancelled, retry]
    let report = Gate0ELiveEvidence(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      profile: "private local/ad-hoc direct Claude Code CLI with no tools",
      capability: capability, operations: operations,
      assertions: [
        "new_completed": true,
        "resume_used_exact_external_thread": resumed.inputThreadID == threadID,
        "resume_kept_session_id": resumed.projectedThreadID == threadID,
        "new_and_resume_answered": new.committedMessages.joined().contains("GATE0E_NEW_OK")
          && resumed.committedMessages.joined().contains("GATE0E_RESUME_OK"),
        "cancelled_truthfully": cancelled.outcome == "cancelled",
        "retry_is_new_explicit_operation": retry.inputThreadID == nil,
        "dangerous_flags_absent": operations.allSatisfy {
          !$0.invocationArguments.contains(where: { $0.hasPrefix("--dangerously") })
        },
        "journals_nonempty": operations.allSatisfy { $0.journalBytes > 0 },
      ],
      residualAuthorityNote:
        "This verifies process semantics for headless Claude Code turns with no tools, MCP servers, or user settings. It does not claim notarization, Developer ID, or App Store distribution.")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .atomic)
    print("PASS: real Claude new/resume/cancel/retry evidence written to \(output.path)")
  }

  private static func run(
    name: String, executable: URL, workspace: URL, evidenceRoot: URL,
    kind: AgentInvocation.Kind, prompt: String, cancelAfterMilliseconds: Int? = nil
  ) throws -> Gate0EOperationEvidence {
    let invocation = try AgentInvocation(
      executableURL: executable, kind: kind,
      systemPrompt: "PAPERTRAIL_GATE0E_HARNESS\nYou are a concise, friendly assistant.",
      prompt: prompt, workingDirectory: workspace)
    let directory = evidenceRoot.appendingPathComponent(name, isDirectory: true)
    let journal = try OperationJournal(directoryURL: directory)
    let cancellation = AgentCancellationToken()
    if let milliseconds = cancelAfterMilliseconds {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + .milliseconds(milliseconds)) { cancellation.cancel() }
    }
    let result = try DirectProcessAgentTransport().execute(
      invocation, journal: journal, cancellation: cancellation,
      policy: AgentTransportPolicy(timeout: 90, terminationGrace: 1))
    try DiagnosticExporter().writeRedactedStderr(
      result.stderr, to: directory.appendingPathComponent("stderr.log"))
    let inputThread: String?
    if case .resume(let threadID) = kind { inputThread = threadID } else { inputThread = nil }
    let fingerprint = try FileFingerprint.read(journal.eventsURL)
    return Gate0EOperationEvidence(
      name: name, invocationArguments: invocation.arguments, inputThreadID: inputThread,
      projectedThreadID: result.state.externalThreadID,
      outcome: result.state.outcome.rawValue, exitStatus: result.exitStatus,
      terminationReason: result.terminationReason == .exit ? "exit" : "signal",
      committedMessages: result.state.messages.compactMap(\.committed),
      journalPath: journal.eventsURL.path, journalSHA256: fingerprint.sha256,
      journalBytes: fingerprint.byteCount, retryDisposition: result.retryDisposition.rawValue)
  }

  private static func value(_ flag: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "Gate0E", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
