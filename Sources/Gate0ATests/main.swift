import Darwin
import Foundation
import PapertrailCore

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

private final class LiveProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var updates: [AgentLiveProgress] = []
  func append(_ update: AgentLiveProgress) { lock.withLock { updates.append(update) } }
  func snapshot() -> [AgentLiveProgress] { lock.withLock { updates } }
}

@main
enum Gate0ATests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("invocation boundary", testInvocationBoundary),
      ("minimal environment", testMinimalEnvironment),
      ("fixed Claude model catalog", testModelCatalog),
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

  private static func testModelCatalog() throws {
    let models = AgentModelCatalog.models
    try expect(models.map(\.model) == ["opus", "sonnet", "haiku"], "model family aliases changed")
    try expect(
      models.allSatisfy { AgentInvocation.isValidModelIdentifier($0.model) },
      "catalog contains an identifier the invocation boundary rejects")
    try expect(
      models.allSatisfy { $0.supportedReasoningEfforts == [.low, .medium, .high, .xhigh, .max] },
      "catalog effort levels drifted from the Claude Code --effort choices")
    try expect(
      AgentModelCatalog.descriptor(for: "sonnet")?.displayName == "Claude Sonnet"
        && AgentModelCatalog.descriptor(for: "gpt-5.5") == nil,
      "catalog lookup accepted a non-Claude model")
    for model in models {
      try expect(
        JSONDecoder().decode(AgentModelDescriptor.self, from: JSONEncoder().encode(model))
          == model, "model descriptor did not round-trip")
      for effort in model.supportedReasoningEfforts {
        let invocation = try AgentInvocation(
          executableURL: URL(fileURLWithPath: "/usr/bin/true"), kind: .new,
          systemPrompt: testSystemPrompt, prompt: "x",
          workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), model: model.model,
          reasoningEffort: effort)
        try expect(
          invocation.arguments.suffix(4) == ["--model", model.model, "--effort", effort.rawValue],
          "catalog choice did not reach its approved argument slots")
      }
    }
  }

  private static func testInvocationBoundary() throws {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    let prompt = #"paper'; $(touch /tmp/pwned); --dangerously-skip-permissions"#
    let isolation = [
      "-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--strict-mcp-config",
      "--setting-sources", "", "--permission-mode", "dontAsk", "--system-prompt", testSystemPrompt,
    ]
    let new = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
      workingDirectory: workspace)
    try expect(new.arguments == isolation, "new argument shape changed")
    try expect(new.standardInput == Data(prompt.utf8), "prompt was not preserved on stdin")
    try expect(!new.arguments.joined().contains("touch"), "untrusted prompt reached arguments")
    let ephemeral = try AgentInvocation(
      executableURL: executable, kind: .ephemeral, systemPrompt: testSystemPrompt,
      prompt: prompt, workingDirectory: workspace)
    try expect(
      ephemeral.arguments == isolation + ["--no-session-persistence"],
      "ephemeral turn did not disable session persistence")
    let resume = try AgentInvocation(
      executableURL: executable, kind: .resume(sessionID: "session-123"),
      systemPrompt: testSystemPrompt, prompt: prompt, workingDirectory: workspace,
      reasoningEffort: .xhigh, streamPartialMessages: true)
    try expect(
      resume.arguments
        == isolation + ["--effort", "xhigh", "--include-partial-messages", "--resume", "session-123"],
      "resume argument shape changed")
    let selected = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
      workingDirectory: workspace, model: "opus", reasoningEffort: .medium)
    try expect(
      selected.arguments == isolation + ["--model", "opus", "--effort", "medium"],
      "selected model and effort were not isolated to approved argument slots")
    let automatic = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
      workingDirectory: workspace, reasoningEffort: .automatic)
    try expect(!automatic.arguments.contains("--effort"), "automatic effort overrode the CLI default")
    let future = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
      workingDirectory: workspace, reasoningEffort: AgentReasoningEffort(rawValue: "ultra")!)
    try expect(future.arguments.suffix(2) == ["--effort", "ultra"], "future effort token was lost")
    for effort in [
      "", "high\"", "high\n", "$(touch /tmp/pwned)", "high;touch",
      String(repeating: "a", count: 33),
    ] {
      try expect(AgentReasoningEffort(rawValue: effort) == nil, "unsafe reasoning token accepted")
      do {
        _ = try JSONDecoder().decode(
          AgentReasoningEffort.self, from: JSONEncoder().encode(effort))
        throw TestFailure(description: "unsafe cached reasoning token accepted")
      } catch is DecodingError {}
    }
    for model in ["opus;rm", "-p", "", String(repeating: "a", count: 129)] {
      try expectError(AgentInvocationError.invalidModelIdentifier) {
        _ = try AgentInvocation(
          executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
          workingDirectory: workspace, model: model)
      }
    }
    for session in ["--dangerously-skip-permissions", "a b", "", "x;rm"] {
      try expectError(AgentInvocationError.invalidSessionID) {
        _ = try AgentInvocation(
          executableURL: executable, kind: .resume(sessionID: session),
          systemPrompt: testSystemPrompt, prompt: prompt, workingDirectory: workspace)
      }
    }
    for systemPrompt in [
      "", "--dangerously-skip-permissions", " leading space", "nul\u{0}byte",
      String(repeating: "a", count: AgentInvocation.maximumSystemPromptBytes + 1),
    ] {
      try expectError(AgentInvocationError.invalidSystemPrompt) {
        _ = try AgentInvocation(
          executableURL: executable, kind: .new, systemPrompt: systemPrompt, prompt: prompt,
          workingDirectory: workspace)
      }
    }
    for arguments in [
      isolation + ["--dangerously-skip-permissions"],
      isolation + ["--add-dir", "/"],
      isolation + ["--resume", "s", "--fork-session"],
      isolation + ["--no-session-persistence", "--resume", "s"],
      isolation + ["--include-partial-messages", "--effort", "high"],
      isolation + ["--include-partial-messages", "--include-partial-messages"],
      isolation + ["extra prompt argument"],
      Array(isolation.dropFirst(2)),
      isolation.map { $0 == "dontAsk" ? "bypassPermissions" : $0 },
      isolation.map { $0 == "--strict-mcp-config" ? "--mcp-config" : $0 },
    ] {
      do {
        try AgentInvocation.validate(arguments: arguments)
        throw TestFailure(description: "unapproved argument vector was accepted: \(arguments)")
      } catch is AgentInvocationError {}
    }
    try expect(
      AgentInvocationError.executableNotRunnable.localizedDescription
        == "The Claude Code executable is not runnable.",
      "resolver failure lost its actionable description")
  }

  private static func testMinimalEnvironment() throws {
    let environment = AgentCapabilityChecker.minimalEnvironment(source: [
      "HOME": "/Users/test", "SECRET": "leak", "PATH": "/evil", "ANTHROPIC_API_KEY": "sk-leak",
      "ANTHROPIC_BASE_URL": "http://proxy.invalid", "CLAUDE_CODE_OAUTH_TOKEN": "token",
      "CLAUDE_CONFIG_DIR": "/tmp/other",
    ])
    try expect(environment["HOME"] == "/Users/test", "HOME was not preserved for CLI-owned auth")
    for key in [
      "SECRET", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
      "CLAUDE_CONFIG_DIR",
    ] {
      try expect(environment[key] == nil, "\(key) leaked into the Claude Code child")
    }
    try expect(!environment["PATH", default: ""].contains("/evil"), "untrusted PATH leaked")
    try expect(
      environment["DISABLE_AUTOUPDATER"] == "1"
        && environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1",
      "child could update itself or send nonessential traffic")
    try expect(
      environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "128000",
      "a full presentation could be cut off at the default output cap")
  }

  private static func testFraming() throws {
    let line = Data(
      #"{"type":"assistant","message":{"id":"M1","content":[{"type":"text","text":"한글"}]}}"#.utf8)
    let stream = line + Data([0x0A])
    for split in 0...stream.count {
      var framer = AgentJSONLFramer()
      var records = try framer.append(stream.prefix(split))
      records += try framer.append(stream.suffix(stream.count - split))
      try framer.finish()
      try expect(records == [line], "UTF-8 split failed at byte \(split)")
    }
    var partial = AgentJSONLFramer()
    _ = try partial.append(Data("{}".utf8))
    try expectError(AgentFramingError.partialRecordAtEOF) { try partial.finish() }
    var bounded = AgentJSONLFramer(maximumRecordBytes: 4)
    try expectError(AgentFramingError.recordTooLarge) {
      _ = try bounded.append(Data("12345".utf8))
    }

    let valid = Data("ok\n".utf8)
    var oversizedAfterPrefix = AgentJSONLFramer(maximumRecordBytes: 4)
    let oversizedBatch = oversizedAfterPrefix.consume(valid + Data("12345\n".utf8))
    try expect(
      oversizedBatch.records == [Data("ok".utf8)], "valid prefix was lost before oversized record")
    try expect(oversizedBatch.error == .recordTooLarge, "oversized suffix was not reported")

    var invalidAfterPrefix = AgentJSONLFramer(maximumRecordBytes: 16)
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
      printf '%s\n' '\(initEvent)'
      printf '%s\n' '{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"thinking","thinking":"checking evidence"}]},"session_id":"S1"}'
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":"must-not-surface"}}}'
      printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"partial-draft"}},"session_id":"S1"}'
      for tokens in 1 6 600 700 1200; do printf '{"type":"system","subtype":"thinking_tokens","estimated_tokens":%s,"session_id":"S1"}\n' "$tokens"; done
      printf '%s\n' '{"type":"assistant","message":{"id":"E1","model":"<synthetic>","content":[{"type":"text","text":"synthetic-must-not-surface"}]},"session_id":"S1"}'
      printf '%s\n' '{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"text","text":"\(longText)"}]},"session_id":"S1"}'
      printf '%s\n' '\(successEvent)'
      """)
    let journal = try OperationJournal(directoryURL: root.appendingPathComponent("journal"))
    let invocation = try AgentInvocation(
      executableURL: script, kind: .new, systemPrompt: testSystemPrompt, prompt: "test",
      workingDirectory: root)
    let box = LiveProgressBox()
    let result = try DirectProcessAgentTransport().execute(
      invocation, journal: journal, cancellation: .init(),
      progress: { box.append($0) })
    let updates = box.snapshot()
    try expect(result.state.outcome == .turnCompleted, "live-progress transport did not complete")
    try expect(updates.contains { $0.kind == .reasoning && $0.text == "checking evidence" },
      "reasoning summary was not surfaced")
    try expect(updates.contains { $0.kind == .response && $0.text.count == 4_000 },
      "response was not surfaced at its bound")
    try expect(!updates.contains { $0.text.contains("must-not-surface") },
      "raw delta or synthetic error surfaced as Claude output")
    try expect(updates.allSatisfy { $0.text.count <= 4_000 }, "live text exceeded its bound")
    try expect(
      updates.first?.kind == .status && updates.last?.text == "Claude finished the response",
      "session lifecycle status was not surfaced")
    let thinking = updates.filter { $0.itemID == "thinking-tokens" }.map(\.text)
    try expect(
      thinking == [
        "Thinking… (about 1 tokens)", "Thinking… (about 600 tokens)",
        "Thinking… (about 1,200 tokens)",
      ], "thinking-token progress was not throttled to 500-token steps: \(thinking)")
    try expect(
      try !String(contentsOf: journal.eventsURL, encoding: .utf8).contains("thinking_tokens")
        && !String(contentsOf: journal.eventsURL, encoding: .utf8).contains("stream_event"),
      "per-chunk thinking counters or text deltas were fsync'd into the journal")
    try expect(
      updates.contains { $0.kind == .draft && $0.text == "partial-draft" },
      "streamed text delta was not surfaced as draft progress")
    try expect(
      result.state.model == "claude-test", "init model was not recorded for the run summary")
  }

  private static func testProjection() throws {
    let lines = [
      initEvent,
      #"{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"thinking","thinking":""}]},"session_id":"S1"}"#,
      #"{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"text","text":"hello"}]},"session_id":"S1"}"#,
      #"{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"text","text":"hello"}]},"session_id":"S1"}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta"}}"#,
      #"{"type":"assistant","message":{"id":"M1","model":"claude-test","content":[{"type":"text","text":"world"}]},"session_id":"S1"}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"hello\n\nworld","session_id":"S1"}"#,
    ]
    var projector = AgentEventProjector()
    for line in lines { try projector.project(AgentEvent(raw: Data(line.utf8))) }
    projector.reconcile(exitStatus: 0, cancellationRequested: false)
    try expect(projector.state.externalThreadID == "S1", "session ID projection failed")
    try expect(
      projector.state.messages == [.init(itemID: "M1", draft: nil, committed: "hello\n\nworld")],
      "message projection, block joining, or dedupe failed")
    try expect(projector.state.resultText == "hello\n\nworld", "final result text was lost")
    try expect(projector.state.outcome == .turnCompleted, "success+0 did not succeed")

    let authFailure = [
      initEvent,
      #"{"type":"assistant","message":{"id":"E1","model":"<synthetic>","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired"}]},"session_id":"S1"}"#,
      #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired","terminal_reason":"api_error","session_id":"S1"}"#,
    ]
    var failed = AgentEventProjector()
    for line in authFailure { try failed.project(AgentEvent(raw: Data(line.utf8))) }
    failed.reconcile(exitStatus: 1, cancellationRequested: false)
    try expect(failed.state.outcome == .failed, "is_error result did not fail the turn")
    try expect(failed.state.messages.isEmpty, "synthetic error became an assistant message")
    try expect(failed.state.resultText == nil, "failed result text was treated as an answer")
    try expect(
      AgentCapabilityChecker.classifyOperationFailure(
        diagnostics: failed.state.diagnostics, stderr: "") == .loggedOut,
      "authentication failure was not classified as logged out")
    try expect(
      failed.state.failureDetail == "Failed to authenticate: OAuth session expired",
      "authentication failure detail was not surfaced")
    // Recorded from a live Claude Code 2.1.231 safeguard refusal.
    let refusal = [
      initEvent,
      #"{"type":"system","subtype":"model_refusal_no_fallback","original_model":"claude-opus-5","api_refusal_category":"reasoning_extraction","session_id":"S1"}"#,
      #"{"type":"assistant","message":{"id":"E2","model":"<synthetic>","content":[{"type":"text","text":"API Error: Opus 5's safeguards flagged this message."}]},"session_id":"S1"}"#,
      #"{"type":"result","subtype":"success","is_error":true,"stop_reason":"refusal","terminal_reason":"api_error","result":"API Error: Opus 5's safeguards flagged this message. This sometimes happens with safe, normal conversations.\n\nTry rephrasing the request in a new session or change your model.\n\nLearn more: https://support.claude.com/","session_id":"S1"}"#,
    ]
    var refused = AgentEventProjector()
    for line in refusal { try refused.project(AgentEvent(raw: Data(line.utf8))) }
    refused.reconcile(exitStatus: 1, cancellationRequested: false)
    try expect(
      refused.state.outcome == .failed && refused.state.messages.isEmpty,
      "safeguard refusal was not a failed turn without an assistant answer")
    try expect(
      refused.state.failureDetail
        == "API Error: Opus 5's safeguards flagged this message. This sometimes happens with safe, normal conversations. Try rephrasing the request in a new session or change your model.",
      "refusal detail lost its remedy: \(String(describing: refused.state.failureDetail))")
    try expect(projector.state.failureDetail == nil, "completed turn reported a failure detail")

    try expect(
      try outcome([successEvent], exit: 1) == .protocolFailure,
      "success+nonzero did not fail protocol")
    try expect(try outcome([], exit: 0) == .protocolFailure, "missing result did not fail protocol")
    try expect(try outcome([], exit: 1) == .failed, "CLI rejection before streaming did not fail")
    try expect(
      try outcome([successEvent, successEvent.replacingOccurrences(of: "done", with: "again")], exit: 0)
        == .protocolFailure,
      "two terminal results did not fail protocol")
    try expectError(AgentProjectionError.toolsEnabled(["Bash"])) {
      var projector = AgentEventProjector()
      try projector.project(
        AgentEvent(raw: Data(initEvent.replacingOccurrences(of: #""tools":[]"#, with: #""tools":["Bash"]"#).utf8)))
    }
    try expectError(AgentProjectionError.unexpectedToolUse) {
      var projector = AgentEventProjector()
      try projector.project(
        AgentEvent(raw: Data(#"{"type":"assistant","message":{"id":"M1","content":[{"type":"tool_use","name":"Read"}]}}"#.utf8)))
    }
    try expectError(AgentProjectionError.conflictingSessionIDs) {
      var projector = AgentEventProjector()
      try projector.project(AgentEvent(raw: Data(initEvent.utf8)))
      try projector.project(
        AgentEvent(raw: Data(successEvent.replacingOccurrences(of: "S1", with: "S2").utf8)))
    }
    var interrupted = AgentEventProjector()
    interrupted.reconcile(
      exitStatus: 9, terminationReason: .uncaughtSignal, cancellationRequested: false)
    try expect(interrupted.state.outcome == .interrupted, "unrequested signal was not interrupted")
  }

  private static func outcome(_ lines: [String], exit: Int32) throws -> AgentOperationOutcome {
    var projector = AgentEventProjector()
    for line in lines { try projector.project(AgentEvent(raw: Data(line.utf8))) }
    projector.reconcile(exitStatus: exit, cancellationRequested: false)
    return projector.state.outcome
  }

  private static func testJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try OperationJournal(
      directoryURL: root.appendingPathComponent("operation"), recordLimit: 256, journalLimit: 1024)
    for record in [
      initEvent,
      #"{"type":"assistant","message":{"id":"M1","content":[{"type":"text","text":"hello"}]}}"#,
      successEvent,
    ] { try journal.append(Data(record.utf8)) }
    var before = try journal.replay()
    before.reconcile(exitStatus: 0, cancellationRequested: false)
    try expect(before.state.outcome == .turnCompleted, "journal replay did not reconcile")
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
    try swap.append(Data(#"{"type":"system","subtype":"init","session_id":"T1","tools":[]}"#.utf8))
    let accepted = try Data(contentsOf: swap.eventsURL)
    try FileManager.default.removeItem(at: swap.eventsURL)
    try FileManager.default.createSymbolicLink(at: swap.eventsURL, withDestinationURL: outside)
    try expectError(OperationJournalError.journalTampered) {
      try swap.append(Data(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#.utf8))
    }
    try expect(try Data(contentsOf: outside) == Data("outside".utf8), "symlink swap wrote outside")

    let truncate = try OperationJournal(
      directoryURL: root.appendingPathComponent("truncate-operation"))
    try truncate.append(Data(#"{"type":"system","subtype":"init","session_id":"T2","tools":[]}"#.utf8))
    try Data().write(to: truncate.eventsURL)
    try expectError(OperationJournalError.journalTampered) { _ = try truncate.replay() }

    let deleted = try OperationJournal(
      directoryURL: root.appendingPathComponent("delete-operation"))
    try deleted.append(Data(#"{"type":"system","subtype":"init","session_id":"T3","tools":[]}"#.utf8))
    try FileManager.default.removeItem(at: deleted.eventsURL)
    try expectError(OperationJournalError.journalTampered) {
      try deleted.append(Data(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#.utf8))
    }
    try expect(!accepted.isEmpty, "accepted replay prefix fixture was empty")
  }

  private static func testOperationResultRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let operationID = UUID()
    let result = AgentOperationResultV1(
      operationID: operationID, journalByteCount: 73,
      state: AgentProjectedState(
        externalThreadID: "session-1",
        messages: [.init(itemID: "message-1", draft: nil, committed: "answer")],
        terminalEvents: ["result.success"], outcome: .turnCompleted),
      exitStatus: 0, terminationReason: .exit)
    let store = AgentOperationResultStore(directoryURL: root)

    try store.write(result)
    let recovered = try store.read(
      expectedOperationID: operationID, expectedJournalByteCount: 73)

    try expect(recovered == result, "operation result changed during sidecar round-trip")
    try expect(recovered?.terminalEvent == "result.success", "terminal event was not retained")
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
    let accepted = AgentOperationResultV1(
      operationID: operationID, journalByteCount: 10,
      state: AgentProjectedState(outcome: .failed), exitStatus: 1,
      terminationReason: .exit)
    let store = AgentOperationResultStore(directoryURL: root, maximumBytes: 768)
    try store.write(accepted)

    let largeProjection = AgentOperationResultV1(
      operationID: operationID, journalByteCount: 10,
      state: AgentProjectedState(
        diagnostics: [String(repeating: "x", count: 2_048)], outcome: .protocolFailure),
      exitStatus: 1, terminationReason: .exit)
    try store.write(largeProjection)

    try expect(
      try store.read(expectedOperationID: operationID, expectedJournalByteCount: 10)
        == largeProjection,
      "large projected payload was copied into the bounded terminal sidecar")

    let rejectingStore = AgentOperationResultStore(directoryURL: root, maximumBytes: 1)
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
    let store = AgentOperationResultStore(directoryURL: root)
    try store.write(
      AgentOperationResultV1(
        operationID: operationID, journalByteCount: 41,
        state: AgentProjectedState(outcome: .interrupted), exitStatus: 9,
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
    let store = AgentOperationResultStore(directoryURL: root)
    try store.write(
      AgentOperationResultV1(
        operationID: operationID, journalByteCount: 41,
        state: AgentProjectedState(outcome: .interrupted), exitStatus: 9,
        terminationReason: .uncaughtSignal))

    do {
      _ = try store.read(expectedOperationID: operationID, expectedJournalByteCount: 42)
      throw TestFailure(description: "sidecar with a mismatched journal byte count was accepted")
    } catch let error as TestFailure { throw error } catch {}
  }

  private static func testCapabilityStates() throws {
    let missing = AgentCapabilityChecker().check(
      executableURL: URL(fileURLWithPath: "/definitely/missing/claude"))
    try expect(missing.status == .missing, "missing executable was not classified")
    try expect(
      AgentCapabilityChecker.classifyOperationFailure(
        diagnostics: [], stderr: "Not logged in · Please run /login") == .loggedOut,
      "logged-out failure was not classified")
    try expect(
      AgentCapabilityChecker.classifyOperationFailure(diagnostics: ["network failed"], stderr: "")
        == .invocationFailed,
      "generic failure was misclassified")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func check(_ name: String, _ contents: String) throws -> AgentCapabilityReport {
      AgentCapabilityChecker().check(
        executableURL: try makeExecutable(in: root, name: name, contents: contents))
    }
    try expect(try check("compatible", claudeScript()).status == .usable,
      "compatible capability surface was rejected")
    try expect(
      try check("old", claudeScript(version: "2.0.9 (Claude Code)")).status == .incompatible,
      "version below the capability floor was accepted")
    try expect(
      try check("other-cli", claudeScript(version: "codex-cli 0.159.2")).status == .incompatible,
      "a different CLI was accepted as Claude Code")
    let missingOption = try check(
      "missing-option",
      claudeScript(help: completeHelp.replacingOccurrences(of: "--effort <level>", with: "")))
    try expect(missingOption.status == .incompatible,
      "complete help without a required option was not classified as incompatible")
    try expect(missingOption.detail.contains("missing=--effort"),
      "incompatible help discarded its missing capability evidence")
    let incomplete = try check("incomplete-help", claudeScript(help: "--print"))
    try expect(incomplete.status == .invocationFailed,
      "incomplete help output was falsely classified as an incompatible CLI")
    let loggedOut = try check("logged-out", claudeScript(loggedIn: "false"))
    try expect(loggedOut.status == .loggedOut, "logged-out CLI was reported usable")
    try expect(loggedOut.detail.contains("claude auth login"), "logged-out state lost its remedy")
    try expect(
      try check("unknown-auth", claudeScript(authOutput: "not json")).status == .usable,
      "an unreadable auth probe blocked a usable CLI instead of deferring to the operation")
    try expect(
      try check("transient-help", transientHelpScript()).status == .usable,
      "a complete retry did not recover a transient incomplete help response")
    let highVolumeStarted = Date()
    try expect(
      try check("high-volume-help", paddedHelpScript()).status == .usable,
      "high-volume help output was not drained safely")
    try expect(
      Date().timeIntervalSince(highVolumeStarted) < 10,
      "high-volume help output blocked on a full process pipe")
  }

  private static func testResolverSkipsIncompatibleCandidate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let incompatible = try makeExecutable(
      in: root, name: "incompatible-claude",
      contents: claudeScript(version: "2.0.9 (Claude Code)"))
    let compatibleDirectory = root.appendingPathComponent("compatible-bin", isDirectory: true)
    let compatible = try makeExecutable(
      in: compatibleDirectory, name: "claude", contents: claudeScript())

    let selected = try AgentExecutableResolver().resolve(
      preferredPath: incompatible.path, environment: ["PATH": compatibleDirectory.path])

    try expect(
      selected.standardizedFileURL != incompatible.standardizedFileURL,
      "resolver returned the first executable without proving CLI compatibility")
    try expect(
      AgentCapabilityChecker().check(executableURL: selected).status == .usable,
      "resolver did not select a capability-checked executable after rejecting the first candidate")
    if selected.path.hasPrefix(root.path) {
      try expect(
        selected.standardizedFileURL == compatible.standardizedFileURL,
        "resolver skipped the next usable PATH candidate")
    }

    let loggedOutDirectory = root.appendingPathComponent("logged-out-bin", isDirectory: true)
    let loggedOut = try makeExecutable(
      in: loggedOutDirectory, name: "claude", contents: claudeScript(loggedIn: "false"))
    let error = AgentExecutableResolutionError(inspectedCandidates: [
      AgentCapabilityChecker().check(executableURL: loggedOut)
    ])
    try expect(
      error.localizedDescription.contains("claude auth login"),
      "logged-out resolution failure did not name the login remedy")
  }

  private static func testTransportAcceptedPrefix() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let malformed = try makeExecutable(
      in: root, name: "malformed",
      contents: "#!/bin/sh\nprintf '%s\\n' '\(initEvent)' '{\"type\":'\n")
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
        AgentProtocolDiagnostic.self, from: Data(contentsOf: diagnosticURL))
      try expect(
        persisted == malformedResult.protocolDiagnostic,
        "persisted protocol diagnostic differs from transport result")
    }

    let invalidUTF8 = try makeExecutable(
      in: root, name: "invalid-utf8",
      contents: "#!/bin/sh\nprintf '%s\\n' '\(initEvent)'\nprintf '\\377\\n'\n")
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
        "#!/bin/sh\nprintf '%s\\n' '\(initEvent)'\n/usr/bin/head -c 1048577 /dev/zero | /usr/bin/tr '\\000' a\nprintf '\\n'\n"
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
        "#!/bin/sh\nprintf '%s\\n' '\(initEvent)' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}'\n"
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
      contents: "#!/bin/sh\nprintf '%s\\n' '\(initEvent)'\nprintf '%s' '{\"type\":\"result\"}'\n")
    let partialJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("partial-journal"))
    let partialResult = try runFake(partial, journal: partialJournal)
    try expect(
      partialResult.protocolDiagnostic?.kind == .partialRecordAtEOF,
      "partial EOF reason missing")
    try expect(try journalRecords(partialJournal).count == 1, "partial EOF lost accepted prefix")

    let toolUse = try makeExecutable(
      in: root, name: "tool-use",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '\(initEvent)' '{\"type\":\"assistant\",\"message\":{\"id\":\"M1\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\"}]}}'\n"
    )
    let toolUseJournal = try OperationJournal(
      directoryURL: root.appendingPathComponent("tool-use-journal"))
    let toolUseResult = try runFake(toolUse, journal: toolUseJournal)
    try expect(toolUseResult.state.outcome == .protocolFailure, "tool use passed transport")
    try expect(
      toolUseResult.protocolDiagnostic?.kind == .projectionFailure,
      "tool-use transport diagnostic missing")
    try expect(
      try journalRecords(toolUseJournal).count == 2,
      "tool-use event was not journaled before projection rejection")

    let conflictingTerminals = try makeExecutable(
      in: root, name: "conflicting-terminals",
      contents:
        "#!/bin/sh\nprintf '%s\\n' '\(successEvent)' '\(successEvent.replacingOccurrences(of: "done", with: "again"))'\n"
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
        "#!/bin/sh\n/usr/bin/head -c 1200000 /dev/zero >&2\nprintf '%s\\n' '\(successEvent)'\n"
    )
    let noisyResult = try runFake(
      noisy, journal: OperationJournal(directoryURL: root.appendingPathComponent("noisy-journal")))
    try expect(noisyResult.stderr.count == 1_048_576, "stderr cap was not exact")
    try expect(noisyResult.state.outcome == .turnCompleted, "stderr cap changed successful outcome")
    try expect(noisyResult.retryDisposition == .none, "successful operation offered retry")

    let waits = try makeExecutable(
      in: root, name: "waits",
      contents:
        "#!/bin/sh\ntrap 'exit 143' TERM\nprintf '%s\\n' '\(initEvent)'\nwhile :; do :; done\n"
    )
    let immediate = AgentCancellationToken()
    immediate.cancel()
    let immediateResult = try runFake(
      waits, journal: OperationJournal(directoryURL: root.appendingPathComponent("immediate")),
      cancellation: immediate)
    try expect(immediateResult.state.outcome == .cancelled, "immediate cancel was not cancelled")
    try expect(
      immediateResult.retryDisposition == .explicitUserDecisionRequired,
      "cancel retry policy was not explicit")

    let late = AgentCancellationToken()
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
        printf '%s\\n' '\(initEvent.replacingOccurrences(of: "S1", with: "TREE"))'
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

  private static let testSystemPrompt = "TEST_SYSTEM_PROMPT"
  private static let initEvent =
    #"{"type":"system","subtype":"init","session_id":"S1","tools":[],"mcp_servers":[],"model":"claude-test","permissionMode":"dontAsk"}"#
  private static let successEvent =
    #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"S1"}"#
  private static let completeHelp = """
    Usage: claude [options] [command] [prompt]
    Options:
      -p, --print                  Print response and exit
      --output-format <format>     "text", "json", or "stream-json"
      --verbose                    Override verbose mode
      --tools <tools...>           Available built-in tools
      --strict-mcp-config          Only use MCP servers from --mcp-config
      --setting-sources <sources>  Setting sources to load
      --permission-mode <mode>     (choices: "acceptEdits", "dontAsk", "plan")
      --system-prompt <prompt>     System prompt
      --model <model>              Model for the session
      --effort <level>             Effort level
      --include-partial-messages   Include partial message chunks
      -r, --resume [value]         Resume a conversation
      --no-session-persistence     Disable session persistence
      -h, --help                   Display help for command
    """

  private static func claudeScript(
    version: String = "2.1.231 (Claude Code)", help: String = completeHelp,
    loggedIn: String = "true", authOutput: String? = nil
  ) -> String {
    let auth = authOutput ?? #"{"loggedIn": \#(loggedIn), "authMethod": "claude.ai"}"#
    return """
      #!/bin/sh
      case "$1" in
        --version) printf '%s\\n' '\(version)' ;;
        --help) cat <<'HELP'
      \(help)
      HELP
        ;;
        auth) printf '%s\\n' '\(auth)' ;;
        *) exit 2 ;;
      esac
      """
  }

  private static func transientHelpScript() -> String {
    """
    #!/bin/sh
    case "$1" in
      --version) printf '%s\\n' '2.1.231 (Claude Code)' ;;
      --help)
        state="$0.help-attempt"
        count=0
        test ! -f "$state" || count=$(cat "$state")
        count=$((count + 1))
        printf '%s\\n' "$count" > "$state"
        if [ "$count" -eq 1 ]; then printf '%s\\n' '--print'; else cat <<'HELP'
    \(completeHelp)
    HELP
        fi ;;
      auth) printf '%s\\n' '{"loggedIn": true}' ;;
    esac
    """
  }

  private static func paddedHelpScript() -> String {
    """
    #!/bin/sh
    case "$1" in
      --version) printf '%s\\n' '2.1.231 (Claude Code)' ;;
      --help) cat <<'HELP'
    \(completeHelp)
    HELP
        yes 'bounded capability padding 012345678901234567890123456789' | head -n 24000 ;;
      auth) yes 'bounded auth padding 012345678901234567890123456789' | head -n 12000
        printf '%s\\n' '{"loggedIn": true}' ;;
    esac
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
    cancellation: AgentCancellationToken = AgentCancellationToken(),
    policy: AgentTransportPolicy = AgentTransportPolicy(), prompt: String = "test"
  ) throws -> AgentTransportResult {
    let invocation = try AgentInvocation(
      executableURL: executable, kind: .new, systemPrompt: testSystemPrompt, prompt: prompt,
      workingDirectory: executable.deletingLastPathComponent())
    return try DirectProcessAgentTransport().execute(
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
