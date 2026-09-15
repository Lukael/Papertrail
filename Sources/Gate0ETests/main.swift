import Darwin
import Foundation
import PapertrailCore

struct Gate0ETestFailure: Error, CustomStringConvertible { let description: String }

actor ConcurrencyProbe {
  private var running = 0
  private var maximum = 0
  func enter() {
    running += 1
    maximum = max(maximum, running)
  }
  func leave() { running -= 1 }
  func maxSeen() -> Int { maximum }
}

actor CompletionOrder {
  private var values: [Int] = []
  func append(_ value: Int) { values.append(value) }
  func snapshot() -> [Int] { values }
}

actor StartMarker {
  private var started = false
  func mark() { started = true }
  func value() -> Bool { started }
}

@main
enum Gate0ETests {
  static func main() async throws {
    let sync: [(String, () throws -> Void)] = [
      ("exact deterministic transcript projection", testTranscriptProjection),
      ("review turns have concise stable chat projections", testReviewChatProjection),
      ("workspace staging is lossless bounded and owner-only", testWorkspaceStaging),
      ("paper pointer is the sole current-chat authority", testCurrentAuthority),
      ("replacement transaction preserves lineage and messages", testAtomicReplacement),
      ("launch reconciliation fails closed", testReconciliation),
      ("journal replay and app-owned message projection are idempotent", testJournalProjection),
      (
        "launch restores journal drafts and interrupts orphan operations",
        testLaunchOperationRecovery
      ),
      (
        "launch applies a valid terminal operation sidecar idempotently",
        testLaunchAppliesTerminalOperationSidecar
      ),
      (
        "launch does not trust a raw completed terminal without a sidecar",
        testLaunchRejectsUnsupervisedCompletedJournal
      ),
      ("chat bootstrap uses extracted text as sole paper authority", testBootstrapTextAuthority),
      ("cross-paper and historical writes are rejected", testIsolation),
      ("bounded user prompts are enforced", testPromptBound),
      ("UI and full-Xcode persistence source contracts are wired", testSourceContracts),
      ("every process outcome has truthful user-facing text", testOutcomeText),
      ("terminal protocol failures survive cleanup", testTerminalProtocolFailurePreserved),
      ("chat queue keys resolve canonical workspace identity", testCanonicalQueueKey),
    ]
    for (name, test) in sync {
      try test()
      print("PASS: \(name)")
    }
    try await testQueueSerialization()
    print("PASS: per-session queue serialization and overlap")
    try await testConcurrentInitialSendsResumeExactThread()
    print("PASS: concurrent initial sends commit then resume exact thread")
    try await testResumeFailureDoesNotDuplicateQueuedPrompt()
    print("PASS: resume failure does not duplicate a queued distinct prompt")
    try await testAmbiguousResumeFailureRequiresExplicitRetry()
    print("PASS: ambiguous resume failure requires explicit retry")
    try await testFailedResumePersistsWithoutReplacement()
    print("PASS: failed resume persists without automatic replacement")
    try await testFakeEndToEnd()
    print("PASS: fake exec resume replacement cancel retry restoration")
    try await testQueuedInvalidation()
    print("PASS: queued predecessor invalidation launches no child")
    try await testCancelWithWaiter()
    print("PASS: cancel targets running child rather than waiter")
    try await testRuntimeRegistryPaperIsolation()
    print("PASS: shared runtime cancellation is exact-key paper isolated")
    try await testSupplementarySourceRefresh()
    print("PASS: supplementary source refresh replaces stale chat context")
    try await testTamperedCachedTextRefresh()
    print("PASS: tampered staged text replaces stale chat context")
    try await testDurableResultSurvivesStoreCommitFailure()
    print("PASS: durable terminal result survives store commit failure")
    try await testCrossPaperReviewRejection()
    print("PASS: cross-paper selected review staging rejected")
    print("PASS: \(sync.count + 13) Gate 0E test groups")
  }

