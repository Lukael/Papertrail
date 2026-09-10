import CryptoKit
import Foundation
import PapertrailCore

struct Failure: Error, CustomStringConvertible { let description: String }
final class LockedResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<ReviewGenerationResult, Error>?
  func set(_ result: Result<ReviewGenerationResult, Error>) { lock.withLock { value = result } }
  func get() -> Result<ReviewGenerationResult, Error>? { lock.withLock { value } }
}
final class LockedIntBox: @unchecked Sendable {
  private let lock = NSLock(); private var value = 0
  func increment() { lock.withLock { value += 1 } }
  func get() -> Int { lock.withLock { value } }
}
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(description: message) }
}

@main enum Gate0FTests {
  static var fm: FileManager { FileManager.default }

  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("manual document snapshots include only completed paper chat", testConversationSnapshot),
      ("document synthesis validates chat references and immutable inputs", testConversationGeneration),
      ("production prompt is bounded and distrusts document instructions", testPrompt),
      ("structured review is strict evidence-linked and rendered deterministically", testStructuredReview),
      ("successful direct transport promotes and selects immutable review", testSuccess),
      ("regeneration preserves prior version bytes and lineage", testRegeneration),
      ("failed process and invalid structure never replace selected review", testFailures),
      ("cancelled generation preserves prior selection", testCancellation),
      ("cross-paper predecessor and path confusion fail closed", testCrossPaper),
      ("legacy automatic request records remain readable without app dispatch", testAutomaticTrigger),
      ("state transition matrices reject every invalid edge", testStateTransitions),
      ("staged inputs are readonly and mutation is quarantined", testStagedMutation),
      ("canonical containment rejects cross-paper and operation result symlinks", testCanonicalContainment),
      ("post-transport cancellation cannot promote", testPostTransportCancellation),
      ("promotion crash points reconcile without overwriting selection", testPromotionCrashRecovery),
      ("running generation reconciliation is truthful", testReconciliation),
      ("SwiftData and app UI source paths are wired", testSourceContracts),
    ]
    var passed = 0
    for (name, test) in tests {
      do { try test(); passed += 1; print("PASS \(name)") }
      catch { print("FAIL \(name): \(error)"); exit(1) }
    }
    print("PASS Gate0FTests \(passed)/\(tests.count)")
  }

  static func testConversationSnapshot() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let chatID = UUID(), reviewID = UUID(), cutoff = Date()
    func message(_ session: UUID, _ role: String, _ state: String, _ text: String,
                 _ date: Date = .distantPast) -> ChatMessage {
      ChatMessage(paperID: fixture.paperID, sessionID: session, role: role,
                  committedContent: text, deliveryState: state, createdAt: date)
    }
    try fixture.durable.transaction { state in
      state.sessions += [
        CodexSession(id: chatID, paperID: fixture.paperID, purpose: .paperChat, workspaceRelativePath: "chat"),
        CodexSession(id: reviewID, paperID: fixture.paperID, purpose: .reviewGeneration, workspaceRelativePath: "review")]
      state.messages += [message(chatID, "user", "committed", "Earlier question"),
        message(chatID, "assistant", "committed", "Completed answer"),
        message(chatID, "assistant", "draft", "Incomplete answer"),
        message(chatID, "user", "queued", "Pending question"),
        message(chatID, "user", "failed", "Failed question"),
        message(chatID, "system", "committed", "Internal message"),
        message(reviewID, "assistant", "committed", "Previous review output"),
        message(chatID, "user", "committed", "Future message", cutoff.addingTimeInterval(3600))]
    }
    try fixture.durable.transaction { state in
      for outcome in [ProcessOutcome.failed, .protocolFailure, .running, .turnCompleted] {
        var operation = CodexOperation(sessionID: chatID, kind: "chatTurn", promptSHA256: "fixture",
          journalRelativePath: "journal")
        operation.processOutcomeRawValue = outcome.rawValue
        state.operations.append(operation)
        state.messages.append(ChatMessage(paperID: fixture.paperID, sessionID: chatID,
          operationID: operation.id, role: "assistant", committedContent: outcome == .turnCompleted ? "Successful turn item" : "Incomplete turn item",
          deliveryState: "committed", createdAt: .distantPast))
      }
    }
    let snapshot = try ReviewConversationSnapshot.capture(paperID: fixture.paperID, store: fixture.durable)
    try expect(Set(snapshot.messages.map(\.content)) == ["Earlier question", "Completed answer", "Successful turn item"],
      "snapshot included unfinished, future, system, or generation messages")
    try fixture.durable.transaction { state in
      state.messages.append(message(chatID, "user", "committed", "Later question"))
    }
    let next = try ReviewConversationSnapshot.capture(paperID: fixture.paperID, store: fixture.durable)
    try expect(snapshot.messages.count == 3 && next.messages.count == 4, "snapshot changed after capture")
    let empty = ReviewConversationSnapshot(paperID: fixture.paperID)
    try expect(empty.messages.isEmpty, "no-chat document has invented context")
  }

  static func testConversationGeneration() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let session = UUID(), messageID = UUID()
    let conversation = ReviewConversationSnapshot(paperID: fixture.paperID, records: [
      ChatMessageRecord(id: messageID, paperID: fixture.paperID, sessionID: session,
        operationID: nil, role: "user", content: "Could sensor noise change this result?",
        draft: nil, deliveryState: "committed", createdAt: .distantPast)
    ], paperChatSessionIDs: [session])
    var json = try JSONSerialization.jsonObject(with: Data(canonicalReviewJSON().utf8)) as! [String: Any]
    json["discussion"] = [["kind": "openQuestion", "text": "센서 잡음에 따른 결과 변화는 추가 검증이 필요하다.",
      "messageIDs": [messageID.uuidString.lowercased()]]]
    let executable = fixture.root.appendingPathComponent("fake-discussion")
    let body = script(outputReviewJSON: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    try Data(body.utf8).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let identity = ReviewGenerationIdentity()
    let result = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable,
      identity: identity, conversation: conversation)
    try expect(result.versionID != nil && result.selected, "paper plus discussion was not promoted")
    let workspace = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID)
    let stagedConversation = try Data(contentsOf: workspace.appendingPathComponent("input/conversation.json"))
    let capturedConversation = try conversation.encoded()
    try expect(stagedConversation == capturedConversation,
      "generation did not preserve clicked conversation")
    let doc = try ReviewDocumentDecoder().decode(try JSONSerialization.data(withJSONObject: json))
    let html = ReviewHTMLRenderer().render(document: doc)
    try expect(html.contains("대화에서 정리한 내용") && html.contains("미해결 질문"),
      "discussion is not separately rendered")
    try Data(html.utf8).write(to: URL(fileURLWithPath: ".build/manual-document-preview.html"))
    let paper = try fixture.durable.load().papers[0]
    let text = try PDFExtractedTextCache(paths: fixture.paths).resolve(paperID: paper.id,
      sourceURL: fixture.paths.url(forRelativePath: paper.sourceRelativePath), expectedSourceSHA256: paper.sourceSHA256)
    let pages = try text.readPages()
    try expect(!ReviewDocumentValidator().validate(doc, pageTexts: pages, conversationMessageIDs: []).passed,
      "invented conversation reference passed")
    let legacy = try ReviewDocumentDecoder().decode(Data(canonicalReviewJSON().utf8))
    try expect(!ReviewDocumentValidator().validate(legacy, pageTexts: pages,
      conversationMessageIDs: [messageID.uuidString.lowercased()]).passed, "chat was silently ignored")
    let mutation = ReviewGenerationIdentity()
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable,
        identity: mutation, conversation: conversation, hooks: .init(afterTransport: {
          let path = fixture.paths.generationWorkspace(mutation.generationID, paperID: fixture.paperID)
            .appendingPathComponent("input/conversation.json")
          try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
          try? Data("{}".utf8).write(to: path)
        }))
      throw Failure(description: "mutated conversation was promoted")
    } catch ReviewGenerationServiceError.stagedInputMutation {}
  }

  static func testPrompt() throws {
    let prompt = ReviewPromptBuilder().productionPrompt()
    try expect(prompt.utf8.count <= ReviewPromptBuilder.maximumPromptBytes, "prompt exceeds bound")
    for phrase in [
      "page-delimited paper text", "untrusted research data", "Work only inside",
      "output/operations/current/review.json", "schemaVersion=1",
      "evidenceIDs", "exactExcerpt", "strongestSupportedConclusion",
      "summary:evidence-linked statement", "researchProblem:evidence-linked statement",
      "contributions:[evidence-linked statement]", "overview:evidence-linked statement",
      "pipeline:[method step]", "assumptions:[evidence-linked statement]",
      "strongestSupportedConclusion:evidence-linked statement", "followUpQuestions:[string]",
      "questions are plain strings", "evidence:[evidence item]",
      "pageIndex:integer", "printedLocator:string or null", "supports:[string]",
      "condition:string", "metric:string", "result:string", "note:string",
      "affectedClaim:string", "resolvingCheck:string",
      "Evidence supports must not reference follow-up questions", "notReported",
      "concise, specific analysis",
    ] {
      try expect(prompt.contains(phrase), "prompt lacks \(phrase)")
    }
    for forbidden in [
      "output/index.html", "output/assets", "render/pages", "crop", "at least 5000",
      "image assets", "evidence-report.json",
    ] {
      try expect(
        !prompt.lowercased().contains(forbidden.lowercased()),
        "production prompt retains obsolete generation instruction: \(forbidden)")
    }
    let synthesisPrompt = ReviewPromptBuilder().productionPrompt(conversationPath: "input/conversation.json")
    try expect(synthesisPrompt.contains("input/conversation.json") && synthesisPrompt.contains("messageIDs"),
      "prompt does not consume the captured conversation")
    let css = "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(ReviewResourceSanitizer.contentSecurityPolicy)\"><style>@media(max-width:850px){.a{display:block}}</style><p id=\"r1\">x<a href=\"#fn1\">1</a></p><section id=\"fn1\"><blockquote lang=\"en\">Exact evidence.</blockquote><a href=\"#r1\">back</a></section>"
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let ordinaryCSSReport = try ReviewValidator().validate(reviewDirectory: directory, html: css)
    try expect(
      ordinaryCSSReport.passed,
      "ordinary adjacent CSS braces were misclassified as a placeholder")
    for placeholder in ["{{}}", "{{TITLE}}", "{{\nMULTILINE\n}}"] {
      let candidate = css.replacingOccurrences(of: "Exact evidence.", with: placeholder)
      let report = try ReviewValidator().validate(reviewDirectory: directory, html: candidate)
      try expect(report.findings.contains { $0.code == "placeholder" }, "unresolved placeholder form was accepted: \(placeholder)")
    }
  }

  static func testStructuredReview() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let paper = try fixture.durable.load().papers[0]
    let source = try fixture.paths.url(forRelativePath: paper.sourceRelativePath)
    let cache = PDFExtractedTextCache(paths: fixture.paths)
    let first = try cache.resolve(
      paperID: paper.id, sourceURL: source, expectedSourceSHA256: paper.sourceSHA256)
    let second = try cache.resolve(
      paperID: paper.id, sourceURL: source, expectedSourceSHA256: paper.sourceSHA256)
    try expect(first == second, "matching source identity rebuilt extracted text")

    let data = Data(canonicalReviewJSON().utf8)
    let document = try ReviewDocumentDecoder().decode(data)
    let report = ReviewDocumentValidator().validate(document, pageTexts: try first.readPages())
    try expect(report.passed, "canonical structured review failed: \(report.findings)")
    let firstHTML = ReviewHTMLRenderer().render(document: document)
    let secondHTML = ReviewHTMLRenderer().render(document: document)
    try expect(firstHTML == secondHTML, "app-owned rendering is nondeterministic")
    try expect(!firstHTML.contains("<img"), "renderer emitted an image")

    let asymmetric = canonicalReviewJSON().replacingOccurrences(
      of: #""supports":["experiment_result","conclusion"]"#,
      with: #""supports":["experiment_result"]"#)
    let asymmetricDocument = try ReviewDocumentDecoder().decode(Data(asymmetric.utf8))
    let asymmetricReport = ReviewDocumentValidator().validate(
      asymmetricDocument, pageTexts: try first.readPages())
    try expect(
      asymmetricReport.findings.contains { $0.code == "reference-mismatch" },
      "one-way evidence link passed semantic validation")

    let unknownKey = canonicalReviewJSON().replacingOccurrences(
      of: #""schemaVersion": 1"#, with: #""schemaVersion": 1, "unexpected": true"#)
    do {
      _ = try ReviewDocumentDecoder().decode(Data(unknownKey.utf8))
      throw Failure(description: "unknown structured-review key was accepted")
    } catch is ReviewDocumentDecodingError {}
  }

  static func testSuccess() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake-codex")
    try fakeExecutable(executable, mode: "success")
    let identity = ReviewGenerationIdentity(
      generationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
      sessionID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
      operationID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
      versionID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!)
    let result = try fixture.service.generate(
      paperID: fixture.paperID, executableURL: executable, identity: identity,
      metadata: .unavailable(reason: "offline test"))
    try expect(result.label == "Generated · structure checked", "quality label overclaimed")
    try expect(result.evidenceReportState == .missing && result.selected, "evidence/select state wrong")
    let records = try fixture.reviewStore.generations(paperID: fixture.paperID)
    try expect(records.count == 1 && records[0].isSelectable, "promoted generation not selectable")
    try expect(records[0].qualityVerification == .notPerformed, "human quality was invented")
    let snapshot = try fixture.durable.load()
    try expect(snapshot.papers[0].selectedReviewVersionID == identity.versionID, "paper selection missing")
    try expect(snapshot.sessions[0].purpose == .reviewGeneration, "review did not create an isolated review session")
    try expect(
      snapshot.papers[0].currentChatSessionID == nil,
      "review generation incorrectly replaced the current paper chat")
    try expect(snapshot.sessions[0].lifecycle == .active, "review session did not remain active")
    try expect(snapshot.sessions[0].externalThreadID == "thread-review", "thread not bound")
    let reviewMessages = snapshot.messages.filter { $0.operationID == identity.operationID }
    try expect(reviewMessages.count == 2, "review turn was not projected into chat")
    try expect(
      reviewMessages.first(where: { $0.roleRawValue == "user" })?.committedContent
        .contains("Generate a Papertrail document for “Paper”") == true,
      "review request context is missing from chat")
    try expect(
      reviewMessages.first(where: { $0.roleRawValue == "user" })?.committedContent
        != ReviewPromptBuilder().productionPrompt(),
      "private production prompt was duplicated into chat")
    try expect(
      reviewMessages.first(where: { $0.roleRawValue == "assistant" })?.committedContent
        == "generated",
      "review result is missing from chat")
    try expect(
      reviewMessages.allSatisfy {
        $0.sessionID == identity.sessionID && $0.deliveryStateRawValue == "committed"
      },
      "review audit messages are not committed to the isolated session")
    let reviewSessionWorkspace = try fixture.paths.url(
      forRelativePath: snapshot.sessions[0].workspaceRelativePath)
    try expect(
      reviewSessionWorkspace.standardizedFileURL.path
        == fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID)
          .standardizedFileURL.path,
      "review session did not retain its isolated generation workspace: \(reviewSessionWorkspace.path) != \(fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID).path)")
    let version = fixture.paths.reviewVersion(identity.versionID, generationID: identity.generationID, paperID: fixture.paperID)
    let html = try String(contentsOf: version.appendingPathComponent("index.html"), encoding: .utf8)
    try expect(!html.contains("<img") && !html.contains("<script"), "renderer emitted forbidden content")
    try expect(html.contains("Content-Security-Policy"), "CSP missing")
    try expect(html.contains("PAPERTRAIL · STRUCTURED REVIEW"), "app-owned renderer was not used")
    let attrs = try fm.attributesOfItem(atPath: version.appendingPathComponent("index.html").path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(perms & 0o222 == 0, "promoted review remains writable")
    let workspace = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID)
    try expect(workspace.path.hasSuffix("/workspace/agent"), "child cwd is not scoped to agent")
    try expect(
      workspace.standardizedFileURL.path == reviewSessionWorkspace.standardizedFileURL.path,
      "review session does not own its generation workspace")
    var outputIsDirectory: ObjCBool = false
    try expect(
      fm.fileExists(
        atPath: workspace.appendingPathComponent(
          "output/operations/\(identity.operationID.uuidString.lowercased())").path,
        isDirectory: &outputIsDirectory) && outputIsDirectory.boolValue,
      "operation-owned output destination was not staged before Codex launch")
    let operationReview = workspace.appendingPathComponent(
      "output/operations/\(identity.operationID.uuidString.lowercased())/review.json")
    try expect(
      fm.fileExists(atPath: operationReview.path),
      "operation-owned structured review was not preserved")
    _ = try ReviewDocumentDecoder().decode(Data(contentsOf: operationReview))
    for artifact in [
      "index.html", "sanitization-report.json", "validation-report.json",
      "evidence-report.json", ReviewPromotionIntegrity.manifestName,
    ] {
      try expect(
        fm.fileExists(atPath: version.appendingPathComponent(artifact).path),
        "app-owned promoted artifact is missing: \(artifact)")
    }
    try expect(
      !fm.fileExists(atPath: workspace.appendingPathComponent("output/index.html").path)
        && !fm.fileExists(
          atPath: workspace.appendingPathComponent("output/evidence-report.json").path),
      "agent output retained obsolete app-owned review artifacts")
    try expect(
      !fm.fileExists(atPath: workspace.appendingPathComponent("output/assets").path)
        && !fm.fileExists(atPath: workspace.appendingPathComponent("render/pages").path)
        && !fm.fileExists(atPath: workspace.appendingPathComponent("source.pdf").path)
        && !fm.fileExists(atPath: workspace.appendingPathComponent("template").path),
      "new generation retained PDF/template/image artifacts")
    let journalDirectory = try fixture.paths.url(
      forRelativePath: snapshot.operations[0].journalRelativePath)
    try expect(
      journalDirectory.deletingLastPathComponent()
        == workspace.deletingLastPathComponent().appendingPathComponent("operations"),
      "review journal is not outside child cwd in the private operations sibling")
    let prompt = try String(contentsOf: workspace.appendingPathComponent("prompt.md"), encoding: .utf8)
    try expect(
      prompt.contains("untrusted research data")
        && prompt.contains("output/operations/\(identity.operationID.uuidString.lowercased())/review.json"),
      "persisted prompt mismatch")
    let invocation = try String(contentsOf: workspace.appendingPathComponent("invocation.txt"), encoding: .utf8)
    try expect(
      invocation.contains(
        "exec --ignore-user-config --json --sandbox workspace-write --skip-git-repo-check -"),
      "direct arguments changed")
    let manifest = try JSONDecoder().decode(ReviewTextStagingManifest.self, from: Data(contentsOf: workspace.appendingPathComponent("staging-manifest.json")))
    try expect(manifest.copiesAreExact, "staged copies not exact")
    try expect(manifest.textOriginalPath != manifest.textCopyPath, "text was not explicitly copied")
    try expect(manifest.sourceSHA256 == snapshot.papers[0].sourceSHA256, "text staging lost source identity")
    let extractedText = try String(
      contentsOf: workspace.appendingPathComponent("input/paper-text.txt"), encoding: .utf8)
    try expect(
      extractedText.contains("===== PDF PAGE 1 =====") && extractedText.contains("===== PDF PAGE 2 ====="),
      "page-delimited PDF text was not staged")
    let extractedMode = (try fm.attributesOfItem(
      atPath: workspace.appendingPathComponent("input/paper-text.txt").path
    )[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(extractedMode & 0o222 == 0, "staged PDF text remains writable")
    let inputMode = (try fm.attributesOfItem(
      atPath: URL(fileURLWithPath: manifest.textCopyPath).deletingLastPathComponent().path
    )[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(inputMode == 0o500, "staged text directory is not read-only")
  }

  static func testRegeneration() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake-codex")
    try fakeExecutable(executable, mode: "success")
    let first = ReviewGenerationIdentity(), second = ReviewGenerationIdentity()
    _ = try fixture.service.generate(
      paperID: fixture.paperID, executableURL: executable, identity: first)
    let firstURL = fixture.paths.reviewVersion(first.versionID, generationID: first.generationID, paperID: fixture.paperID)
      .appendingPathComponent("index.html")
    let firstHash = try FileFingerprint.read(firstURL).sha256
    _ = try fixture.service.generate(
      paperID: fixture.paperID, executableURL: executable, predecessorGenerationID: first.generationID, identity: second)
    let preservedHash = try FileFingerprint.read(firstURL).sha256
    try expect(preservedHash == firstHash, "regeneration changed prior bytes")
    let records = try fixture.reviewStore.generations(paperID: fixture.paperID)
    try expect(records.count == 2, "regeneration did not preserve versions")
    try expect(records.first { $0.id == second.generationID }?.predecessorGenerationID == first.generationID, "lineage missing")
    let snapshot = try fixture.durable.load()
    try expect(snapshot.papers[0].selectedReviewVersionID == second.versionID, "new selection missing")
    try expect(snapshot.sessions.count == 2, "regeneration did not create a separate Codex session")
    try expect(
      Set(snapshot.generations.map(\.sessionID)) == Set(snapshot.sessions.map(\.id)),
      "review generations were not mapped one-to-one to isolated sessions")
    try expect(
      snapshot.messages.count == 4
        && Set(snapshot.messages.map(\.sessionID)) == Set(snapshot.sessions.map(\.id)),
      "regenerated review audit turns were not retained in their isolated sessions")
    let secondWorkspace = fixture.paths.generationWorkspace(
      second.generationID, paperID: fixture.paperID)
    let secondInvocation = try String(
      contentsOf: secondWorkspace.appendingPathComponent("invocation.txt"), encoding: .utf8)
    try expect(
      secondInvocation.contains(
        "exec --ignore-user-config --json --sandbox workspace-write --skip-git-repo-check -"),
      "regeneration did not start an isolated external Codex thread")
  }

  static func testFailures() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let good = fixture.root.appendingPathComponent("good"), failed = fixture.root.appendingPathComponent("failed"), invalid = fixture.root.appendingPathComponent("invalid")
    try fakeExecutable(good, mode: "success"); try fakeExecutable(failed, mode: "failed"); try fakeExecutable(invalid, mode: "invalid")
    let selected = ReviewGenerationIdentity()
    _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: good, identity: selected)
    let selectedURL = fixture.paths.reviewVersion(selected.versionID, generationID: selected.generationID, paperID: fixture.paperID).appendingPathComponent("index.html")
    let hash = try FileFingerprint.read(selectedURL).sha256
    let failedID = ReviewGenerationIdentity()
    let failedResult = try fixture.service.generate(paperID: fixture.paperID, executableURL: failed, predecessorGenerationID: selected.generationID, identity: failedID)
    try expect(failedResult.processOutcome == .failed && failedResult.versionID == nil, "process failure promoted")
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: invalid, predecessorGenerationID: failedID.generationID, identity: ReviewGenerationIdentity())
      throw Failure(description: "invalid structure succeeded")
    } catch is ReviewGenerationServiceError {}
    let snapshot = try fixture.durable.load()
    try expect(snapshot.papers[0].selectedReviewVersionID == selected.versionID, "failure replaced selection")
    let preservedHash = try FileFingerprint.read(selectedURL).sha256
    try expect(preservedHash == hash, "failure mutated selected bytes")
  }

  static func testCrossPaper() throws {
    let fixture = try makeFixture(twoPapers: true); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake")
    try fakeExecutable(executable, mode: "success")
    let first = ReviewGenerationIdentity()
    _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable, identity: first)
    let otherID = try fixture.durable.load().papers[1].id
    do {
      _ = try fixture.service.generate(paperID: otherID, executableURL: executable, predecessorGenerationID: first.generationID, identity: ReviewGenerationIdentity())
      throw Failure(description: "cross-paper predecessor accepted")
    } catch ReviewGenerationStoreError.crossPaperReference {}
  }

  static func testAutomaticTrigger() throws {
    let root = fm.temporaryDirectory.appendingPathComponent("auto-request-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("requests.json"), paperID = UUID()
    let durable = DurableModelStore(storeURL: root.appendingPathComponent("paper.store"))
    var paper = Paper(
      id: paperID, canonicalTitle: "Crash marker", safeBasename: "crash-marker",
      sourceRelativePath: "Papers/\(paperID.uuidString.lowercased())/source/paper.pdf",
      sourceSHA256: "hash")
    paper.automaticReviewRequiredAt = Date()
    var snapshot = DurableSnapshot(); snapshot.papers.append(paper)
    try durable.save(snapshot)

    // Fault injection: the authoritative paper save committed, then the process died
    // before any sidecar request could be enqueued.
    let firstStore = DurableAutomaticReviewRequestStore(url: url)
    let sidecarBeforeRecovery = try firstStore.request(paperID: paperID)
    try expect(sidecarBeforeRecovery == nil, "fault fixture unexpectedly wrote a sidecar")
    let reopenedPaperStore = PortableReviewGenerationStore(
      store: DurableModelStore(storeURL: durable.storeURL))
    let reopenedPaper = try reopenedPaperStore.paper(id: paperID)
    try expect(reopenedPaper.automaticReviewRequired, "authoritative review marker did not survive relaunch")
    let relaunched = DurableAutomaticReviewRequestStore(url: url)
    let first = try relaunched.reconcile(
      paperID: paperID, automaticReviewRequired: reopenedPaper.automaticReviewRequired)!
    let duplicate = try relaunched.reconcile(
      paperID: paperID, automaticReviewRequired: reopenedPaper.automaticReviewRequired)!
    try expect(first.id == duplicate.id, "marker plus sidecar reconstructed a duplicate request")
    let pendingAfterRelaunch = try relaunched.request(paperID: paperID)
    try expect(pendingAfterRelaunch?.state == .pending, "pending request did not survive relaunch")
    // Missing CLI/template prerequisites never call claim, so the durable request remains pending.
    try expect(pendingAfterRelaunch?.attempts == 0, "unavailable prerequisite consumed request")
    let claims = LockedIntBox(), group = DispatchGroup()
    for _ in 0..<20 {
      group.enter()
      DispatchQueue.global().async {
        if (try? DurableAutomaticReviewRequestStore(url: url).claim(paperID: paperID)) != nil {
          claims.increment()
        }
        group.leave()
      }
    }
    group.wait()
    try expect(claims.get() == 1, "reconstructed request did not start exactly once")
    let claimed = try relaunched.request(paperID: paperID)!
    try relaunched.release(requestID: claimed.id, generationID: claimed.generationID!)
    // A manual start claims the same durable work item; an overlapping automatic
    // start observes the claim and cannot create a second generation.
    let retry = try DurableAutomaticReviewRequestStore(url: url).claim(paperID: paperID)!
    let overlappingClaim = try relaunched.claim(paperID: paperID)
    try expect(overlappingClaim == nil, "manual and automatic starts claimed separate work")
    try expect(retry.attempts == 2, "released request was not retryable after relaunch")
    try reopenedPaperStore.markAutomaticReviewCompleted(paperID: paperID)
    try relaunched.complete(requestID: retry.id, generationID: retry.generationID!)
    let completedPaper = try PortableReviewGenerationStore(
      store: DurableModelStore(storeURL: durable.storeURL)).paper(id: paperID)
    try expect(!completedPaper.automaticReviewRequired, "completion did not clear the authoritative requirement")
    _ = try DurableAutomaticReviewRequestStore(url: url).reconcile(
      paperID: paperID, automaticReviewRequired: completedPaper.automaticReviewRequired)
    let afterCompletion = try DurableAutomaticReviewRequestStore(url: url).request(paperID: paperID)
    try expect(afterCompletion == nil, "completed request bookkeeping remained")

    let releaseRoot = root.appendingPathComponent("release-failure", isDirectory: true)
    let releaseURL = releaseRoot.appendingPathComponent("requests.json")
    let releaseStore = DurableAutomaticReviewRequestStore(url: releaseURL)
    _ = try releaseStore.reconcile(paperID: paperID, automaticReviewRequired: true)
    let releaseClaim = try releaseStore.claim(paperID: paperID)!
    let bytesBeforeFailedRelease = try Data(contentsOf: releaseURL)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: releaseRoot.path)
    var releaseFailed = false
    do {
      try releaseStore.release(
        requestID: releaseClaim.id, generationID: releaseClaim.generationID!)
    } catch {
      releaseFailed = true
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: releaseRoot.path)
    try expect(releaseFailed, "unwritable automatic request release was silently accepted")
    let bytesAfterFailedRelease = try Data(contentsOf: releaseURL)
    try expect(
      bytesAfterFailedRelease == bytesBeforeFailedRelease,
      "failed release changed durable request bytes")
    let requestAfterFailedRelease = try releaseStore.request(paperID: paperID)
    try expect(
      requestAfterFailedRelease?.state == .claimed,
      "failed release did not preserve the durable claimed state")

    let source = try String(
      contentsOf: URL(
        fileURLWithPath: "Sources/PapertrailApp/PaperLibraryController.swift"),
      encoding: .utf8)
    try expect(!source.contains("automaticReviewRequests.reconcile")
      && !source.contains("startAutomaticReview"), "legacy requests are still dispatched by the app")
  }

  static func testStateTransitions() throws {
    let process: [ProcessOutcome] = [.pending, .running, .turnCompleted, .failed, .cancelled, .interrupted, .protocolFailure]
    let validProcess: Set<String> = [
      "pending>running", "pending>failed", "pending>cancelled", "pending>interrupted", "pending>protocolFailure",
      "running>turnCompleted", "running>failed", "running>cancelled", "running>interrupted", "running>protocolFailure",
      "turnCompleted>cancelled", "turnCompleted>protocolFailure",
    ]
    for from in process { for to in process {
      let key = "\(from.rawValue)>\(to.rawValue)"
      let accepted = (try? ReviewStateMachine.validate(process: from, to: to)) != nil
      try expect(accepted == validProcess.contains(key), "process matrix mismatch \(key)")
    }}
    let structures: [StructuralValidationState] = [.notRun, .running, .passed, .failed]
    let validStructure: Set<String> = ["notRun>running", "running>passed", "running>failed"]
    for from in structures { for to in structures {
      let key = "\(from.rawValue)>\(to.rawValue)"
      try expect(((try? ReviewStateMachine.validate(structure: from, to: to)) != nil) == validStructure.contains(key), "structure matrix mismatch \(key)")
    }}
    let evidence: [EvidenceReportState] = [.missing, .produced, .invalid]
    for from in evidence { for to in evidence {
      let valid = from == .missing && (to == .produced || to == .invalid)
      try expect(((try? ReviewStateMachine.validate(evidence: from, to: to)) != nil) == valid, "evidence matrix mismatch")
    }}
    let quality: [QualityVerificationState] = [.notPerformed, .inProgress, .verified, .failed]
    let validQuality: Set<String> = ["notPerformed>inProgress", "inProgress>verified", "inProgress>failed", "failed>inProgress"]
    for from in quality { for to in quality {
      let key = "\(from.rawValue)>\(to.rawValue)"
      try expect(((try? ReviewStateMachine.validate(quality: from, to: to)) != nil) == validQuality.contains(key), "quality matrix mismatch \(key)")
    }}
    let promotions: [ReviewPromotionPhase] = [
      .none, .intentRecorded, .filesMoved, .committed, .selected,
      .recoveryRequired, .quarantined,
    ]
    let validPromotion: Set<String> = [
      "none>intentRecorded", "intentRecorded>filesMoved", "intentRecorded>quarantined",
      "filesMoved>committed", "filesMoved>quarantined",
      "committed>selected", "committed>recoveryRequired",
    ]
    for from in promotions { for to in promotions {
      let key = "\(from.rawValue)>\(to.rawValue)"
      try expect(((try? ReviewStateMachine.validate(promotion: from, to: to)) != nil) == validPromotion.contains(key), "promotion matrix mismatch \(key)")
    }}
  }

  static func testStagedMutation() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake")
    try fakeExecutable(executable, mode: "success")
    let identity = ReviewGenerationIdentity()
    do {
      _ = try fixture.service.generate(
        paperID: fixture.paperID, executableURL: executable, identity: identity,
        hooks: .init(afterTransport: {
          let text = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID)
            .appendingPathComponent("input/paper-text.txt")
          try? self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: text.path)
          try? Data("mutation".utf8).write(to: text)
        }))
      throw Failure(description: "mutated staged input was promoted")
    } catch ReviewGenerationServiceError.stagedInputMutation {}
    let record = try fixture.reviewStore.generations(paperID: fixture.paperID).first!
    try expect(record.processOutcome == .protocolFailure && record.reviewVersionID == nil, "mutation state was not failed closed")
    let quarantine = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID).appendingPathComponent("quarantine")
    try expect(fm.fileExists(atPath: quarantine.path), "mutated output was not quarantined")
  }

  static func testCanonicalContainment() throws {
    let fixture = try makeFixture(twoPapers: true); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake")
    try fakeExecutable(executable, mode: "success")
    var snapshot = try fixture.durable.load()
    let other = snapshot.papers[1]
    snapshot.papers[0].sourceRelativePath = other.sourceRelativePath
    snapshot.papers[0].sourceSHA256 = other.sourceSHA256
    try fixture.durable.save(snapshot)
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable)
      throw Failure(description: "paper A accepted paper B source")
    } catch ReviewGenerationServiceError.sourceOutsidePaper {}

    let clean = try makeFixture(); defer { try? fm.removeItem(at: clean.root) }
    let identity = ReviewGenerationIdentity(), outside = clean.root.appendingPathComponent("outside.png")
    try Data("outside".utf8).write(to: outside)
    do {
      _ = try clean.service.generate(
        paperID: clean.paperID, executableURL: executable, identity: identity,
        hooks: .init(afterTransport: {
          let result = clean.paths.generationWorkspace(identity.generationID, paperID: clean.paperID)
            .appendingPathComponent("output/operations/\(identity.operationID.uuidString.lowercased())/review.json")
          try? self.fm.removeItem(at: result)
          try? self.fm.createSymbolicLink(at: result, withDestinationURL: outside)
        }))
      throw Failure(description: "operation result symlink escaped workspace")
    } catch ReviewGenerationServiceError.unsafeOutput {}
    let unsafeRecords = try clean.reviewStore.generations(paperID: clean.paperID)
    try expect(unsafeRecords.first?.reviewVersionID == nil, "unsafe operation result promoted")
    try expect(
      unsafeRecords.first?.structuralValidation == .failed,
      "unsafe operation result left validation running")
  }

  static func testPostTransportCancellation() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake")
    try fakeExecutable(executable, mode: "success")
    let token = CodexCancellationToken()
    let result = try fixture.service.generate(
      paperID: fixture.paperID, executableURL: executable, cancellation: token,
      hooks: .init(afterTransport: { token.cancel() }))
    try expect(result.processOutcome == .cancelled && result.versionID == nil, "post-transport cancel promoted")
    let cancelledSnapshot = try fixture.durable.load()
    try expect(cancelledSnapshot.papers[0].selectedReviewVersionID == nil, "post-transport cancel selected")
  }

  static func testPromotionCrashRecovery() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let executable = fixture.root.appendingPathComponent("fake")
    try fakeExecutable(executable, mode: "success")
    let baseline = ReviewGenerationIdentity()
    _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable, identity: baseline)

    let intent = ReviewGenerationIdentity()
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable, predecessorGenerationID: baseline.generationID, identity: intent, hooks: .init(crashPoint: .afterPromotionIntent))
      throw Failure(description: "intent crash did not fire")
    } catch ReviewGenerationServiceError.simulatedCrash(.afterPromotionIntent) {}
    let intentFinal = fixture.paths.reviewVersion(intent.versionID, generationID: intent.generationID, paperID: fixture.paperID)
    let partial = intentFinal.deletingLastPathComponent().appendingPathComponent(".partial-\(intent.versionID.uuidString.lowercased())")
    try fm.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: partial.appendingPathComponent("index.html"))
    let firstRecovery = try ReviewPromotionReconciler().reconcile(paperID: fixture.paperID, paths: fixture.paths, store: fixture.reviewStore)
    try expect(firstRecovery.contains { $0.action == "quarantined-partial" }, "partial crash was not quarantined")

    let moved = ReviewGenerationIdentity()
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable, predecessorGenerationID: intent.generationID, identity: moved, hooks: .init(crashPoint: .afterFilesMoved))
      throw Failure(description: "files-moved crash did not fire")
    } catch ReviewGenerationServiceError.simulatedCrash(.afterFilesMoved) {}
    let secondRecovery = try ReviewPromotionReconciler().reconcile(paperID: fixture.paperID, paths: fixture.paths, store: fixture.reviewStore)
    try expect(secondRecovery.contains { $0.action == "recovered-final-without-changing-selection" }, "moved final was not recovered")
    let recoveredSnapshot = try fixture.durable.load()
    try expect(recoveredSnapshot.papers[0].selectedReviewVersionID == baseline.versionID, "recovery overwrote prior selection")
    let recoveredRecord = recoveredSnapshot.generations.first { $0.id == moved.generationID }
    try expect(recoveredRecord?.promotionPhaseRawValue == ReviewPromotionPhase.recoveryRequired.rawValue, "recovery did not atomically reach recoveryRequired")
    try expect(recoveredSnapshot.evidenceReports.contains { $0.generationID == moved.generationID }, "atomic recovery omitted evidence record")
    try expect(recoveredSnapshot.qualityVerifications.contains { $0.generationID == moved.generationID }, "atomic recovery omitted quality record")

    func crashedFinal(_ identity: ReviewGenerationIdentity) throws -> URL {
      do {
        _ = try fixture.service.generate(
          paperID: fixture.paperID, executableURL: executable, predecessorGenerationID: baseline.generationID,
          identity: identity, hooks: .init(crashPoint: .afterFilesMoved))
        throw Failure(description: "files-moved crash did not fire")
      } catch ReviewGenerationServiceError.simulatedCrash(.afterFilesMoved) {}
      return fixture.paths.reviewVersion(
        identity.versionID, generationID: identity.generationID, paperID: fixture.paperID)
    }

    func requireQuarantine(_ identity: ReviewGenerationIdentity, _ reason: String) throws {
      let reports = try ReviewPromotionReconciler().reconcile(
        paperID: fixture.paperID, paths: fixture.paths, store: fixture.reviewStore)
      try expect(reports.contains {
        $0.generationID == identity.generationID && $0.action == "quarantined-uncommitted-final"
      }, "\(reason) final was not quarantined")
      let record = try fixture.reviewStore.generations(paperID: fixture.paperID)
        .first { $0.id == identity.generationID }
      try expect(record?.reviewVersionID == nil && record?.promotionPhase == .quarantined,
        "\(reason) final became selectable")
    }

    let tampered = ReviewGenerationIdentity()
    let tamperedFinal = try crashedFinal(tampered)
    let tamperedIndex = tamperedFinal.appendingPathComponent("index.html")
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tamperedIndex.path)
    try Data("tampered".utf8).write(to: tamperedIndex)
    try requireQuarantine(tampered, "content-tampered")

    let linked = ReviewGenerationIdentity()
    let linkedFinal = try crashedFinal(linked)
    let linkedIndex = linkedFinal.appendingPathComponent("index.html")
    let outside = fixture.root.appendingPathComponent("promotion-outside.html")
    try Data("outside".utf8).write(to: outside)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: linkedFinal.path)
    try fm.removeItem(at: linkedIndex)
    try fm.createSymbolicLink(at: linkedIndex, withDestinationURL: outside)
    try requireQuarantine(linked, "symlinked")

    let mutable = ReviewGenerationIdentity()
    let mutableFinal = try crashedFinal(mutable)
    try fm.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: mutableFinal.appendingPathComponent("index.html").path)
    try requireQuarantine(mutable, "mutable-mode")

    let corruptEvidence = ReviewGenerationIdentity()
    let corruptEvidenceFinal = try crashedFinal(corruptEvidence)
    let evidenceURL = corruptEvidenceFinal.appendingPathComponent("evidence-report.json")
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidenceURL.path)
    try Data(#"{"trust":"forged","independentlyVerified":true}"#.utf8).write(to: evidenceURL)
    try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: evidenceURL.path)
    try requireQuarantine(corruptEvidence, "evidence-corrupt")

    let committed = ReviewGenerationIdentity()
    do {
      _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: executable, predecessorGenerationID: moved.generationID, identity: committed, hooks: .init(crashPoint: .afterStoreCommit))
      throw Failure(description: "commit crash did not fire")
    } catch ReviewGenerationServiceError.simulatedCrash(.afterStoreCommit) {}
    let committedRecord = try fixture.reviewStore.generations(paperID: fixture.paperID).first { $0.id == committed.generationID }
    try expect(committedRecord?.reviewVersionID == committed.versionID, "atomic commit lost version")
    let committedSnapshot = try fixture.durable.load()
    try expect(committedSnapshot.papers[0].selectedReviewVersionID == committed.versionID, "atomic commit lost selection")
  }

  static func testCancellation() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let good = fixture.root.appendingPathComponent("good"), slow = fixture.root.appendingPathComponent("slow")
    try fakeExecutable(good, mode: "success"); try fakeExecutable(slow, mode: "slow")
    let selected = ReviewGenerationIdentity()
    _ = try fixture.service.generate(paperID: fixture.paperID, executableURL: good, identity: selected)
    let token = CodexCancellationToken(), identity = ReviewGenerationIdentity(), box = LockedResultBox()
    let group = DispatchGroup(); group.enter()
    DispatchQueue.global().async {
      box.set(Result {
        try fixture.service.generate(
          paperID: fixture.paperID, executableURL: slow,
          predecessorGenerationID: selected.generationID, identity: identity,
          cancellation: token)
      })
      group.leave()
    }
    let marker = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID).appendingPathComponent("started")
    let deadline = Date().addingTimeInterval(5)
    while !fm.fileExists(atPath: marker.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    try expect(fm.fileExists(atPath: marker.path), "slow process did not start")
    token.cancel()
    try expect(group.wait(timeout: .now() + 5) == .success, "cancel did not terminate process")
    guard case .success(let result)? = box.get() else { throw Failure(description: "cancel generation threw") }
    try expect(result.processOutcome == .cancelled && result.versionID == nil, "cancelled work promoted")
    let snapshot = try fixture.durable.load()
    try expect(snapshot.papers[0].selectedReviewVersionID == selected.versionID, "cancel changed selection")
  }

  static func testReconciliation() throws {
    let fixture = try makeFixture(); defer { try? fm.removeItem(at: fixture.root) }
    let identity = ReviewGenerationIdentity()
    let workspace = fixture.paths.generationWorkspace(identity.generationID, paperID: fixture.paperID)
    try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
    _ = try fixture.reviewStore.createGeneration(
      generationID: identity.generationID, paperID: fixture.paperID,
      sessionID: identity.sessionID, operationID: identity.operationID,
      workspaceRelativePath: fixture.paths.relativePath(for: workspace),
      sessionWorkspaceRelativePath: fixture.paths.relativePath(for: workspace),
      promptSHA256: "hash",
      journalRelativePath: fixture.paths.relativePath(
        for: workspace.deletingLastPathComponent().appendingPathComponent("operations/x")),
      predecessorGenerationID: nil)
    let ids = try fixture.reviewStore.reconcileInterruptedGenerations()
    try expect(ids == [identity.generationID], "running generation not reconciled")
    let record = try fixture.reviewStore.generations(paperID: fixture.paperID)[0]
    try expect(record.processOutcome == .interrupted && record.reviewVersionID == nil, "reconciliation overclaimed")
  }

  static func testSourceContracts() throws {
    let package = try String(contentsOf: URL(fileURLWithPath: "Package.swift"), encoding: .utf8)
    let buildGate0E = try String(contentsOf: URL(fileURLWithPath: "Scripts/build-gate0e-app.sh"), encoding: .utf8)
    let buildGate0H = try String(contentsOf: URL(fileURLWithPath: "Scripts/build-gate0h-app.sh"), encoding: .utf8)
    for source in [package, buildGate0E, buildGate0H] {
      try expect(!source.contains("Gate0B"), "legacy Gate0B execution path remains")
      try expect(!source.contains("papertrail-template"), "legacy review template remains bundled")
    }
    try expect(
      !fm.fileExists(atPath: "papertrail-template")
        && !fm.fileExists(atPath: "Sources/Gate0BHarness")
        && !fm.fileExists(atPath: "Sources/Gate0BTests"),
      "legacy review generation files remain")
    let swiftData = try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailCore/Review/SwiftDataReviewGenerationStore.swift"), encoding: .utf8)
    let controller = try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailApp/ReviewGenerationController.swift"), encoding: .utf8)
    let chatController = try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailApp/PaperChatController.swift"), encoding: .utf8)
    let library = try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailApp/PaperLibraryController.swift"), encoding: .utf8)
    let view = try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailApp/PaperWorkspaceViews.swift"), encoding: .utf8)
    for required in ["SwiftDataReviewGenerationStore", "context.save()", "selectedReviewVersionID", "reconcileInterruptedGenerations"] {
      try expect(swiftData.contains(required), "SwiftData path lacks \(required)")
    }
    for required in ["service.generate", "CodexCancellationToken", "predecessorGenerationID", "source excerpts verified"] {
      try expect(controller.contains(required), "review controller lacks \(required)")
    }
    try expect(controller.contains("guard !isRunning else { return }"), "manual and automatic review starts are not serialized")
    try expect(
      !controller.contains("try? CodexExecutableResolver")
        && !chatController.contains("try? CodexExecutableResolver"),
      "app controller still collapses Codex resolver failures")
    try expect(
      controller.contains("error.localizedDescription")
        && chatController.contains("error.localizedDescription"),
      "app controller does not preserve the Codex resolver failure reason")
    try expect(expectOrder(in: controller, ["conversationProvider()", "executableProvider.executableURL()"]),
      "conversation is not captured before asynchronous preparation")
    for forbidden in ["startAutomaticReview", "resumeAutomaticReviews", "automaticReviewRequests.reconcile"] {
      try expect(!library.contains(forbidden), "library still starts automatic generation: \(forbidden)")
    }
    try expect(!controller.contains("generateAutomaticallyIfNeeded"), "automatic generation remains reachable")
    try expect(swiftData.contains("try ReviewStateMachine.validate(promotion: current, to: phase)"), "SwiftData promotion updates bypass the shared transition matrix")
    for required in ["automaticReviewRequiredAt", "automaticReviewCompletedAt", "markAutomaticReviewCompleted"] {
      try expect(swiftData.contains(required), "SwiftData automatic-review marker path lacks \(required)")
    }
    guard let recoveryStart = swiftData.range(of: "public func recoverPromotion(generationID: UUID) throws"),
      let recoveryEnd = swiftData.range(
        of: "public func markPromotionPhase", range: recoveryStart.upperBound..<swiftData.endIndex)
    else { throw Failure(description: "SwiftData recovery transaction could not be inspected") }
    let recoveryBody = String(swiftData[recoveryStart.lowerBound..<recoveryEnd.lowerBound])
    try expect(recoveryBody.components(separatedBy: "context.save()").count - 1 == 1, "SwiftData recovery is split across multiple saves")
    try expect(recoveryBody.contains("ReviewPromotionPhase.recoveryRequired.rawValue"), "SwiftData atomic recovery does not commit recoveryRequired")
    for required in ["Generate document", "Regenerate document", "Versions", "conversation so far"] {
      try expect(view.contains(required), "review UI lacks \(required)")
    }
  }

  static func expectOrder(in source: String, _ needles: [String]) -> Bool {
    var lowerBound = source.startIndex
    for needle in needles {
      guard let range = source.range(of: needle, range: lowerBound..<source.endIndex) else {
        return false
      }
      lowerBound = range.upperBound
    }
    return true
  }

  struct Fixture {
    let root: URL, paths: LibraryPaths, durable: DurableModelStore
    let reviewStore: PortableReviewGenerationStore
    let service: ReviewGenerationService
    let paperID: UUID
  }

  static func makeFixture(twoPapers: Bool = false) throws -> Fixture {
    let root = fm.temporaryDirectory.appendingPathComponent("gate0f-\(UUID().uuidString)", isDirectory: true)
    let paths = LibraryPaths(applicationSupport: root.appendingPathComponent("support"))
    try paths.createRootTopology()
    let durable = DurableModelStore(storeURL: paths.storeURL)
    var snapshot = DurableSnapshot()
    let paperID = UUID()
    for id in twoPapers ? [paperID, UUID()] : [paperID] {
      let source = paths.sourceDirectory(paperID: id).appendingPathComponent("paper.pdf")
      try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try Data(contentsOf: URL(fileURLWithPath: "Fixtures/Papers/representative-paper.pdf"))
      try data.write(to: source)
      snapshot.papers.append(Paper(
        id: id, canonicalTitle: "Paper", safeBasename: "paper",
        sourceRelativePath: try paths.relativePath(for: source),
        sourceSHA256: ImmutableFileStore.sha256(data)))
    }
    try durable.save(snapshot)
    let reviewStore = PortableReviewGenerationStore(store: durable)
    return Fixture(root: root, paths: paths, durable: durable, reviewStore: reviewStore, service: ReviewGenerationService(paths: paths, store: reviewStore), paperID: paperID)
  }

  static func fakeExecutable(_ url: URL, mode: String) throws {
    let body: String
    switch mode {
    case "failed":
      body = """
      #!/bin/sh
      cat >/dev/null
      printf '{"type":"turn.started","turn_id":"t"}\\n'
      printf '{"type":"thread.started","thread_id":"thread-review"}\\n'
      printf '{"type":"turn.failed","turn_id":"t"}\\n'
      exit 1
      """
    case "invalid":
      body = script(outputReviewJSON: #"{"schemaVersion":1}"#)
    case "slow":
      body = """
      #!/bin/sh
      cat >/dev/null
      : > started
      printf '{"type":"turn.started","turn_id":"t"}\\n'
      printf '{"type":"thread.started","thread_id":"thread-review"}\\n'
      sleep 10
      printf '{"type":"turn.completed","turn_id":"t"}\\n'
      """
    default:
      body = script(outputReviewJSON: canonicalReviewJSON())
    }
    try Data(body.utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  static func script(outputReviewJSON: String) -> String {
    let encoded = Data(outputReviewJSON.utf8).base64EncodedString()
    return """
    #!/bin/sh
    set -eu
    cat > received-prompt.txt
    printf '%s\\n' "$*" > invocation.txt
    review_dir=$(find output/operations -mindepth 1 -maxdepth 1 -type d | head -1)
    printf '%s' '\(encoded)' | base64 -D > "$review_dir/review.json"
    printf '{"type":"turn.started","turn_id":"t"}\\n'
    printf '{"type":"thread.started","thread_id":"thread-review"}\\n'
    printf '{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"generated"}}\\n'
    printf '{"type":"turn.completed","turn_id":"t"}\\n'
    """
  }

  static func canonicalReviewJSON() -> String {
    #"""
    {
      "schemaVersion": 1,
      "title": "Signals in a Small Synthetic Sensor Array",
      "summary": {"id":"summary","text":"네 개 센서 관측값의 산술 평균을 검증하는 합성 실험이다.","evidenceIDs":["e_abstract"]},
      "researchProblem": {"id":"problem","text":"로컬 리뷰 파이프라인을 시험할 결정적 센서 배열 예제를 제공한다.","evidenceIDs":["e_abstract"]},
      "method": {
        "overview":{"id":"method_overview","text":"고정 오프셋을 가진 네 관측값의 산술 평균을 계산한다.","evidenceIDs":["e_method"]},
        "pipeline":[{"id":"step_mean","input":"네 개의 보정된 센서 관측값","process":"네 값의 산술 평균 계산","output":"결정적 추정값","evidenceIDs":["e_method"]}],
        "assumptions":[{"id":"assumption_fixed","text":"모든 센서는 같은 단위 진폭 신호를 관측한다.","evidenceIDs":["e_method"]}]
      },
      "contributions":[{"id":"contribution_fixture","text":"학습 파라미터나 외부 데이터가 없는 재현 가능한 검증 예제를 제시한다.","evidenceIDs":["e_method"]}],
      "experiments":{"status":"reported","items":[{"id":"experiment_result","condition":"0.90, 1.00, 1.05, 1.10의 고정 관측값","metric":"산술 평균","result":"1.0125","evidenceIDs":["e_result"]}]},
      "authorLimitations":{"status":"reported","items":[{"id":"limitation_scope","text":"실세계 일반화나 통계적 유의성을 입증하지 않는다.","evidenceIDs":["e_limit"]}]},
      "reviewerConcerns":{"status":"reported","items":[{"id":"concern_external","affectedClaim":"실세계 적용 가능성","concern":"합성된 단일 결정적 예제만 보고된다.","whyItMatters":"외부 환경의 잡음과 분포 변화를 평가할 수 없다.","unresolved":"물리 센서에서도 같은 오차 특성이 유지되는지 알 수 없다.","resolvingCheck":"실제 센서와 반복 측정으로 외적 타당성을 검증한다.","evidenceIDs":["e_limit"]}]},
      "strongestSupportedConclusion":{"id":"conclusion","text":"제시된 네 값에 대해 결정적 추정값 1.0125가 재현된다.","evidenceIDs":["e_result"]},
      "followUpQuestions":["실제 센서 반복 측정에서도 오차가 유지되는가?"],
      "evidence":[
        {"id":"e_abstract","pageIndex":1,"printedLocator":"Abstract","class":"authorStatement","exactExcerpt":"This synthetic paper describes a deterministic sensor-array experiment designed solely to exercise a local review pipeline.","supports":["summary","problem"]},
        {"id":"e_method","pageIndex":1,"printedLocator":"Sec. 1","class":"directEvidence","exactExcerpt":"The estimator is the arithmetic mean of the four observations. No learned parameters or external data are used.","supports":["method_overview","step_mean","assumption_fixed","contribution_fixture"]},
        {"id":"e_result","pageIndex":2,"printedLocator":"Sec. 2","class":"directEvidence","exactExcerpt":"The deterministic estimator returns 1.0125 for the fixture values.","supports":["experiment_result","conclusion"]},
        {"id":"e_limit","pageIndex":2,"printedLocator":"Sec. 2","class":"authorStatement","exactExcerpt":"It does not establish robustness, statistical significance, external validity, or suitability for a physical sensor.","supports":["limitation_scope","concern_external"]}
      ]
    }
    """#
  }
}
