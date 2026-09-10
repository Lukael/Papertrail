import Darwin
import Foundation
import PapertrailCore

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

private final class LiveProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var updates: [CodexLiveProgress] = []
  func append(_ update: CodexLiveProgress) { lock.withLock { updates.append(update) } }
  func snapshot() -> [CodexLiveProgress] { lock.withLock { updates } }
}

@main
enum Gate0ATests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("invocation boundary", testInvocationBoundary),
      ("minimal environment", testMinimalEnvironment),
      ("JSONL framing", testFraming),
      ("projection and terminal reconciliation", testProjection),
      ("journal permissions, caps, replay", testJournal),
      ("journal rejects path and inode tampering", testJournalTampering),
      ("operation result sidecar round-trips with owner-only permissions", testOperationResultRoundTrip),
      ("operation result sidecar replacement is atomic and bounded", testOperationResultAtomicBound),
      ("operation result sidecar rejects a wrong operation ID", testOperationResultOperationID),
      ("operation result sidecar rejects a mismatched journal length", testOperationResultJournalLength),
      ("capability states", testCapabilityStates),
      ("resolver skips incompatible candidates", testResolverSkipsIncompatibleCandidate),
      ("transport accepted-prefix failures", testTransportAcceptedPrefix),
      ("transport live progress is bounded and filtered", testLiveProgress),
      ("stderr bound and cancellation", testTransportBoundsAndCancellation),
      ("transcript golden and omission", testTranscript),
    ]
    for (name, test) in tests {
      try test()
      print("PASS: \(name)")
    }
    print("PASS: \(tests.count) Gate 0A test groups")
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws
  {
    guard try condition() else { throw TestFailure(description: message) }
  }

  private static func expectError<T: Error & Equatable>(_ expected: T, _ body: () throws -> Void)
    throws
  {
    do {
      try body()
      throw TestFailure(description: "Expected \(expected), but no error was thrown")
    } catch let error as T {
      try expect(error == expected, "Expected \(expected), received \(error)")
    }
  }

  private static func testInvocationBoundary() throws {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    let prompt = #"paper'; $(touch /tmp/pwned); --dangerously-bypass-approvals-and-sandbox"#
    let new = try CodexInvocation(
      executableURL: executable, kind: .new, prompt: prompt, workingDirectory: workspace)
    try expect(
      new.arguments == [
        "exec", "--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "-",
      ],
      "new argument shape changed")
    try expect(new.standardInput == Data(prompt.utf8), "prompt was not preserved on stdin")
    try expect(!new.arguments.joined().contains("touch"), "untrusted prompt reached arguments")
    let selectedModel = try CodexInvocation(
      executableURL: executable, kind: .new, prompt: prompt, workingDirectory: workspace,
      model: "gpt-5.5", reasoningEffort: .medium)
    try expect(
      selectedModel.arguments == [
        "exec", "--model", "gpt-5.5", "--config", #"model_reasoning_effort="medium""#,
        "--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "-",
      ], "selected model and effort were not isolated to approved argument slots")
    let isolated = try CodexInvocation(
      executableURL: executable, kind: .new, prompt: prompt, workingDirectory: workspace,
      model: "gpt-5.6-terra", reasoningEffort: .medium, ignoreUserConfiguration: true)
    try expect(
      isolated.arguments == [
        "exec", "--model", "gpt-5.6-terra", "--config", #"model_reasoning_effort="medium""#,
        "--ignore-user-config", "--json", "--sandbox", "workspace-write",
        "--skip-git-repo-check", "-",
      ], "isolated invocation shape changed")
    let resume = try CodexInvocation(
      executableURL: executable, kind: .resume(threadID: "thread-123"), prompt: prompt,
      workingDirectory: workspace, reasoningEffort: .xhigh)
    try expect(
      resume.arguments == [
        "exec", "resume", "--config", #"model_reasoning_effort="xhigh""#, "--config",
        #"sandbox_mode="workspace-write""#, "--config",
        "sandbox_workspace_write.writable_roots=[\"\(workspace.path)\"]", "--json",
        "--skip-git-repo-check", "thread-123", "-",
      ],
      "resume argument shape changed")
    do {
      try CodexInvocation.validate(arguments: ["exec", "--dangerously-bypass-hook-trust", "-"])
      throw TestFailure(description: "dangerous flag was accepted")
    } catch is CodexInvocationError {}
    try expectError(CodexInvocationError.invalidModelIdentifier) {
      _ = try CodexInvocation(
        executableURL: executable, kind: .new, prompt: prompt, workingDirectory: workspace,
        model: "gpt-5.5;rm")
    }
    try expectError(CodexInvocationError.invalidReasoningEffort) {
      try CodexInvocation.validate(arguments: [
        "exec", "--config", "model_reasoning_effort=malicious", "--json", "--sandbox",
        "workspace-write", "--skip-git-repo-check", "-",
      ])
    }
    do {
      try CodexInvocation.validate(arguments: [
        "exec", "--config", "sandbox=danger-full-access", "--json", "--sandbox",
        "workspace-write", "--skip-git-repo-check", "-",
      ])
      throw TestFailure(description: "arbitrary config override was accepted")
    } catch is CodexInvocationError {}
    try expect(
      CodexInvocationError.executableNotRunnable.localizedDescription
        == "The Codex executable is not runnable.",
      "resolver failure lost its actionable description")
  }

  private static func testMinimalEnvironment() throws {
    let environment = CodexCapabilityChecker.minimalEnvironment(source: [
      "HOME": "/Users/test", "SECRET": "leak", "PATH": "/evil",
    ])
    try expect(environment["HOME"] == "/Users/test", "HOME was not preserved for CLI-owned auth")
    try expect(environment["SECRET"] == nil, "arbitrary environment leaked")
    try expect(!environment["PATH", default: ""].contains("/evil"), "untrusted PATH leaked")
  }

  private static func testFraming() throws {
    let line = Data(
      #"{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"한글"}}"#.utf8)
    let stream = line + Data([0x0A])
    for split in 0...stream.count {
      var framer = CodexJSONLFramer()
      var records = try framer.append(stream.prefix(split))
      records += try framer.append(stream.suffix(stream.count - split))
      try framer.finish()
      try expect(records == [line], "UTF-8 split failed at byte \(split)")
    }
    var partial = CodexJSONLFramer()
    _ = try partial.append(Data("{}".utf8))
    try expectError(CodexFramingError.partialRecordAtEOF) { try partial.finish() }
    var bounded = CodexJSONLFramer(maximumRecordBytes: 4)
    try expectError(CodexFramingError.recordTooLarge) {
      _ = try bounded.append(Data("12345".utf8))
    }

    let valid = Data("ok\n".utf8)
    var oversizedAfterPrefix = CodexJSONLFramer(maximumRecordBytes: 4)
    let oversizedBatch = oversizedAfterPrefix.consume(valid + Data("12345\n".utf8))
    try expect(
      oversizedBatch.records == [Data("ok".utf8)], "valid prefix was lost before oversized record")
    try expect(oversizedBatch.error == .recordTooLarge, "oversized suffix was not reported")

    var invalidAfterPrefix = CodexJSONLFramer(maximumRecordBytes: 16)
    let invalidBatch = invalidAfterPrefix.consume(valid + Data([0xFF, 0x0A]))
    try expect(
      invalidBatch.records == [Data("ok".utf8)], "valid prefix was lost before invalid UTF-8")
    try expect(invalidBatch.error == .invalidUTF8, "invalid UTF-8 suffix was not reported")
  }

  private static func testLiveProgress() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let longText = String(repeating: "x", count: 5_000)
    let script = try makeExecutable(
      in: root, name: "live-progress", contents: """
      #!/bin/sh
      cat >/dev/null
      printf '%s\n' '{"type":"thread.started","thread_id":"T1"}'
      printf '%s\n' '{"type":"turn.started","turn_id":"R1"}'
      printf '%s\n' '{"type":"reasoning.delta","text":"must-not-surface"}'
      printf '%s\n' '{"type":"reasoning.completed","item":{"id":"X","type":"reasoning","text":"checking evidence"}}'
      printf '%s\n' '{"type":"item.updated","item":{"id":"M1","type":"agent_message","text":"draft"}}'
      printf '%s\n' '{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"\(longText)"}}'
      printf '%s\n' '{"type":"turn.completed","turn_id":"R1"}'
      """)
    let journal = try OperationJournal(directoryURL: root.appendingPathComponent("journal"))
    let invocation = try CodexInvocation(
      executableURL: script, kind: .new, prompt: "test", workingDirectory: root)
    let box = LiveProgressBox()
    let result = try DirectProcessCodexTransport().execute(
      invocation, journal: journal, cancellation: .init(),
      progress: { box.append($0) })
    let updates = box.snapshot()
    try expect(result.state.outcome == .turnCompleted, "live-progress transport did not complete")
    try expect(updates.contains { $0.kind == .reasoning && $0.text == "checking evidence" },
      "reasoning summary was not surfaced")
    try expect(updates.contains { $0.kind == .response && $0.text == "draft" },
      "draft response was not surfaced")
    try expect(!updates.contains { $0.text.contains("must-not-surface") },
      "raw private reasoning delta surfaced")
    try expect(updates.allSatisfy { $0.text.count <= 4_000 }, "live text exceeded its bound")
  }

  private static func testProjection() throws {
    let lines = [
      #"{"type":"thread.started","thread_id":"T1"}"#,
      #"{"type":"item.started","item":{"id":"M1","type":"agent_message","text":""}}"#,
      #"{"type":"item.updated","item":{"id":"M1","type":"agent_message","text":"hel"}}"#,
      #"{"type":"item.updated","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"reasoning.delta","text":"private"}"#,
      #"{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"turn.completed"}"#,
    ]
    var projector = CodexEventProjector()
    for line in lines { try projector.project(CodexEvent(raw: Data(line.utf8))) }
    projector.reconcile(exitStatus: 0, cancellationRequested: false)
    try expect(projector.state.externalThreadID == "T1", "thread ID projection failed")
    try expect(
      projector.state.messages == [.init(itemID: "M1", draft: nil, committed: "hello")],
      "message projection/dedupe failed")
    try expect(projector.state.outcome == .turnCompleted, "completed+0 did not succeed")
    try expect(
      try outcome([#"{"type":"turn.failed"}"#], exit: 0) == .failed, "turn.failed did not fail")
    try expect(
      try outcome([#"{"type":"turn.completed"}"#], exit: 1) == .protocolFailure,
      "completed+nonzero did not fail protocol")
    try expect(
      try outcome([], exit: 0) == .protocolFailure, "missing terminal did not fail protocol")
    try expect(
      try outcome([#"{"type":"turn.completed"}"#, #"{"type":"turn.failed"}"#], exit: 0)
        == .protocolFailure,
      "conflicting terminals did not fail protocol")
    var wrongTurn = CodexEventProjector()
    try wrongTurn.project(
      CodexEvent(raw: Data(#"{"type":"turn.started","turn_id":"expected"}"#.utf8)))
    try expectError(CodexProjectionError.conflictingTurnIDs) {
      try wrongTurn.project(
        CodexEvent(raw: Data(#"{"type":"turn.completed","turn_id":"other"}"#.utf8)))
    }
    var interrupted = CodexEventProjector()
    interrupted.reconcile(
      exitStatus: 9, terminationReason: .uncaughtSignal, cancellationRequested: false)
    try expect(interrupted.state.outcome == .interrupted, "unrequested signal was not interrupted")
  }

  private static func outcome(_ lines: [String], exit: Int32) throws -> CodexOperationOutcome {
    var projector = CodexEventProjector()
    for line in lines { try projector.project(CodexEvent(raw: Data(line.utf8))) }
    projector.reconcile(exitStatus: exit, cancellationRequested: false)
    return projector.state.outcome
  }

  private static func testJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try OperationJournal(
      directoryURL: root.appendingPathComponent("operation"), recordLimit: 256, journalLimit: 1024)
    for record in [
      #"{"type":"thread.started","thread_id":"T1"}"#,
      #"{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"turn.completed"}"#,
    ] { try journal.append(Data(record.utf8)) }
    var before = try journal.replay()
    before.reconcile(exitStatus: 0, cancellationRequested: false)
    let beforeBytes = try before.state.stableBytes()
    let export = root.appendingPathComponent("export/stderr.log")
    try DiagnosticExporter().writeRedactedStderr(
      Data("Bearer secret-token /Users/test/private".utf8), to: export, homePath: "/Users/test")
    try FileManager.default.removeItem(at: export.deletingLastPathComponent())
    var after = try journal.replay()
    after.reconcile(exitStatus: 0, cancellationRequested: false)
    try expect(try after.state.stableBytes() == beforeBytes, "diagnostic export changed replay")
    let directoryMode =
      (try FileManager.default.attributesOfItem(atPath: journal.directoryURL.path)[
        .posixPermissions]
      as? NSNumber)?.intValue
    let fileMode =
      (try FileManager.default.attributesOfItem(atPath: journal.eventsURL.path)[.posixPermissions]
      as? NSNumber)?.intValue
    try expect(directoryMode == 0o700, "operation directory is not 0700")
    try expect(fileMode == 0o600, "journal is not 0600")
    try expectError(OperationJournalError.recordTooLarge) {
      try journal.append(Data(repeating: 0x61, count: 257))
    }
    try expect(
      FileManager.default.fileExists(atPath: journal.eventsURL.path), "journal was auto-deleted")

    let capped = try OperationJournal(
      directoryURL: root.appendingPathComponent("capped"), recordLimit: 16, journalLimit: 10)
    try capped.append(Data("1234".utf8))
    let acceptedPrefix = try Data(contentsOf: capped.eventsURL)
    try expectError(OperationJournalError.journalTooLarge) {
      try capped.append(Data("12345".utf8))
    }
    try expect(
      try Data(contentsOf: capped.eventsURL) == acceptedPrefix,
      "journal cap changed accepted prefix")
  }

  private static func testJournalTampering() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: outside)

    let symlinkDirectory = root.appendingPathComponent("symlink-operation")
    try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: symlinkDirectory.appendingPathComponent("events.jsonl"),
      withDestinationURL: outside)
    do {
      _ = try OperationJournal(directoryURL: symlinkDirectory)
      throw TestFailure(description: "journal accepted an initial symlink")
    } catch let error as TestFailure { throw error } catch {}
    try expect(try Data(contentsOf: outside) == Data("outside".utf8), "symlink init wrote outside")

    let swap = try OperationJournal(directoryURL: root.appendingPathComponent("swap-operation"))
    try swap.append(Data(#"{"type":"thread.started","thread_id":"T1"}"#.utf8))
    let accepted = try Data(contentsOf: swap.eventsURL)
    try FileManager.default.removeItem(at: swap.eventsURL)
    try FileManager.default.createSymbolicLink(at: swap.eventsURL, withDestinationURL: outside)
    try expectError(OperationJournalError.journalTampered) {
      try swap.append(Data(#"{"type":"turn.completed"}"#.utf8))
    }
    try expect(try Data(contentsOf: outside) == Data("outside".utf8), "symlink swap wrote outside")

    let truncate = try OperationJournal(
      directoryURL: root.appendingPathComponent("truncate-operation"))
    try truncate.append(Data(#"{"type":"thread.started","thread_id":"T2"}"#.utf8))
    try Data().write(to: truncate.eventsURL)
    try expectError(OperationJournalError.journalTampered) { _ = try truncate.replay() }

    let deleted = try OperationJournal(
      directoryURL: root.appendingPathComponent("delete-operation"))
    try deleted.append(Data(#"{"type":"thread.started","thread_id":"T3"}"#.utf8))
    try FileManager.default.removeItem(at: deleted.eventsURL)
    try expectError(OperationJournalError.journalTampered) {
      try deleted.append(Data(#"{"type":"turn.completed"}"#.utf8))
    }
    try expect(!accepted.isEmpty, "accepted replay prefix fixture was empty")
  }

  private static func testOperationResultRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let result = CodexOperationResultV1(
      operationID: operationID, journalByteCount: 73,
      state: CodexProjectedState(
        externalThreadID: "thread-1",
        messages: [.init(itemID: "message-1", draft: nil, committed: "answer")],
        terminalEvents: ["turn.completed:turn-1"], outcome: .turnCompleted),
      exitStatus: 0, terminationReason: .exit)
    let store = CodexOperationResultStore(directoryURL: root)

    try store.write(result)
    let recovered = try store.read(
      expectedOperationID: operationID, expectedJournalByteCount: 73)

    try expect(recovered == result, "operation result changed during sidecar round-trip")
    let sidecar = root.appendingPathComponent("operation-result.json")
    let mode =
      (try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions]
      as? NSNumber)?.intValue
    try expect(mode == 0o600, "operation result sidecar is not 0600")
  }

  private static func testOperationResultAtomicBound() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let accepted = CodexOperationResultV1(
      operationID: operationID, journalByteCount: 10,
      state: CodexProjectedState(outcome: .failed), exitStatus: 1,
      terminationReason: .exit)
    let store = CodexOperationResultStore(directoryURL: root, maximumBytes: 768)
    try store.write(accepted)

    let largeProjection = CodexOperationResultV1(
      operationID: operationID, journalByteCount: 10,
      state: CodexProjectedState(
        diagnostics: [String(repeating: "x", count: 2_048)], outcome: .protocolFailure),
      exitStatus: 1, terminationReason: .exit)
    try store.write(largeProjection)

    try expect(
      try store.read(expectedOperationID: operationID, expectedJournalByteCount: 10)
        == largeProjection,
      "large projected payload was copied into the bounded terminal sidecar")

    let rejectingStore = CodexOperationResultStore(directoryURL: root, maximumBytes: 1)
    do {
      try rejectingStore.write(accepted)
      throw TestFailure(description: "oversized operation result sidecar was accepted")
    } catch let error as TestFailure { throw error } catch {}
    try expect(
      try store.read(expectedOperationID: operationID, expectedJournalByteCount: 10)
        == largeProjection,
      "failed bounded replacement changed the prior atomic sidecar")
  }

  private static func testOperationResultOperationID() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let store = CodexOperationResultStore(directoryURL: root)
    try store.write(
      CodexOperationResultV1(
        operationID: operationID, journalByteCount: 41,
        state: CodexProjectedState(outcome: .interrupted), exitStatus: 9,
        terminationReason: .uncaughtSignal))

    do {
      _ = try store.read(expectedOperationID: UUID(), expectedJournalByteCount: 41)
      throw TestFailure(description: "sidecar with the wrong operation ID was accepted")
    } catch let error as TestFailure { throw error } catch {}
  }

  private static func testOperationResultJournalLength() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let store = CodexOperationResultStore(directoryURL: root)
    try store.write(
      CodexOperationResultV1(
        operationID: operationID, journalByteCount: 41,
        state: CodexProjectedState(outcome: .interrupted), exitStatus: 9,
        terminationReason: .uncaughtSignal))

    do {
      _ = try store.read(expectedOperationID: operationID, expectedJournalByteCount: 42)
      throw TestFailure(description: "sidecar with a mismatched journal byte count was accepted")
    } catch let error as TestFailure { throw error } catch {}
  }

  private static func testCapabilityStates() throws {
    let missing = CodexCapabilityChecker().check(
      executableURL: URL(fileURLWithPath: "/definitely/missing/codex"))
    try expect(missing.status == .missing, "missing executable was not classified")
    try expect(
      CodexCapabilityChecker.classifyOperationFailure(stderr: "Login required") == .loggedOut,
      "logged-out failure was not classified")
    try expect(
      CodexCapabilityChecker.classifyOperationFailure(stderr: "network failed")
        == .invocationFailed,
      "generic failure was misclassified")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let compatible = try makeExecutable(
      in: root, name: "compatible", contents: capabilityScript(version: "0.149.1"))
    let incompatible = try makeExecutable(
      in: root, name: "incompatible", contents: capabilityScript(version: "0.148.0"))
    let resumeSandbox = try makeExecutable(
      in: root, name: "resume-sandbox",
      contents: capabilityScript(version: "0.149.1", resumeExposesSandbox: true))
    let incompleteResumeHelp = try makeExecutable(
      in: root, name: "incomplete-resume-help",
      contents: incompleteResumeHelpScript())
    let completeButIncompatible = try makeExecutable(
      in: root, name: "complete-incompatible-help",
      contents: completeIncompatibleHelpScript())
    let transientResumeHelp = try makeExecutable(
      in: root, name: "transient-resume-help",
      contents: transientResumeHelpScript())
    let highVolumeHelp = try makeExecutable(
      in: root, name: "high-volume-help",
      contents: highVolumeHelpScript())
    try expect(
      CodexCapabilityChecker().check(executableURL: compatible).status == .usable,
      "compatible capability surface was rejected")
    try expect(
      CodexCapabilityChecker().check(executableURL: incompatible).status == .incompatible,
      "old capability surface was accepted")
    try expect(
      CodexCapabilityChecker().check(executableURL: resumeSandbox).status == .incompatible,
      "resume sandbox option drift was accepted")
    let incomplete = CodexCapabilityChecker().check(executableURL: incompleteResumeHelp)
    try expect(
      incomplete.status == .invocationFailed,
      "incomplete help output was falsely classified as an incompatible CLI")
    try expect(
      incomplete.detail.contains("exec resume --help")
        && incomplete.detail.contains("missing=--skip-git-repo-check"),
      "incomplete help failure discarded its missing capability evidence")
    try expect(
      CodexCapabilityChecker().check(executableURL: completeButIncompatible).status
        == .incompatible,
      "complete help with a missing required option was not classified as incompatible")
    try expect(
      CodexCapabilityChecker().check(executableURL: transientResumeHelp).status == .usable,
      "a complete retry did not recover a transient incomplete help response")
    let highVolumeStarted = Date()
    try expect(
      CodexCapabilityChecker().check(executableURL: highVolumeHelp).status == .usable,
      "high-volume help output was not drained safely")
    try expect(
      Date().timeIntervalSince(highVolumeStarted) < 5,
      "high-volume help output blocked on a full process pipe")
  }

  private static func testResolverSkipsIncompatibleCandidate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let incompatible = try makeExecutable(
      in: root, name: "incompatible-codex", contents: capabilityScript(version: "0.148.0"))
    let compatibleDirectory = root.appendingPathComponent("compatible-bin", isDirectory: true)
    let compatible = try makeExecutable(
      in: compatibleDirectory, name: "codex", contents: capabilityScript(version: "0.149.1"))

    let selected = try CodexExecutableResolver().resolve(
      preferredPath: incompatible.path, environment: ["PATH": compatibleDirectory.path])

    try expect(
      selected.standardizedFileURL != incompatible.standardizedFileURL,
      "resolver returned the first executable without proving CLI compatibility")
    try expect(
      CodexCapabilityChecker().check(executableURL: selected).status == .usable,
      "resolver did not select a capability-checked executable after rejecting the first candidate")
    if selected.path.hasPrefix(root.path) {
      try expect(
        selected.standardizedFileURL == compatible.standardizedFileURL,
        "resolver skipped the next usable PATH candidate")
    }
  }

  private static func testTransportAcceptedPrefix() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let malformed = try makeExecutable(
      in: root, name: "malformed",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}' '{\"type\":'\n"
    )
    let malformedJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("malformed-journal"))
    let malformedResult = try runFake(malformed, journal: malformedJournal)
    try expect(
      malformedResult.state.outcome == .protocolFailure, "malformed suffix did not fail protocol")
    try expect(
      try journalRecords(malformedJournal).count == 1,
      "malformed suffix lost or polluted accepted prefix")
    try expect(
      malformedResult.protocolDiagnostic?.kind == .malformedJSON,
      "empty-stderr malformed child did not expose JSON diagnostic")
    try expect(
      malformedResult.protocolDiagnostic?.summary.isEmpty == false,
      "malformed diagnostic summary was empty")
    try expect(
      (malformedResult.protocolDiagnostic?.summary.utf8.count ?? 513) <= 512,
      "protocol diagnostic exceeded its bound")
    try expect(
      malformedResult.diagnosticArtifactURL.map {
        FileManager.default.fileExists(atPath: $0.path)
      } == true,
      "malformed diagnostic artifact was not persisted")
    if let diagnosticURL = malformedResult.diagnosticArtifactURL {
      let mode =
        (try FileManager.default.attributesOfItem(atPath: diagnosticURL.path)[.posixPermissions]
        as? NSNumber)?.intValue
      try expect(mode == 0o600, "protocol diagnostic artifact is not 0600")
      let persisted = try JSONDecoder().decode(
        CodexProtocolDiagnostic.self, from: Data(contentsOf: diagnosticURL))
      try expect(
        persisted == malformedResult.protocolDiagnostic,
        "persisted protocol diagnostic differs from transport result")
    }

    let invalidUTF8 = try makeExecutable(
      in: root, name: "invalid-utf8",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}'\nprintf '\\377\\n'\n"
    )
    let invalidJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("invalid-journal"))
    let invalidResult = try runFake(invalidUTF8, journal: invalidJournal)
    try expect(
      invalidResult.state.outcome == .protocolFailure, "invalid UTF-8 did not fail protocol")
    try expect(try journalRecords(invalidJournal).count == 1, "invalid UTF-8 lost accepted prefix")
    try expect(
      invalidResult.protocolDiagnostic?.kind == .invalidUTF8, "invalid UTF-8 reason missing")

    let oversized = try makeExecutable(
      in: root, name: "oversized",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}'\n/usr/bin/head -c 1048577 /dev/zero | /usr/bin/tr '\\000' a\nprintf '\\n'\n"
    )
    let oversizedJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("oversized-journal"))
    let oversizedResult = try runFake(oversized, journal: oversizedJournal)
    try expect(
      oversizedResult.state.outcome == .protocolFailure, "oversized suffix did not fail protocol")
    try expect(
      try journalRecords(oversizedJournal).count == 1, "oversized suffix lost accepted prefix")
    try expect(
      oversizedResult.protocolDiagnostic?.kind == .recordTooLarge, "oversize reason missing")

    let missingField = try makeExecutable(
      in: root, name: "missing-field",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}' '{\"type\":\"item.completed\",\"item\":{\"id\":\"M1\",\"type\":\"agent_message\"}}'\n"
    )
    let missingJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("missing-journal"))
    let missingResult = try runFake(missingField, journal: missingJournal)
    try expect(
      missingResult.state.outcome == .protocolFailure, "missing field did not fail protocol")
    try expect(
      try journalRecords(missingJournal).count == 2,
      "syntactically accepted event was not journaled before projection rejection")
    try expect(
      missingResult.protocolDiagnostic?.kind == .projectionFailure,
      "projection failure reason missing")

    let partial = try makeExecutable(
      in: root, name: "partial",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}'\nprintf '%s' '{\"type\":\"turn.completed\"}'\n"
    )
    let partialJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("partial-journal"))
    let partialResult = try runFake(partial, journal: partialJournal)
    try expect(
      partialResult.protocolDiagnostic?.kind == .partialRecordAtEOF,
      "partial EOF reason missing")
    try expect(try journalRecords(partialJournal).count == 1, "partial EOF lost accepted prefix")

    let wrongTurn = try makeExecutable(
      in: root, name: "wrong-turn",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"turn.started\",\"turn_id\":\"expected\"}' '{\"type\":\"turn.completed\",\"turn_id\":\"other\"}'\n"
    )
    let wrongTurnJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("wrong-turn-journal"))
    let wrongTurnResult = try runFake(wrongTurn, journal: wrongTurnJournal)
    try expect(wrongTurnResult.state.outcome == .protocolFailure, "wrong turn passed transport")
    try expect(
      wrongTurnResult.protocolDiagnostic?.kind == .projectionFailure,
      "wrong-turn transport diagnostic missing")
    try expect(
      try journalRecords(wrongTurnJournal).count == 2,
      "wrong-turn event was not journaled before projection rejection")

    let conflictingTerminals = try makeExecutable(
      in: root, name: "conflicting-terminals",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"turn.completed\"}' '{\"type\":\"turn.failed\"}'\n"
    )
    let conflictingResult = try runFake(
      conflictingTerminals,
      journal: OperationJournal(directoryURL: root.appendingPathComponent("terminal-journal")))
    try expect(
      conflictingResult.state.outcome == .protocolFailure,
      "conflicting terminals passed transport reconciliation")
    try expect(
      conflictingResult.protocolDiagnostic?.kind == .pipelineFailure,
      "terminal reconciliation failure did not expose a diagnostic")
  }

  private static func testTransportBoundsAndCancellation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let noisy = try makeExecutable(
      in: root, name: "noisy",
      contents:
        "#!/bin/sh\n/usr/bin/head -c 1200000 /dev/zero >&2\nprintf '%s\\n' '{\"type\":\"turn.completed\"}'\n"
    )
    let noisyResult = try runFake(
      noisy, journal: OperationJournal(directoryURL: root.appendingPathComponent("noisy-journal")))
    try expect(noisyResult.stderr.count == 1_048_576, "stderr cap was not exact")
    try expect(noisyResult.state.outcome == .turnCompleted, "stderr cap changed successful outcome")
    try expect(noisyResult.retryDisposition == .none, "successful operation offered retry")

    let waits = try makeExecutable(
      in: root, name: "waits",
      contents:
        "#!/bin/sh\ntrap 'exit 143' TERM\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"T1\"}'\nwhile :; do :; done\n"
    )
    let immediate = CodexCancellationToken()
    immediate.cancel()
    let immediateResult = try runFake(
      waits, journal: OperationJournal(directoryURL: root.appendingPathComponent("immediate")),
      cancellation: immediate)
    try expect(immediateResult.state.outcome == .cancelled, "immediate cancel was not cancelled")
    try expect(
      immediateResult.retryDisposition == .explicitUserDecisionRequired,
      "cancel retry policy was not explicit")

    let late = CodexCancellationToken()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { late.cancel() }
    let lateResult = try runFake(
      waits, journal: OperationJournal(directoryURL: root.appendingPathComponent("late")),
      cancellation: late)
    try expect(lateResult.state.outcome == .cancelled, "late cancel was not cancelled")

    let timeoutResult = try runFake(
      waits, journal: OperationJournal(directoryURL: root.appendingPathComponent("timeout")),
      policy: .init(timeout: 0.1, terminationGrace: 0.1))
    try expect(timeoutResult.state.outcome == .timedOut, "bounded timeout did not fire")
    try expect(
      timeoutResult.retryDisposition == .explicitNewOperationRequired,
      "timeout did not require a new operation")

    let timeoutPIDFile = root.appendingPathComponent("forced-timeout.pid")
    let ignoresTermination = try makeExecutable(
      in: root, name: "ignores-termination",
      contents:
        "#!/bin/sh\nprintf '%s' \"$$\" > '\(timeoutPIDFile.path)'\ntrap '' TERM\nwhile :; do :; done\n"
    )
    let forceStart = Date()
    let forcedResult = try runFake(
      ignoresTermination,
      journal: OperationJournal(directoryURL: root.appendingPathComponent("forced-timeout")),
      policy: .init(timeout: 3, terminationGrace: 0.1))
    try expect(forcedResult.state.outcome == .timedOut, "forced timeout was not timedOut")
    try expect(
      Date().timeIntervalSince(forceStart) < 8, "TERM-ignoring child was not force-bounded")
    let timeoutPID = Int32(try String(contentsOf: timeoutPIDFile, encoding: .utf8))!
    errno = 0
    try expect(
      Darwin.kill(timeoutPID, 0) == -1 && errno == ESRCH,
      "forced-timeout child was not reaped")

    let descendantPIDFile = root.appendingPathComponent("descendant.pid")
    let inheritedPipes = try makeExecutable(
      in: root, name: "inherited-pipes",
      contents: """
        #!/bin/sh
        printf '%s\\n' '{"type":"thread.started","thread_id":"TREE"}'
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        printf "%s" "$!" > "\(descendantPIDFile.path)"
        trap 'exit 143' TERM
        wait
        """
    )
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["5"]
    try unrelated.run()
    defer {
      if unrelated.isRunning { unrelated.terminate() }
      unrelated.waitUntilExit()
    }
    let inheritedJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("inherited-pipes-journal"))
    let inheritedStart = Date()
    let inheritedResult = try runFake(
      inheritedPipes, journal: inheritedJournal,
      policy: .init(timeout: 2, terminationGrace: 0.1))
    try expect(
      Date().timeIntervalSince(inheritedStart) < 5,
      "FD-inheriting TERM-ignoring descendant kept transport drain alive")
    try expect(
      inheritedResult.state.outcome == .timedOut,
      "process-tree timeout was not reconciled")
    try expect(unrelated.isRunning, "cleanup signaled an unrelated process group")
    try expect(
      FileManager.default.fileExists(atPath: descendantPIDFile.path),
      """
      descendant marker missing; exit=\(inheritedResult.exitStatus) \
      stderr=\(String(decoding: inheritedResult.stderr, as: UTF8.self))
      """)
    let descendantPID = Int32(
      try String(contentsOf: descendantPIDFile, encoding: .utf8))!
    try expectProcessGone(descendantPID, message: "owned descendant survived process-tree cleanup")
    var replayed = try inheritedJournal.replay()
    replayed.reconcile(
      exitStatus: inheritedResult.exitStatus,
      terminationReason: inheritedResult.terminationReason,
      cancellationRequested: false,
      timedOut: true,
      framingCompleted: true)
    try expect(
      replayed.state.externalThreadID == "TREE" && replayed.state.outcome == .timedOut,
      "process-tree cleanup lost durable journal reconciliation")

    let pidFile = root.appendingPathComponent("stdin-failure.pid")
    let closesInput = try makeExecutable(
      in: root, name: "closes-input",
      contents:
        "#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nexec 0<&-\ntrap '' TERM\nwhile :; do :; done\n"
    )
    do {
      _ = try runFake(
        closesInput,
        journal: OperationJournal(directoryURL: root.appendingPathComponent("stdin-failure")),
        policy: .init(timeout: 10, terminationGrace: 0.1),
        prompt: String(repeating: "x", count: 8 * 1_024 * 1_024))
      throw TestFailure(description: "closed child stdin did not fail")
    } catch let error as TestFailure { throw error } catch {}
    let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    errno = 0
    try expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "stdin failure left child unreaped")
  }

  private static func capabilityScript(
    version: String, resumeExposesSandbox: Bool = false
  ) -> String {
    let resumeSandbox = resumeExposesSandbox ? "--sandbox workspace-write" : ""
    return """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf '%s\n' 'codex-cli \(version)'
      elif [ "$1" = "exec" ] && [ "$2" = "resume" ]; then
        printf '%s\n' '--json --skip-git-repo-check \(resumeSandbox) If `-` is used, read from stdin'
        printf '%s\n' '--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust'
        printf '%s\n' 'Examples: sandbox_permissions=["disk-full-read-access"]'
      else
        printf '%s\n' '--json --sandbox workspace-write --skip-git-repo-check resume instructions are read from stdin'
      fi
      """
  }

  private static func incompleteResumeHelpScript() -> String {
    """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      printf '%s\n' 'codex-cli 0.149.1'
    elif [ "$1" = "exec" ] && [ "$2" = "resume" ]; then
      printf '%s\n' '--json'
    else
      printf '%s\n' '--json --sandbox workspace-write --skip-git-repo-check resume instructions are read from stdin'
    fi
    """
  }

  private static func completeIncompatibleHelpScript() -> String {
    """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      printf '%s\n' 'codex-cli 0.149.1'
    elif [ "$1" = "exec" ] && [ "$2" = "resume" ]; then
      printf '%s\n' 'Usage: codex exec resume [OPTIONS]'
      printf '%s\n' 'Options:'
      printf '%s\n' '  --json'
      printf '%s\n' '  -h, --help'
      printf '%s\n' 'If `-` is used, read from stdin'
    else
      printf '%s\n' '--json --sandbox workspace-write --skip-git-repo-check resume instructions are read from stdin'
    fi
    """
  }

  private static func transientResumeHelpScript() -> String {
    """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      printf '%s\n' 'codex-cli 0.149.1'
    elif [ "$1" = "exec" ] && [ "$2" = "resume" ]; then
      state="$0.resume-attempt"
      count=0
      test ! -f "$state" || count=$(cat "$state")
      count=$((count + 1))
      printf '%s\n' "$count" > "$state"
      if [ "$count" -eq 1 ]; then
        printf '%s\n' '--json'
      else
        printf '%s\n' '--json --skip-git-repo-check If `-` is used, read from stdin'
      fi
    else
      printf '%s\n' '--json --sandbox workspace-write --skip-git-repo-check resume instructions are read from stdin'
    fi
    """
  }

  private static func highVolumeHelpScript() -> String {
    """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      printf '%s\n' 'codex-cli 0.149.1'
    elif [ "$1" = "exec" ] && [ "$2" = "resume" ]; then
      printf '%s\n' '--json --skip-git-repo-check If `-` is used, read from stdin'
      yes 'bounded capability padding 012345678901234567890123456789' | head -n 24000
    else
      printf '%s\n' '--json --sandbox workspace-write --skip-git-repo-check resume instructions are read from stdin'
      yes 'bounded capability padding 012345678901234567890123456789' | head -n 24000
    fi
    """
  }

  private static func makeExecutable(in directory: URL, name: String, contents: String) throws
    -> URL
  {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private static func runFake(
    _ executable: URL, journal: OperationJournal,
    cancellation: CodexCancellationToken = CodexCancellationToken(),
    policy: CodexTransportPolicy = CodexTransportPolicy(), prompt: String = "test"
  ) throws -> CodexTransportResult {
    let invocation = try CodexInvocation(
      executableURL: executable, kind: .new, prompt: prompt,
      workingDirectory: executable.deletingLastPathComponent())
    return try DirectProcessCodexTransport().execute(
      invocation, journal: journal, cancellation: cancellation, policy: policy)
  }

  private static func journalRecords(_ journal: OperationJournal) throws -> [Data] {
    let bytes = [UInt8](try Data(contentsOf: journal.eventsURL))
    return bytes.split(separator: 0x0A).map { Data($0) }
  }

  private static func expectProcessGone(_ pid: Int32, message: String) throws {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      errno = 0
      if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.pbi_status == 5
      {
        return
      }
      usleep(10_000)
    } while Date() < deadline
    let group = Darwin.getpgid(pid)
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let infoBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    throw TestFailure(
      description:
        """
        \(message); pid=\(pid) pgid=\(group) errno=\(errno) \
        infoBytes=\(infoBytes) status=\(info.pbi_status)
        """)
  }

  private static func testTranscript() throws {
    let date = Date(timeIntervalSince1970: 1)
    let messages = [
      TranscriptMessage(id: "M1", role: .user, content: "old\r\nquestion", createdAt: date),
      TranscriptMessage(
        id: "M2", role: .assistant, content: "답변", createdAt: date.addingTimeInterval(1)),
      TranscriptMessage(
        id: "M3", role: .user, content: "new\task", createdAt: date.addingTimeInterval(2)),
      TranscriptMessage(
        id: "D1", role: .assistant, content: "draft", createdAt: date, committed: false),
      TranscriptMessage(id: "S1", role: .system, content: "system", createdAt: date),
    ]
    let output = String(
      decoding: TranscriptContextProjector().project(
        predecessorSessionID: "S1", messages: messages),
      as: UTF8.self)
    let expected = """
      TRANSCRIPT_CONTEXT_V1
      {"predecessor_session_id":"S1","budget_bytes":32768,"normalization":"NFC_LF","selection":"newest_whole_message_suffix"}
      {"type":"omission","count":0,"newest_omitted":false}
      {"id":"M1","role":"user","content":"old\\nquestion"}
      {"id":"M2","role":"assistant","content":"답변"}
      {"id":"M3","role":"user","content":"new\\task"}

      """
    try expect(output == expected, "production transcript golden changed")
    try expect(
      TranscriptContextProjector().project(predecessorSessionID: "S1", messages: messages)
        == Data(output.utf8),
      "repeated transcript projection was not byte-identical")

    let tieDate = Date(timeIntervalSince1970: 10)
    let normalizedMessages = [
      TranscriptMessage(id: "B", role: .user, content: "later", createdAt: tieDate),
      TranscriptMessage(
        id: "A", role: .assistant, content: "e\u{301}\u{0}\u{1F}x", createdAt: tieDate),
      TranscriptMessage(
        id: "C", role: .user, content: "\u{0}A\u{1F}\tB\r\nC",
        createdAt: tieDate.addingTimeInterval(1)),
    ]
    let normalized = String(
      decoding: TranscriptContextProjector().project(
        predecessorSessionID: "NFC", messages: normalizedMessages),
      as: UTF8.self)
    try expect(
      normalized.contains("{\"id\":\"A\",\"role\":\"assistant\",\"content\":\"éx\"}"),
      "NFC or C0 removal failed")
    try expect(
      normalized.contains("{\"id\":\"C\",\"role\":\"user\",\"content\":\"A\\tB\\nC\"}"),
      "tab/LF preservation or C0 removal failed")
    try expect(
      normalized.range(of: "\"id\":\"A\"")!.lowerBound
        < normalized.range(of: "\"id\":\"B\"")!.lowerBound,
      "timestamp tie was not resolved by ID")

    let suffixMessages = [
      TranscriptMessage(id: "M1", role: .user, content: "old", createdAt: date),
      TranscriptMessage(
        id: "M2", role: .assistant, content: "middle", createdAt: date.addingTimeInterval(1)),
      TranscriptMessage(
        id: "M3", role: .user, content: "new", createdAt: date.addingTimeInterval(2)),
    ]
    let suffix = String(
      decoding: TranscriptContextProjector().project(
        predecessorSessionID: "S1", messages: suffixMessages, budgetBytes: 285),
      as: UTF8.self)
    let expectedSuffix = """
      TRANSCRIPT_CONTEXT_V1
      {"predecessor_session_id":"S1","budget_bytes":285,"normalization":"NFC_LF","selection":"newest_whole_message_suffix"}
      {"type":"omission","count":1,"newest_omitted":false}
      {"id":"M2","role":"assistant","content":"middle"}
      {"id":"M3","role":"user","content":"new"}

      """
    try expect(suffix == expectedSuffix, "reduced-budget suffix or omission count changed")
    try expect(Data(suffix.utf8).count == 285, "reduced-budget fixture byte count changed")

    let oversized = [
      TranscriptMessage(id: "old", role: .assistant, content: "keep out", createdAt: date),
      TranscriptMessage(
        id: "huge", role: .user, content: String(repeating: "가", count: 100),
        createdAt: date.addingTimeInterval(1)),
    ]
    let omission = String(
      decoding: TranscriptContextProjector().project(
        predecessorSessionID: "P", messages: oversized, budgetBytes: 512),
      as: UTF8.self)
    let expectedOmission = """
      TRANSCRIPT_CONTEXT_V1
      {"predecessor_session_id":"P","budget_bytes":512,"normalization":"NFC_LF","selection":"newest_whole_message_suffix"}
      {"type":"omission","count":2,"newest_omitted":true,"newest_id":"huge","newest_utf8_bytes":300,"newest_sha256":"699eb89f6a4cefe24fdd5bddd05a65ead217e2368a28850d5283ec27c7a97164"}

      """
    try expect(omission == expectedOmission, "oversized-newest omission object/hash changed")
    try expect(!omission.contains("\"id\":\"old\""), "older content leaked after newest omission")
  }
}