  static var root: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
  static var pdf: URL {
    root.appendingPathComponent("Fixtures/Papers/representative-paper.pdf")
  }
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw Gate0ETestFailure(description: message) }
  }

  static func testReviewChatProjection() throws {
    let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let first = ChatMessageIdentity.reviewRequest(operationID: operationID)
    let second = ChatMessageIdentity.reviewRequest(operationID: operationID)
    try expect(first == second, "review request message identity is not deterministic")
    let projected = ReviewChatProjection.request(paperTitle: "A\nPaper")
    try expect(
      projected.contains("Generate a Papertrail document for “A Paper”"),
      "review request projection lost its context")
    try expect(projected.contains("completed conversation captured") && projected.contains("separate from discussion"),
      "review request projection does not describe synthesis input")
    try expect(!projected.contains("\n"), "review request projection retained title control text")
    try expect(
      projected.utf8.count < ReviewPromptBuilder().productionPrompt().utf8.count,
      "review request projection duplicated the private production prompt")
  }
  static func temporarySupport() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate0e-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  static func fixture() throws -> (URL, LibraryPaths, DurableModelStore, Paper) {
    let support = try temporarySupport()
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let imported = try PDFImporter(paths: paths).importPDF(from: pdf, title: "Scoped Paper")
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(DurableSnapshot(papers: [imported.paper]))
    return (support, paths, store, imported.paper)
  }

  static func testTranscriptProjection() throws {
    let date = Date(timeIntervalSince1970: 1)
    let messages = [
      TranscriptMessage(id: "M1", role: .user, content: "old\r\nquestion", createdAt: date),
      TranscriptMessage(
        id: "M2", role: .assistant, content: "답변", createdAt: date.addingTimeInterval(1)),
      TranscriptMessage(
        id: "M3", role: .user, content: "new\\task", createdAt: date.addingTimeInterval(2)),
      TranscriptMessage(
        id: "D", role: .assistant, content: "draft", createdAt: date, committed: false),
      TranscriptMessage(id: "T", role: .tool, content: "hidden", createdAt: date),
    ]
    let projected = TranscriptContextProjector().project(
      predecessorSessionID: "S1", messages: messages)
    let expected =
      "TRANSCRIPT_CONTEXT_V1\n{\"predecessor_session_id\":\"S1\",\"budget_bytes\":32768,\"normalization\":\"NFC_LF\",\"selection\":\"newest_whole_message_suffix\"}\n{\"type\":\"omission\",\"count\":0,\"newest_omitted\":false}\n{\"id\":\"M1\",\"role\":\"user\",\"content\":\"old\\nquestion\"}\n{\"id\":\"M2\",\"role\":\"assistant\",\"content\":\"답변\"}\n{\"id\":\"M3\",\"role\":\"user\",\"content\":\"new\\\\task\"}\n"
    try expect(projected == Data(expected.utf8), "golden transcript bytes differ")
    try expect(
      projected
        == TranscriptContextProjector().project(predecessorSessionID: "S1", messages: messages),
      "projection is nondeterministic")
    let huge = TranscriptMessage(
      id: "NEW", role: .user, content: String(repeating: "x", count: 1000), createdAt: date)
    let bounded = String(
      decoding: TranscriptContextProjector().project(
        predecessorSessionID: "S", messages: [messages[0], huge], budgetBytes: 300), as: UTF8.self)
    try expect(
      bounded.contains("\"newest_omitted\":true"), "oversized newest was truncated/included")
    try expect(!bounded.contains("old"), "older message included after newest omission")
  }

  static func testWorkspaceStaging() throws {
    let (support, paths, _, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let workspace = paths.chatWorkspace(UUID(), paperID: paper.id)
    let sourceURL = try paths.url(forRelativePath: paper.sourceRelativePath)
    let extractedText = try PDFExtractedTextCache(paths: paths).resolve(
      paperID: paper.id, sourceURL: sourceURL,
      expectedSourceSHA256: paper.sourceSHA256)
    let result = try ChatBootstrapBuilder().stage(
      sourceURL: sourceURL,
      expectedSourceSHA256: paper.sourceSHA256, workspaceURL: workspace,
      context: .init(paperID: paper.id, title: "Title\n$(touch nope)"),
      extractedText: extractedText)
    try expect(result.sourceSHA256 == paper.sourceSHA256, "staged source hash differs")
    try expect(
      result.extractedTextSHA256 == extractedText.manifest.textSHA256,
      "staged extracted-text identity differs")
    let stagedText = workspace.appendingPathComponent("input/paper-text.txt")
    try expect(
      FileManager.default.fileExists(atPath: stagedText.path),
      "verified extracted text was not staged")
    let stagedTextMode = (try FileManager.default.attributesOfItem(atPath: stagedText.path)[
      .posixPermissions
    ] as? NSNumber)?.intValue ?? -1
    try expect(stagedTextMode == 0o400, "staged extracted text is not read-only")
    try expect(!result.bootstrapPrompt.contains("auth.json"), "bootstrap requested credentials")
    try expect(
      result.bootstrapPrompt.utf8.count <= ChatBootstrapBuilder.maximumPromptBytes,
      "bootstrap unbounded")
    for phrase in [
      PaperChatSystemPromptBuilder.marker, "SOURCE_SCOPE: full_paper", "AUTHOR STATEMENT",
      "DIRECT EVIDENCE", "INTERPRETATION", "UNRESOLVED", "[p. 4]", "[Sec. 3.2]",
      "input/paper-text.txt", "primary authority", "Match depth to the question",
    ] {
      try expect(result.bootstrapPrompt.contains(phrase), "chat system prompt lacks \(phrase)")
    }
    try expect(
      result.bootstrapPrompt.contains(PaperChatSystemPromptBuilder.marker),
      "chat system prompt version marker is not staged")
    try expect(
      !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("source.pdf").path),
      "archival PDF was exposed inside the agent workspace")
    try expect(
      result.bootstrapPrompt.contains("source_sha256: \(paper.sourceSHA256)"),
      "app-owned source identity is missing from the bootstrap")
    let review = support.appendingPathComponent("review", isDirectory: true)
    try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
    try Data("<html>review</html>".utf8).write(to: review.appendingPathComponent("index.html"))
    let replacementID = UUID()
    let transcript = TranscriptContextProjector().project(
      predecessorSessionID: "OLD", messages: [])
    let withReview = try ChatBootstrapBuilder().stage(
      sourceURL: try paths.url(forRelativePath: paper.sourceRelativePath),
      expectedSourceSHA256: paper.sourceSHA256,
      workspaceURL: paths.chatWorkspace(replacementID, paperID: paper.id),
      context: .init(
        paperID: paper.id, title: paper.canonicalTitle,
        predecessorSessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
        transcript: transcript, selectedReviewRelativePath: "selected-review/index.html",
        selectedReviewQualityNote: "Generated · structure checked; not independently verified"),
      extractedText: extractedText,
      selectedReviewURL: review)
    let copiedReview = withReview.workspaceURL.appendingPathComponent("selected-review")
      .appendingPathComponent("index.html")
    let descendants =
      (try? FileManager.default.subpathsOfDirectory(
        atPath: withReview.workspaceURL.path)) ?? []
    try expect(
      FileManager.default.fileExists(atPath: copiedReview.path),
      "selected review copy missing: \(descendants)")
    try expect(
      withReview.bootstrapPrompt.contains("not independently verified"), "review caveat missing")
    try expect(
      withReview.bootstrapPrompt.contains("TRANSCRIPT_CONTEXT_V1"), "replacement transcript missing"
    )
  }

  static func testBootstrapTextAuthority() throws {
    let prompt = try ChatBootstrapBuilder().prompt(
      context: .init(paperID: UUID(), title: "Text authority"),
      sourceSHA256: String(repeating: "b", count: 64),
      extractedTextSHA256: String(repeating: "a", count: 64))
    let lowercased = prompt.lowercased()
    try expect(
      lowercased.contains("primary_text: input/paper-text.txt")
        && lowercased.contains("input/paper-text.txt")
        && lowercased.contains("primary authority"),
      "bootstrap does not make the cached extracted text the primary paper authority")
    for forbidden in [
      "source.pdf takes precedence", "use staged source.pdf only", "read source.pdf",
      "check the complete staged pdf", "parse source.pdf",
    ] {
      try expect(
        !lowercased.contains(forbidden),
        "bootstrap still directs Codex back to PDF parsing via: \(forbidden)")
    }
  }

  static func testCurrentAuthority() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let chat = PortablePaperChatStore(store: store)
    let id = UUID()
    let workspace = paths.chatWorkspace(id, paperID: paper.id)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    _ = try chat.createInitialSession(
      paperID: paper.id, sessionID: id, workspaceRelativePath: paths.relativePath(for: workspace))
    let snapshot = try store.load()
    try expect(snapshot.papers[0].currentChatSessionID == id, "pointer not persisted")
    try expect(
      !String(data: try JSONEncoder().encode(snapshot.sessions[0]), encoding: .utf8)!.contains(
        "isCurrentChat"), "dual current flag persisted")
    try expect(
      try chat.currentSession(paperID: paper.id)?.id == id,
      "current session not derived from pointer")
  }

  static func testAtomicReplacement() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let chat = PortablePaperChatStore(store: store)
    let old = UUID()
    let new = UUID()
    let oldWorkspace = paths.chatWorkspace(old, paperID: paper.id)
    try FileManager.default.createDirectory(at: oldWorkspace, withIntermediateDirectories: true)
    _ = try chat.createInitialSession(
      paperID: paper.id, sessionID: old,
      workspaceRelativePath: paths.relativePath(for: oldWorkspace))
    var snapshot = try store.load()
    let messageID = UUID()
    snapshot.messages.append(
      ChatMessage(
        id: messageID, paperID: paper.id, sessionID: old, role: "assistant",
        committedContent: "kept", deliveryState: "committed"))
    try store.save(snapshot)
    let staged = paths.chatWorkspace(new, paperID: paper.id)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    try expect(
      try store.load().papers[0].currentChatSessionID == old,
      "staging changed pointer before commit")
    _ = try chat.commitReplacement(
      paperID: paper.id, predecessorSessionID: old, successorSessionID: new,
      workspaceRelativePath: paths.relativePath(for: staged), reason: "resume failed")
    snapshot = try store.load()
    let predecessor = snapshot.sessions.first { $0.id == old }!
    try expect(snapshot.papers[0].currentChatSessionID == new, "successor pointer not committed")
    try expect(
      predecessor.lifecycle == .historical && predecessor.replacementSessionID == new,
      "predecessor lineage missing")
    try expect(
      snapshot.messages.first?.id == messageID && snapshot.messages.first?.sessionID == old,
      "historical message lineage changed")
  }

  static func testReconciliation() throws {
    let paper = UUID()
    let valid = UUID()
    let other = UUID()
    let sessions = [
      SessionSnapshot(id: valid, paperID: paper, purpose: .paperChat),
      SessionSnapshot(id: other, paperID: UUID(), purpose: .paperChat),
    ]
    let reconciler = LaunchReconciler()
    try expect(
      reconciler.reconcileCurrentChat(
        paperID: paper, currentPointer: valid, sessions: sessions, legacyMigrationRequested: true,
        legacyCurrentSessionIDs: [other]
      ).currentChatSessionID == valid, "valid pointer did not win")
    let invalid = reconciler.reconcileCurrentChat(
      paperID: paper, currentPointer: other, sessions: sessions)
    try expect(
      invalid.currentChatSessionID == nil && invalid.repairState == .currentChatPointerInvalid,
      "cross-paper pointer did not fail closed")
    let ambiguous = reconciler.reconcileCurrentChat(
      paperID: paper, currentPointer: nil, sessions: sessions, legacyMigrationRequested: true,
      legacyCurrentSessionIDs: [])
    try expect(
      ambiguous.repairState == .legacyCurrentChatAmbiguous, "ambiguous legacy state guessed")
  }

  static func testJournalProjection() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let journal = try OperationJournal(directoryURL: support.appendingPathComponent("op"))
    let lines = [
      #"{"type":"thread.started","thread_id":"T1"}"#, #"{"type":"turn.started","turn_id":"R1"}"#,
      #"{"type":"item.started","item":{"id":"M1","type":"agent_message","text":"hel"}}"#,
      #"{"type":"item.updated","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"item.completed","item":{"id":"M1","type":"agent_message","text":"hello"}}"#,
      #"{"type":"reasoning.completed","item":{"id":"X","type":"reasoning","text":"secret"}}"#,
      #"{"type":"turn.completed","turn_id":"R1"}"#,
    ]
    for line in lines { try journal.append(Data(line.utf8)) }
    var first = try journal.replay()
    first.reconcile(exitStatus: 0, cancellationRequested: false)
    var second = try journal.replay()
    second.reconcile(exitStatus: 0, cancellationRequested: false)
    try expect(try first.state.stableBytes() == second.state.stableBytes(), "replay differs")
    try expect(
      first.state.messages.count == 1 && first.state.messages[0].committed == "hello",
      "projection incorrect")
  }

  static func testLaunchOperationRecovery() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let sessionID = UUID()
    let operationID = UUID()
    let healthyOperationID = UUID()
    let userID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paper.id)
    let operationDirectory = paths.operationDirectory(
      operationID: operationID, forAgentWorkspace: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    var snapshot = try store.load()
    snapshot.papers[0].currentChatSessionID = sessionID
    snapshot.sessions = [
      CodexSession(
        id: sessionID, paperID: paper.id, purpose: .paperChat,
        workspaceRelativePath: try paths.relativePath(for: workspace), lifecycle: .staged)
    ]
    var operation = CodexOperation(
      id: operationID, clientOperationID: operationID, sessionID: sessionID, kind: "chatTurn",
      promptSHA256: "x", journalRelativePath: try paths.relativePath(for: operationDirectory))
    operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
    var healthyOperation = CodexOperation(
      id: healthyOperationID, clientOperationID: healthyOperationID, sessionID: sessionID,
      kind: "chatTurn", promptSHA256: "y",
      journalRelativePath: try paths.relativePath(
        for: paths.operationDirectory(
          operationID: healthyOperationID, forAgentWorkspace: workspace)))
    healthyOperation.processOutcomeRawValue = ProcessOutcome.running.rawValue
    snapshot.operations = [operation, healthyOperation]
    snapshot.messages = [
      ChatMessage(
        id: userID, paperID: paper.id, sessionID: sessionID, operationID: operationID, role: "user",
        committedContent: "queued", deliveryState: "queued")
    ]
    try store.save(snapshot)
    do {
      let journal = try OperationJournal(directoryURL: operationDirectory)
      try journal.append(Data(#"{"type":"thread.started","thread_id":"recovered-thread"}"#.utf8))
      try journal.append(
        Data(
          #"{"type":"item.updated","item":{"id":"draft-1","type":"agent_message","text":"partial"}}"#
            .utf8))
    }
    let corruptTail = try FileHandle(
      forWritingTo: operationDirectory.appendingPathComponent("events.jsonl"))
    try corruptTail.seekToEnd()
    try corruptTail.write(contentsOf: Data(#"{"type":"item.updated""#.utf8))
    try corruptTail.close()
    let healthyDirectory = paths.operationDirectory(
      operationID: healthyOperationID, forAgentWorkspace: workspace)
    let healthyJournal = try OperationJournal(directoryURL: healthyDirectory)
    try healthyJournal.append(
      Data(
        #"{"type":"item.completed","item":{"id":"healthy","type":"agent_message","text":"kept"}}"#
          .utf8))
    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    snapshot = try store.load()
    try expect(snapshot.sessions[0].lifecycle == .active, "pointed session was not restored active")
    try expect(
      snapshot.operations.allSatisfy {
        $0.processOutcomeRawValue == ProcessOutcome.interrupted.rawValue
      }, "one corrupt journal blocked operation isolation")
    try expect(
      snapshot.messages.contains(where: {
        $0.draftContent == "partial" && $0.sessionID == sessionID
      }), "accepted draft was not replayed")
    try expect(
      snapshot.messages.contains(where: { $0.committedContent == "kept" }),
      "healthy operation was not reconciled after corrupt sibling journal")
    try expect(
      issues.contains(
        .corruptOperationJournal(
          operationID: operationID,
          relativePath: try paths.relativePath(for: operationDirectory))),
      "corrupt journal was not reported as an operation-scoped recovery issue")
    try expect(
      snapshot.messages.first(where: { $0.id == userID })?.deliveryStateRawValue
        == ProcessOutcome.interrupted.rawValue, "queued user state was not recovered")
    try expect(
      snapshot.sessions.first(where: { $0.id == sessionID })?.externalThreadID
        == "recovered-thread",
      "accepted thread.started identity was not restored from the operation journal")
  }

  static func testLaunchAppliesTerminalOperationSidecar() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let sessionID = UUID()
    let operationID = UUID()
    let userID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paper.id)
    let operationDirectory = paths.operationDirectory(
      operationID: operationID, forAgentWorkspace: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    var snapshot = try store.load()
    snapshot.papers[0].currentChatSessionID = sessionID
    snapshot.sessions = [
      CodexSession(
        id: sessionID, paperID: paper.id, purpose: .paperChat,
        workspaceRelativePath: try paths.relativePath(for: workspace), lifecycle: .staged)
    ]
    var operation = CodexOperation(
      id: operationID, clientOperationID: operationID, sessionID: sessionID, kind: "chatTurn",
      promptSHA256: "sidecar", journalRelativePath: try paths.relativePath(for: operationDirectory))
    operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
    snapshot.operations = [operation]
    snapshot.messages = [
      ChatMessage(
        id: userID, paperID: paper.id, sessionID: sessionID, operationID: operationID, role: "user",
        committedContent: "question", deliveryState: "queued")
    ]
    try store.save(snapshot)

    let journal = try OperationJournal(directoryURL: operationDirectory)
    for record in [
      #"{"type":"thread.started","thread_id":"sidecar-thread"}"#,
      #"{"type":"turn.started","turn_id":"sidecar-turn"}"#,
      #"{"type":"item.completed","item":{"id":"sidecar-message","type":"agent_message","text":"durable answer"}}"#,
      #"{"type":"turn.completed","turn_id":"sidecar-turn"}"#,
    ] { try journal.append(Data(record.utf8)) }
    var projector = try journal.replay()
    projector.reconcile(exitStatus: 0, cancellationRequested: false)
    let durableResult = CodexOperationResultV1(
      operationID: operationID, journalByteCount: journal.sizeBytes, state: projector.state,
      exitStatus: 0, terminationReason: .exit)
    try CodexOperationResultStore(directoryURL: operationDirectory).write(durableResult)

    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    let once = try store.load()
    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    let twice = try store.load()

    try expect(
      once.operations.first { $0.id == operationID }?.processOutcomeRawValue
        == ProcessOutcome.turnCompleted.rawValue,
      "valid terminal sidecar did not restore the completed operation")
    try expect(
      once.sessions.first { $0.id == sessionID }?.externalThreadID == "sidecar-thread",
      "valid terminal sidecar did not restore the external thread")
    try expect(
      once.messages.contains {
        $0.operationID == operationID && $0.roleRawValue == "assistant"
          && $0.committedContent == "durable answer"
          && $0.deliveryStateRawValue == "committed"
      }, "valid terminal sidecar did not restore the committed assistant answer")
    try expect(
      once.messages.first { $0.id == userID }?.deliveryStateRawValue == "committed",
      "valid terminal sidecar did not commit the queued user message")
    try expect(
      once.messages.filter { $0.operationID == operationID }.count
        == twice.messages.filter { $0.operationID == operationID }.count,
      "repeated launch reconciliation duplicated recovered messages")
    try expect(
      twice.operations.first { $0.id == operationID }?.processOutcomeRawValue
        == ProcessOutcome.turnCompleted.rawValue,
      "repeated launch reconciliation changed the recovered terminal outcome")
  }

  static func testLaunchRejectsUnsupervisedCompletedJournal() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let sessionID = UUID()
    let operationID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paper.id)
    let operationDirectory = paths.operationDirectory(
      operationID: operationID, forAgentWorkspace: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    var snapshot = try store.load()
    snapshot.papers[0].currentChatSessionID = sessionID
    snapshot.sessions = [
      CodexSession(
        id: sessionID, paperID: paper.id, purpose: .paperChat,
        workspaceRelativePath: try paths.relativePath(for: workspace), lifecycle: .staged)
    ]
    var operation = CodexOperation(
      id: operationID, clientOperationID: operationID, sessionID: sessionID, kind: "chatTurn",
      promptSHA256: "journal-only",
      journalRelativePath: try paths.relativePath(for: operationDirectory))
    operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
    snapshot.operations = [operation]
    try store.save(snapshot)

    let journal = try OperationJournal(directoryURL: operationDirectory)
    for record in [
      #"{"type":"thread.started","thread_id":"journal-only-thread"}"#,
      #"{"type":"turn.started","turn_id":"journal-only-turn"}"#,
      #"{"type":"item.completed","item":{"id":"journal-only-message","type":"agent_message","text":"unverified answer"}}"#,
      #"{"type":"turn.completed","turn_id":"journal-only-turn"}"#,
    ] { try journal.append(Data(record.utf8)) }

    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    snapshot = try store.load()
    try expect(
      snapshot.operations.first { $0.id == operationID }?.processOutcomeRawValue
        == ProcessOutcome.interrupted.rawValue,
      "raw turn.completed was trusted without a supervised result sidecar")
  }

  static func testIsolation() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    var snapshot = try store.load()
    let other = Paper(
      canonicalTitle: "Other", safeBasename: "other", sourceRelativePath: paper.sourceRelativePath,
      sourceSHA256: paper.sourceSHA256)
    snapshot.papers.append(other)
    try store.save(snapshot)
    let chat = PortablePaperChatStore(store: store)
    let session = UUID()
    let workspace = paths.chatWorkspace(session, paperID: paper.id)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    _ = try chat.createInitialSession(
      paperID: paper.id, sessionID: session,
      workspaceRelativePath: paths.relativePath(for: workspace))
    do {
      _ = try chat.prepareTurn(
        paperID: other.id, sessionID: session, prompt: "leak", operationID: UUID(),
        userMessageID: UUID(), journalRelativePath: "x", retryPredecessorID: nil)
      throw Gate0ETestFailure(description: "cross-paper write accepted")
    } catch is ChatStoreError {}
    let successor = UUID()
    let ws2 = paths.chatWorkspace(successor, paperID: paper.id)
    try FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
    _ = try chat.commitReplacement(
      paperID: paper.id, predecessorSessionID: session, successorSessionID: successor,
      workspaceRelativePath: paths.relativePath(for: ws2), reason: "test")
    do {
      _ = try chat.prepareTurn(
        paperID: paper.id, sessionID: session, prompt: "old", operationID: UUID(),
        userMessageID: UUID(), journalRelativePath: "x", retryPredecessorID: nil)
      throw Gate0ETestFailure(description: "historical session accepted write")
    } catch is ChatStoreError {}
  }

  static func testPromptBound() throws {
    let (support, paths, store, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let chat = PortablePaperChatStore(store: store)
    let session = UUID()
    let ws = paths.chatWorkspace(session, paperID: paper.id)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    _ = try chat.createInitialSession(
      paperID: paper.id, sessionID: session, workspaceRelativePath: paths.relativePath(for: ws))
    do {
      _ = try chat.prepareTurn(
        paperID: paper.id, sessionID: session, prompt: String(repeating: "x", count: 16_385),
        operationID: UUID(), userMessageID: UUID(), journalRelativePath: "x",
        retryPredecessorID: nil)
      throw Gate0ETestFailure(description: "oversize prompt accepted")
    } catch ChatStoreError.messageTooLarge {}
  }

  static func testSourceContracts() throws {
    let app = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailApp/PaperChatController.swift"), encoding: .utf8)
    let view = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailApp/PaperWorkspaceViews.swift"), encoding: .utf8)
    let library = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailApp/PaperLibraryController.swift"), encoding: .utf8)
    let coordinator = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailCore/Chat/PaperChatCoordinator.swift"), encoding: .utf8)
    let swiftData = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailCore/Chat/SwiftDataPaperChatStore.swift"), encoding: .utf8)
    for required in [
      "coordinator.send", "cancelCurrent", "refreshContext", "func retry", "canRetry",
      "executableProvider.executableURL()", "resolvedCoordinator()", "messages.append(",
      "liveAssistant = ChatLiveAssistantState", "progressHandler()",
    ] { try expect(app.contains(required), "UI controller lacks \(required)") }
    for required in [
      "PaperChatView", "ForEach(controller.messages.suffix(from: firstVisibleIndex))", "Cancel", "Refresh context",
      "Button(\"Retry\")", "CodexModelSelection.allCases", "CodexReasoningEffort.allCases",
      "Menu {", "chatComposerPanel", ".safeAreaInset(edge: .bottom", "ChatMessageRow",
      ".frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)",
      ".padding(.bottom, 40)", "ChatLiveResponseRow", "Thinking", "liveRevision",
    ] { try expect(view.contains(required), "chat UI lacks \(required)") }
    try expect(!view.contains("Menu(\"Section\""), "workspace retained the redundant Section menu")
    for removedButton in [
      "Button(\"Show paper\")", "Button(\"Show review\")", "Button(\"Show chat\")",
    ] {
      try expect(!view.contains(removedButton), "workspace toolbar retained \(removedButton)")
    }
    for required in [
      "@ObservedObject var reviewController", "@ObservedObject var chatController",
      ".id(selectedPaper.id)",
    ] {
      try expect(
        view.contains(required),
        "workspace does not preserve/reset controller identity via \(required)")
    }
    try expect(
      !view.contains("PaperChatController("), "transient workspace view constructs chat controller")
    for required in [
      "chatRuntimeRegistry", "reviewControllers", "chatControllers", "func reviewController",
      "func chatController", "codexEffort", "reasoningEffort: codexEffort",
    ] {
      try expect(library.contains(required), "root controller registry lacks \(required)")
    }
    for required in [
      "SwiftDataPaperChatStore", "context.save()", "currentChatSessionID", "predecessorSessionID",
    ] { try expect(swiftData.contains(required), "SwiftData path lacks \(required)") }
    for required in [
      "progress: (@Sendable (CodexLiveProgress) -> Void)?", "progress: progress",
    ] { try expect(coordinator.contains(required), "chat progress path lacks \(required)") }
  }

  static func testCanonicalQueueKey() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let canonical = support.appendingPathComponent("canonical", isDirectory: true)
    let alias = support.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)
    let sessionID = UUID()
    try expect(
      ChatQueueKey(sessionID: sessionID, workspaceURL: canonical)
        == ChatQueueKey(sessionID: sessionID, workspaceURL: alias),
      "symlink alias created a second queue identity")
  }

  static func testOutcomeText() throws {
    let terminal: [CodexOperationOutcome] = [
      .turnCompleted, .failed, .cancelled, .timedOut, .interrupted, .protocolFailure,
    ]
    let messages = terminal.map { ChatOutcomePresentation.message(outcome: $0) }
    try expect(
      Set(messages).count == terminal.count, "terminal outcomes share ambiguous status text")
    for outcome in terminal where outcome != .turnCompleted {
      let text = ChatOutcomePresentation.message(outcome: outcome).lowercased()
      try expect(!text.contains("completed successfully"), "failure text overclaims success")
    }
    let replacedFailure = ChatOutcomePresentation.message(
      outcome: .failed, replacementCompleted: true)
    try expect(replacedFailure.contains("failed"), "replacement alone was presented as success")
    let replacedSuccess = ChatOutcomePresentation.message(
      outcome: .turnCompleted, replacementCompleted: true)
    try expect(replacedSuccess.contains("retried turn completed"), "replacement success is unclear")
  }

  static func testTerminalProtocolFailurePreserved() throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let store = PortablePaperChatStore(store: durable)
    let sessionID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paper.id)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    _ = try store.createInitialSession(
      paperID: paper.id, sessionID: sessionID,
      workspaceRelativePath: paths.relativePath(for: workspace))
    var snapshot = try durable.load()
    snapshot.sessions[0].externalThreadID = "T1"
    try durable.save(snapshot)
    let operationID = UUID()
    _ = try store.prepareTurn(
      paperID: paper.id, sessionID: sessionID, prompt: "mismatch",
      operationID: operationID, userMessageID: UUID(), journalRelativePath: "operations/x",
      retryPredecessorID: nil)
    let result = CodexTransportResult(
      state: CodexProjectedState(
        externalThreadID: "T2", terminalEvents: ["turn.completed:t"],
        outcome: .turnCompleted),
      exitStatus: 0, terminationReason: .exit, stderr: Data())
    do {
      try store.applyTransportResult(operationID: operationID, result: result)
      throw Gate0ETestFailure(description: "external-thread mismatch was accepted")
    } catch is SessionOperationQueueError {}
    try store.recordOperationFailure(operationID: operationID, outcome: .interrupted)
    snapshot = try durable.load()
    try expect(
      snapshot.operations.first { $0.id == operationID }?.processOutcomeRawValue
        == ProcessOutcome.protocolFailure.rawValue,
      "cleanup overwrote persisted protocolFailure")
    try expect(
      snapshot.messages.filter { $0.operationID == operationID }.allSatisfy {
        $0.deliveryStateRawValue == ProcessOutcome.protocolFailure.rawValue
      }, "cleanup overwrote protocolFailure message state")
  }

  static func testSupplementarySourceRefresh() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    _ = try await coordinator.send(paperID: paper.id, text: "seed")
    guard let predecessor = try store.currentSession(paperID: paper.id) else {
      throw Gate0ETestFailure(description: "initial chat session missing")
    }

    let supplementary = root.appendingPathComponent("Fixtures/Papers/untrusted-content-paper.pdf")
    let receipt = try SupplementaryPDFMerger(paths: paths).merge(
      paperID: paper.id, currentSourceRelativePath: paper.sourceRelativePath,
      expectedSourceSHA256: paper.sourceSHA256, supplementaryURL: supplementary)
    try durable.transaction { snapshot in
      guard let index = snapshot.papers.firstIndex(where: { $0.id == paper.id }) else {
        throw Gate0ETestFailure(description: "paper disappeared before source update")
      }
      snapshot.papers[index].sourceRelativePath = receipt.sourceRelativePath
      snapshot.papers[index].sourceSHA256 = receipt.sourceSHA256
      snapshot.papers[index].updatedAt = Date()
    }

    let result = try await coordinator.send(paperID: paper.id, text: "use supplement")
    guard let successor = try store.currentSession(paperID: paper.id) else {
      throw Gate0ETestFailure(description: "replacement chat session missing")
    }
    try expect(successor.id != predecessor.id, "stale chat session was reused")
    try expect(
      successor.predecessorSessionID == predecessor.id,
      "replacement chat session lost predecessor lineage")
    try expect(
      result.sessionID == successor.id && result.outcome == .turnCompleted,
      "turn did not run in the refreshed context")
    let successorWorkspace = try paths.url(forRelativePath: successor.workspaceRelativePath)
    try expect(
      !FileManager.default.fileExists(
        atPath: successorWorkspace.appendingPathComponent("source.pdf").path),
      "replacement chat workspace exposed the combined PDF")
    let bootstrap = try String(
      contentsOf: successorWorkspace.appendingPathComponent("bootstrap.txt"),
      encoding: .utf8)
    try expect(
      bootstrap.contains("source_sha256: \(receipt.sourceSHA256)"),
      "replacement chat workspace did not bind the combined source identity")
    try expect(bootstrap.contains("TRANSCRIPT_CONTEXT_V1"), "chat history was not carried forward")
  }

  static func testTamperedCachedTextRefresh() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    _ = try await coordinator.send(paperID: paper.id, text: "seed")
    let predecessor = try store.currentSession(paperID: paper.id)!
    let predecessorWorkspace = try paths.url(forRelativePath: predecessor.workspaceRelativePath)
    let stagedText = predecessorWorkspace.appendingPathComponent("input/paper-text.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedText.path)
    try Data("tampered".utf8).write(to: stagedText)

    let result = try await coordinator.send(paperID: paper.id, text: "after tamper")
    let successor = try store.currentSession(paperID: paper.id)!
    try expect(successor.id != predecessor.id, "tampered cached text session was reused")
    try expect(
      result.sessionID == successor.id && result.outcome == .turnCompleted,
      "turn did not run in a restaged cached-text context")
    let restoredText = try paths.url(forRelativePath: successor.workspaceRelativePath)
      .appendingPathComponent("input/paper-text.txt")
    try expect(
      try FileFingerprint.read(restoredText).sha256 != FileFingerprint.read(stagedText).sha256,
      "replacement did not restore verified cached paper text")
  }

  static func testDurableResultSurvivesStoreCommitFailure() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let underlying = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(
      store: FailingApplyPaperChatStore(underlying: underlying), paths: paths,
      executableURL: fake)
    do {
      _ = try await coordinator.send(paperID: paper.id, text: "commit gap")
      throw Gate0ETestFailure(description: "injected store commit failure was not observed")
    } catch let failure as Gate0ETestFailure {
      throw failure
    } catch {}

    var snapshot = try durable.load()
    guard let operation = snapshot.operations.last else {
      throw Gate0ETestFailure(description: "prepared operation missing")
    }
    try expect(
      operation.processOutcomeRawValue == ProcessOutcome.running.rawValue,
      "durable sidecar was hidden by marking the DB operation interrupted")
    let operationDirectory = try paths.url(forRelativePath: operation.journalRelativePath)
    try expect(
      FileManager.default.fileExists(
        atPath: operationDirectory.appendingPathComponent("operation-result.json").path),
      "terminal sidecar was not written before the injected store failure")

    _ = try ApplicationLaunchCoordinator.reconcile(store: durable, paths: paths)
    snapshot = try durable.load()
    try expect(
      snapshot.operations.last?.processOutcomeRawValue == ProcessOutcome.turnCompleted.rawValue,
      "launch recovery did not apply the durable terminal sidecar")
    try expect(
      snapshot.messages.contains {
        $0.operationID == operation.id && $0.roleRawValue == "assistant"
          && $0.deliveryStateRawValue == "committed"
      }, "launch recovery lost the assistant answer after store commit failure")
  }

  static func testQueueSerialization() async throws {
    let queue = SessionOperationQueue()
    let probeA = ConcurrencyProbe()
    let probeAll = ConcurrencyProbe()
    let order = CompletionOrder()
    let key = ChatQueueKey(sessionID: UUID(), workspaceURL: URL(fileURLWithPath: "/tmp/a"))
    let keyB = ChatQueueKey(sessionID: UUID(), workspaceURL: URL(fileURLWithPath: "/tmp/b"))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          _ = try await queue.run(key: key, presentedExternalThreadID: nil) {
            await probeA.enter()
            await probeAll.enter()
            try await Task.sleep(for: .milliseconds(index == 0 ? 40 : 1))
            await order.append(index)
            await probeAll.leave()
            await probeA.leave()
            return 0
          }
        }
        try await Task.sleep(for: .milliseconds(1))
      }
      group.addTask {
        _ = try await queue.run(key: keyB, presentedExternalThreadID: nil) {
          await probeAll.enter()
          try await Task.sleep(for: .milliseconds(20))
          await probeAll.leave()
          return 0
        }
      }
      try await group.waitForAll()
    }
    let maxA = await probeA.maxSeen()
    let maxAll = await probeAll.maxSeen()
    let completionOrder = await order.snapshot()
    try expect(maxA == 1, "same key ran concurrently")
    try expect(maxAll >= 2, "different keys did not overlap")
    try expect(completionOrder == Array(0..<100), "same-key FIFO completion order changed")
    try await queue.bind(externalThreadID: "T1", to: key)
    do {
      _ = try await queue.run(key: key, presentedExternalThreadID: "T2") { 0 }
      throw Gate0ETestFailure(description: "thread mismatch accepted")
    } catch is SessionOperationQueueError {}
    do {
      _ = try await queue.run(key: key, presentedExternalThreadID: nil) { 0 }
      throw Gate0ETestFailure(description: "stale unbound waiter accepted after thread binding")
    } catch is SessionOperationQueueError {}
  }

  static func fakeExecutable(at url: URL) throws {
    let script = """
      #!/bin/sh
      set -eu
      prompt=$(cat)
      printf '%s\\n' "$*" >> invocations.log
      printf '%s\\n' "$prompt" >> prompts.log
      if printf '%s' "$prompt" | grep -q '\\[SLOW\\]'; then sleep 10; fi
      turn="turn-$(wc -l < invocations.log | tr -d ' ')"
      printf '{"type":"turn.started","turn_id":"%s"}\\n' "$turn"
      if [ -f fail-resume ] && [ "${2:-}" = "resume" ]; then rm fail-resume; printf '{"type":"turn.failed","turn_id":"%s"}\\n' "$turn"; exit 1; fi
      if [ "${2:-}" != "resume" ]; then printf '{"type":"thread.started","thread_id":"thread-%s"}\\n' "$turn"; fi
      printf '{"type":"item.completed","item":{"id":"msg-%s","type":"agent_message","text":"answer-%s"}}\\n' "$turn" "$turn"
      printf '{"type":"turn.completed","turn_id":"%s"}\\n' "$turn"
      """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  static func controlledExecutable(at url: URL) throws {
    let script = """
      #!/bin/sh
      set -eu
      prompt=$(cat)
      printf '%s\n' "$*" >> invocations.log
      turn="turn-$(wc -l < invocations.log | tr -d ' ')"
      if printf '%s' "$prompt" | grep -q '\\[BLOCK_NEW\\]' && [ "${2:-}" != "resume" ]; then
        : > initial-started
        while [ ! -f release-initial ]; do sleep 0.01; done
      fi
      if printf '%s' "$prompt" | grep -q '\\[FAIL_RESUME\\]' && [ "${2:-}" = "resume" ]; then
        : > resume-failure-started
        while [ ! -f release-resume-failure ]; do sleep 0.01; done
        printf '{"type":"turn.started","turn_id":"%s"}\n' "$turn"
        printf '{"type":"turn.failed","turn_id":"%s"}\n' "$turn"
        exit 1
      fi
      printf '{"type":"turn.started","turn_id":"%s"}\n' "$turn"
      if [ "${2:-}" != "resume" ]; then printf '{"type":"thread.started","thread_id":"T1"}\n'; fi
      printf '{"type":"item.completed","item":{"id":"msg-%s","type":"agent_message","text":"answer-%s"}}\n' "$turn" "$turn"
      printf '{"type":"turn.completed","turn_id":"%s"}\n' "$turn"
      """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  static func waitForMarker(_ marker: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: marker.path) {
      guard clock.now < deadline else {
        throw Gate0ETestFailure(
          description: "controlled child did not publish \(marker.lastPathComponent)")
      }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  static func waitForOperationCount(_ count: Int, in store: DurableModelStore) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if try store.load().operations.count >= count { return }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(5))
    }
    throw Gate0ETestFailure(description: "queued operation was not durably prepared")
  }

  static func testConcurrentInitialSendsResumeExactThread() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("controlled-codex")
    try controlledExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let runtimeRegistry = PaperChatRuntimeRegistry()
    let coordinatorA = PaperChatCoordinator(
      store: store, paths: paths, executableURL: fake, runtimeRegistry: runtimeRegistry)
    let coordinatorB = PaperChatCoordinator(
      store: store, paths: paths, executableURL: fake, runtimeRegistry: runtimeRegistry)
    let first = Task { try await coordinatorA.send(paperID: paper.id, text: "[BLOCK_NEW] first") }
    let workspace = try await waitForInvocation(store: store, paths: paths, paperID: paper.id)
    try await waitForMarker(workspace.appendingPathComponent("initial-started"))
    let second = Task { try await coordinatorB.send(paperID: paper.id, text: "second") }
    try await waitForOperationCount(2, in: durable)
    try Data().write(to: workspace.appendingPathComponent("release-initial"))
    let firstResult = try await first.value
    let secondResult = try await second.value
    try expect(firstResult.outcome == .turnCompleted, "initial controlled turn failed")
    try expect(secondResult.outcome == .turnCompleted, "queued initial-session turn failed")
    let invocations = try String(
      contentsOf: workspace.appendingPathComponent("invocations.log"), encoding: .utf8
    )
    .split(separator: "\n").map(String.init)
    try expect(
      invocations.count == 2, "concurrent initial sends did not produce exactly two children")
    for operation in try durable.load().operations {
      let journal = try paths.url(forRelativePath: operation.journalRelativePath)
      try expect(
        !journal.path.hasPrefix(workspace.path + "/"),
        "authoritative journal was placed inside the child-writable agent cwd")
      try expect(
        journal.deletingLastPathComponent()
          == workspace.deletingLastPathComponent().appendingPathComponent("operations"),
        "journal did not use the private sibling operations root")
    }
    try expect(!invocations[0].contains(" resume "), "first initial send unexpectedly resumed")
    try expect(
      invocations[1].contains(
        "exec resume --config sandbox_mode=\"workspace-write\" --config sandbox_workspace_write.writable_roots=[\"")
        && invocations[1].contains(
          "\"] --ignore-user-config --json --skip-git-repo-check T1 -"),
      "second send did not resume exact committed T1")
  }

  static func testResumeFailureDoesNotDuplicateQueuedPrompt() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("controlled-codex")
    try controlledExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    _ = try await coordinator.send(paperID: paper.id, text: "seed")
    let predecessor = try store.currentSession(paperID: paper.id)!
    let predecessorWorkspace = try paths.url(forRelativePath: predecessor.workspaceRelativePath)
    let failing = Task { try await coordinator.send(paperID: paper.id, text: "[FAIL_RESUME]") }
    try await waitForMarker(predecessorWorkspace.appendingPathComponent("resume-failure-started"))
    let waiter = Task { try await coordinator.send(paperID: paper.id, text: "predecessor waiter") }
    try await waitForOperationCount(3, in: durable)
    try Data().write(to: predecessorWorkspace.appendingPathComponent("release-resume-failure"))
    let failed = try await failing.value
    try expect(
      failed.outcome == .failed && failed.replacementSessionID == nil,
      "resume failure automatically resubmitted the failed prompt")
    let waited = try await waiter.value
    try expect(waited.outcome == .turnCompleted, "distinct queued prompt did not resume afterward")
    let invocations = try String(
      contentsOf: predecessorWorkspace.appendingPathComponent("invocations.log"), encoding: .utf8
    )
    .split(separator: "\n")
    try expect(
      invocations.count == 3,
      "resume failure launched an extra child beyond seed, failed prompt, and queued prompt")
    let current = try store.currentSession(paperID: paper.id)!
    try expect(
      current.id == predecessor.id && current.predecessorSessionID == nil,
      "resume failure replaced the current session without an explicit action")
  }

  static func testFailedResumePersistsWithoutReplacement() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("controlled-codex")
    try controlledExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    _ = try await coordinator.send(paperID: paper.id, text: "seed")
    let predecessor = try store.currentSession(paperID: paper.id)!
    let workspace = try paths.url(forRelativePath: predecessor.workspaceRelativePath)
    let failing = Task { try await coordinator.send(paperID: paper.id, text: "[FAIL_RESUME]") }
    try await waitForMarker(workspace.appendingPathComponent("resume-failure-started"))
    try Data().write(to: workspace.appendingPathComponent("release-resume-failure"))
    let result = try await failing.value
    try expect(
      result.outcome == .failed && result.replacementSessionID == nil,
      "failed resume was hidden by automatic replacement")
    let snapshot = try durable.load()
    let failed = snapshot.operations.last { $0.sessionID == predecessor.id }!
    try expect(
      failed.processOutcomeRawValue == ProcessOutcome.failed.rawValue,
      "cleanup overwrote persisted failed resume")
    try expect(
      snapshot.messages.filter { $0.operationID == failed.id }.allSatisfy {
        $0.deliveryStateRawValue == ProcessOutcome.failed.rawValue
      }, "cleanup overwrote failed resume message state")
    try expect(
      snapshot.papers.first { $0.id == paper.id }?.currentChatSessionID == predecessor.id,
      "failed resume changed the current session before explicit retry")
  }

  static func testAmbiguousResumeFailureRequiresExplicitRetry() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    _ = try await coordinator.send(paperID: paper.id, text: "seed")
    let session = try store.currentSession(paperID: paper.id)!
    let workspace = try paths.url(forRelativePath: session.workspaceRelativePath)
    try Data().write(to: workspace.appendingPathComponent("fail-resume"))

    let failed = try await coordinator.send(paperID: paper.id, text: "ambiguous prompt")

    try expect(failed.outcome == .failed, "ambiguous resume failure was hidden by a resend")
    try expect(
      failed.replacementSessionID == nil,
      "ambiguous resume failure automatically replaced the session")
    try expect(
      try store.currentSession(paperID: paper.id)?.id == session.id,
      "ambiguous resume failure changed the current session before explicit retry")
    let invocations = try String(
      contentsOf: workspace.appendingPathComponent("invocations.log"), encoding: .utf8
    ).split(separator: "\n")
    try expect(
      invocations.count == 2,
      "ambiguous resume failure launched another child for the same prompt")
  }

  static func waitForInvocation(
    store: PortablePaperChatStore, paths: LibraryPaths, paperID: UUID,
    minimumLines: Int = 1
  ) async throws -> URL {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if let session = try store.currentSession(paperID: paperID) {
        let workspace = try paths.url(forRelativePath: session.workspaceRelativePath)
        let log = workspace.appendingPathComponent("invocations.log")
        if let text = try? String(contentsOf: log, encoding: .utf8),
          text.split(separator: "\n").count >= minimumLines
        {
          return workspace
        }
      }
      await Task.yield()
      try await Task.sleep(for: .milliseconds(5))
    }
    throw Gate0ETestFailure(description: "fake child did not start in time")
  }

  static func testQueuedInvalidation() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    let running = Task { try await coordinator.send(paperID: paper.id, text: "[SLOW] first") }
    let oldWorkspace = try await waitForInvocation(store: store, paths: paths, paperID: paper.id)
    let old = try store.currentSession(paperID: paper.id)!
    let waiter = Task { try await coordinator.send(paperID: paper.id, text: "must-not-launch") }
    try await Task.sleep(for: .milliseconds(100))
    let successorID = UUID()
    let successorWorkspace = paths.chatWorkspace(successorID, paperID: paper.id)
    try FileManager.default.createDirectory(
      at: successorWorkspace, withIntermediateDirectories: true)
    _ = try store.commitReplacement(
      paperID: paper.id, predecessorSessionID: old.id, successorSessionID: successorID,
      workspaceRelativePath: paths.relativePath(for: successorWorkspace), reason: "race fixture")
    await coordinator.cancelCurrent(paperID: paper.id)
    do {
      _ = try await running.value
      throw Gate0ETestFailure(description: "invalidated running result was accepted")
    } catch is ChatStoreError {}
    do {
      _ = try await waiter.value
      throw Gate0ETestFailure(description: "invalidated waiter launched")
    } catch is ChatStoreError {}
    let invocations = try String(
      contentsOf: oldWorkspace.appendingPathComponent("invocations.log"), encoding: .utf8)
    try expect(
      invocations.split(separator: "\n").count == 1, "queued invalidated operation launched a child"
    )
    let operations = try durable.load().operations.filter { $0.sessionID == old.id }
    try expect(
      operations.count == 2
        && operations.allSatisfy {
          $0.processOutcomeRawValue == ProcessOutcome.interrupted.rawValue
        }, "invalidated operations are not truthful terminal records")
  }

  static func testCancelWithWaiter() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    try fakeExecutable(at: fake)
    let store = PortablePaperChatStore(store: durable)
    let runtimeRegistry = PaperChatRuntimeRegistry()
    let coordinatorA = PaperChatCoordinator(
      store: store, paths: paths, executableURL: fake, runtimeRegistry: runtimeRegistry)
    let coordinatorB = PaperChatCoordinator(
      store: store, paths: paths, executableURL: fake, runtimeRegistry: runtimeRegistry)
    let running = Task { try await coordinatorA.send(paperID: paper.id, text: "[SLOW] running") }
    let workspace = try await waitForInvocation(store: store, paths: paths, paperID: paper.id)
    let waiter = Task { try await coordinatorB.send(paperID: paper.id, text: "waiter") }
    try await Task.sleep(for: .milliseconds(100))
    await coordinatorB.cancelCurrent(paperID: paper.id)
    let cancelled = try await running.value
    let completed = try await waiter.value
    try expect(cancelled.outcome == .cancelled, "cancel did not target running child")
    try expect(completed.outcome == .turnCompleted, "waiter was cancelled or lost")
    let prompts = try String(
      contentsOf: workspace.appendingPathComponent("prompts.log"), encoding: .utf8)
    try expect(
      prompts.range(of: "[SLOW] running")!.lowerBound < prompts.range(of: "waiter")!.lowerBound,
      "waiter executed before running child")
  }

  static func testRuntimeRegistryPaperIsolation() async throws {
    let registry = PaperChatRuntimeRegistry()
    let sessionID = UUID()
    let keyA = ChatQueueKey(
      sessionID: sessionID, workspaceURL: URL(fileURLWithPath: "/tmp/paper-a"))
    let keyB = ChatQueueKey(
      sessionID: sessionID, workspaceURL: URL(fileURLWithPath: "/tmp/paper-b"))
    let tokenA = CodexCancellationToken()
    let tokenB = CodexCancellationToken()
    let markerA = StartMarker()
    let markerB = StartMarker()
    let taskA = Task {
      try await registry.run(key: keyA, operationID: UUID(), cancellation: tokenA) {
        await markerA.mark()
        while !tokenA.isCancellationRequested { try await Task.sleep(for: .milliseconds(5)) }
      }
    }
    let taskB = Task {
      try await registry.run(key: keyB, operationID: UUID(), cancellation: tokenB) {
        await markerB.mark()
        while !tokenB.isCancellationRequested { try await Task.sleep(for: .milliseconds(5)) }
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while true {
      let startedA = await markerA.value()
      let startedB = await markerB.value()
      if startedA && startedB { break }
      guard ContinuousClock.now < deadline else {
        throw Gate0ETestFailure(description: "distinct paper runtimes did not start")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    await registry.cancelCurrent(key: keyA)
    try await taskA.value
    try expect(!tokenB.isCancellationRequested, "paper A cancellation leaked into paper B")
    await registry.cancelCurrent(key: keyB)
    try await taskB.value
  }

  static func testCrossPaperReviewRejection() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    var snapshot = try durable.load()
    let other = Paper(
      canonicalTitle: "Other", safeBasename: "other", sourceRelativePath: paper.sourceRelativePath,
      sourceSHA256: paper.sourceSHA256)
    let versionID = UUID()
    let generationID = UUID()
    let review = paths.reviewVersion(versionID, generationID: generationID, paperID: other.id)
    try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
    try Data("<html>other</html>".utf8).write(to: review.appendingPathComponent("index.html"))
    var generation = ReviewGeneration(
      id: generationID, paperID: paper.id, sessionID: UUID(), workspaceRelativePath: "x")
    generation.reviewVersionID = versionID
    generation.reviewRelativePath = try paths.relativePath(for: review)
    generation.processOutcomeRawValue = ProcessOutcome.turnCompleted.rawValue
    generation.structuralValidationRawValue = StructuralValidationState.passed.rawValue
    snapshot.papers[0].selectedReviewVersionID = versionID
    snapshot.papers.append(other)
    snapshot.generations.append(generation)
    try durable.save(snapshot)
    let coordinator = PaperChatCoordinator(
      store: PortablePaperChatStore(store: durable), paths: paths,
      executableURL: URL(fileURLWithPath: "/usr/bin/true"))
    do {
      _ = try await coordinator.send(paperID: paper.id, text: "must reject")
      throw Gate0ETestFailure(description: "cross-paper review staged")
    } catch ChatStoreError.crossPaperReference {}
    try expect(
      try durable.load().papers.first { $0.id == paper.id }?.currentChatSessionID == nil,
      "cross-paper rejection mutated current pointer")
  }

  static func testFakeEndToEnd() async throws {
    let (support, paths, durable, paper) = try fixture()
    defer { try? FileManager.default.removeItem(at: support) }
    let fake = support.appendingPathComponent("fake-codex")
    let script = """
      #!/bin/sh
      set -eu
      prompt=$(cat)
      printf '%s\\n' "$*" >> invocations.log
      printf '%s' "$prompt" > last-prompt.txt
      if printf '%s' "$prompt" | grep -q '\\[SLOW\\]'; then
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        printf "%s" "$!" > descendant.pid
        trap 'exit 143' TERM
        wait
      fi
      turn="turn-$(wc -l < invocations.log | tr -d ' ')"
      printf '{"type":"turn.started","turn_id":"%s"}\\n' "$turn"
      if [ -f fail-resume ] && [ "${2:-}" = "resume" ]; then rm fail-resume; printf '{"type":"turn.failed","turn_id":"%s"}\\n' "$turn"; exit 1; fi
      if [ "${2:-}" != "resume" ]; then printf '{"type":"thread.started","thread_id":"thread-%s"}\\n' "$turn"; fi
      printf '{"type":"item.completed","item":{"id":"msg-%s","type":"agent_message","text":"answer-%s"}}\\n' "$turn" "$turn"
      printf '{"type":"turn.completed","turn_id":"%s"}\\n' "$turn"
      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    let store = PortablePaperChatStore(store: durable)
    let coordinator = PaperChatCoordinator(store: store, paths: paths, executableURL: fake)
    let first = try await coordinator.send(paperID: paper.id, text: "first")
    try expect(first.outcome == .turnCompleted, "new turn failed")
    let firstSession = try store.currentSession(paperID: paper.id)!
    try expect(firstSession.externalThreadID?.hasPrefix("thread-") == true, "thread not bound")
    let second = try await coordinator.send(paperID: paper.id, text: "second")
    try expect(second.outcome == .turnCompleted, "resume failed")
    let firstWorkspace = try paths.url(forRelativePath: firstSession.workspaceRelativePath)
    let invocationLog = try String(
      contentsOf: firstWorkspace.appendingPathComponent("invocations.log"), encoding: .utf8)
    try expect(
      invocationLog.contains("exec --ignore-user-config --json")
        && invocationLog.contains(
          "exec resume --config sandbox_mode=\"workspace-write\" --config sandbox_workspace_write.writable_roots=[\"")
        && invocationLog.contains(
          "\"] --ignore-user-config --json --skip-git-repo-check \(firstSession.externalThreadID!) -"),
      "exact new/resume arguments absent")
    try Data().write(to: firstWorkspace.appendingPathComponent("fail-resume"))
    let failedResume = try await coordinator.send(paperID: paper.id, text: "replacement")
    try expect(
      failedResume.replacementSessionID == nil && failedResume.outcome == .failed,
      "resume failure automatically resubmitted the same prompt")
    let afterFailure = try store.currentSession(paperID: paper.id)!
    try expect(
      afterFailure.id == firstSession.id,
      "resume failure replaced the session before an explicit retry")
    let explicitRetry = try await coordinator.retry(
      paperID: paper.id, failedOperationID: failedResume.operationID, text: "replacement")
    try expect(explicitRetry.outcome == .turnCompleted, "explicit retry did not complete")
    let slow = Task { try await coordinator.send(paperID: paper.id, text: "[SLOW]") }
    try await Task.sleep(for: .milliseconds(200))
    await coordinator.cancelCurrent(paperID: paper.id)
    let cancelled = try await slow.value
    try expect(cancelled.outcome == .cancelled, "cancellation was not reconciled")
    let descendantPID = Int32(
      try String(
        contentsOf: paths.url(forRelativePath: firstSession.workspaceRelativePath)
          .appendingPathComponent("descendant.pid"), encoding: .utf8))!
    let descendantDeadline = ContinuousClock().now.advanced(by: .seconds(2))
    while processIsRunning(descendantPID) && ContinuousClock().now < descendantDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try expect(
      !processIsRunning(descendantPID),
      "cancelled Codex process left its TERM-ignoring descendant alive")
    let failedOperation = try durable.load().operations.last {
      $0.processOutcomeRawValue == ProcessOutcome.cancelled.rawValue
    }!.id
    let retried = try await coordinator.retry(
      paperID: paper.id, failedOperationID: failedOperation, text: "retry")
    try expect(retried.outcome == .turnCompleted, "explicit retry failed")
    let reopened = PortablePaperChatStore(store: try ModelContainerFactory.make(at: paths.storeURL))
    let restored = try reopened.messages(paperID: paper.id)
    try expect(
      restored.contains(where: { $0.content == "first" })
        && restored.contains(where: { $0.content == "retry" }), "app-owned restoration lost turns")
    try expect(!restored.contains(where: { $0.paperID != paper.id }), "cross-paper message leakage")
  }

  static func processIsRunning(_ pid: Int32) -> Bool {
    errno = 0
    if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
      return info.pbi_status != 5
    }
    return true
  }
}

private enum InjectedPaperChatStoreFailure: Error { case applyTransportResult }

private final class FailingApplyPaperChatStore: PaperChatStore, @unchecked Sendable {
  private let underlying: PortablePaperChatStore

  init(underlying: PortablePaperChatStore) { self.underlying = underlying }

  func paper(id: UUID) throws -> PaperChatRecord { try underlying.paper(id: id) }
  func currentSession(paperID: UUID) throws -> ChatSessionRecord? {
    try underlying.currentSession(paperID: paperID)
  }
  func assertCurrentSession(
    paperID: UUID, sessionID: UUID, externalThreadID: String?
  ) throws {
    try underlying.assertCurrentSession(
      paperID: paperID, sessionID: sessionID, externalThreadID: externalThreadID)
  }
  func selectedReviewContext(paperID: UUID) throws -> SelectedReviewChatContext? {
    try underlying.selectedReviewContext(paperID: paperID)
  }
  func messages(paperID: UUID) throws -> [ChatMessageRecord] {
    try underlying.messages(paperID: paperID)
  }
  func predecessorTranscript(sessionID: UUID) throws -> [TranscriptMessage] {
    try underlying.predecessorTranscript(sessionID: sessionID)
  }
  func createInitialSession(
    paperID: UUID, sessionID: UUID, workspaceRelativePath: String
  ) throws -> ChatSessionRecord {
    try underlying.createInitialSession(
      paperID: paperID, sessionID: sessionID, workspaceRelativePath: workspaceRelativePath)
  }
  func commitReplacement(
    paperID: UUID, predecessorSessionID: UUID, successorSessionID: UUID,
    workspaceRelativePath: String, reason: String
  ) throws -> ChatSessionRecord {
    try underlying.commitReplacement(
      paperID: paperID, predecessorSessionID: predecessorSessionID,
      successorSessionID: successorSessionID, workspaceRelativePath: workspaceRelativePath,
      reason: reason)
  }
  func prepareTurn(
    paperID: UUID, sessionID: UUID, prompt: String, operationID: UUID,
    userMessageID: UUID, journalRelativePath: String, retryPredecessorID: UUID?
  ) throws -> PreparedChatTurn {
    try underlying.prepareTurn(
      paperID: paperID, sessionID: sessionID, prompt: prompt, operationID: operationID,
      userMessageID: userMessageID, journalRelativePath: journalRelativePath,
      retryPredecessorID: retryPredecessorID)
  }
  func applyTransportResult(operationID: UUID, result: CodexTransportResult) throws {
    throw InjectedPaperChatStoreFailure.applyTransportResult
  }
  func recordOperationFailure(operationID: UUID, outcome: ProcessOutcome) throws {
    try underlying.recordOperationFailure(operationID: operationID, outcome: outcome)
  }
}
