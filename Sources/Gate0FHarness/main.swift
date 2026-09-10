import Foundation
import PapertrailCore

private struct BoundedTransport: CodexTransport {
  let timeout: TimeInterval
  func execute(
    _ invocation: CodexInvocation, journal: OperationJournal,
    cancellation: CodexCancellationToken
  ) throws -> CodexTransportResult {
    try DirectProcessCodexTransport().execute(
      invocation, journal: journal, cancellation: cancellation,
      policy: CodexTransportPolicy(timeout: timeout))
  }
}

private struct ServiceEvidence: Codable {
  let status: String
  let claimBoundary: String
  let startedAt: String
  let finishedAt: String
  let productionPromptSHA256: String
  let sourceFixtureSHA256Before: String
  let sourceFixtureSHA256After: String
  let generationID: UUID
  let operationID: UUID
  let versionID: UUID
  let processOutcome: ProcessOutcome
  let structuralValidation: StructuralValidationState
  let evidenceReportState: EvidenceReportState
  let qualityVerification: QualityVerificationState
  let promotionPhase: ReviewPromotionPhase
  let selected: Bool
  let structuredReviewSHA256: String
  let reviewIndexSHA256: String
  let sanitizationReportSHA256: String
  let validationReportSHA256: String
  let evidenceReportSHA256: String
  let promotionManifestSHA256: String
  let journalSHA256: String
  let externalThreadID: String?
  let independentlySemanticOrVisualVerified: Bool
  let scenario: String?
  let conversationSHA256: String?
  let conversationMessageIDs: [String]?
  let generatedDiscussion: [ReviewDiscussionNote]?
}

@main enum Gate0FHarness {
  static func main() throws {
    if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--validate-generation" {
      let serviceEvidenceURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
      let structuredReview = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
      let promotedReview = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
      let serviceEvidence = try JSONDecoder().decode(
        ServiceEvidence.self, from: Data(contentsOf: serviceEvidenceURL))
      guard structuredReview.lastPathComponent == "review.json",
        structuredReview.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
          == "operations",
        structuredReview.deletingLastPathComponent().lastPathComponent
          == serviceEvidence.operationID.uuidString.lowercased()
          || structuredReview.deletingLastPathComponent().lastPathComponent
            == serviceEvidence.operationID.uuidString.uppercased()
      else { throw Failure("structured review is not operation-owned") }
      let structuredValues = try structuredReview.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard structuredValues.isRegularFile == true, structuredValues.isSymbolicLink != true else {
        throw Failure("operation-owned review.json is missing or unsafe")
      }
      _ = try ReviewDocumentDecoder().decode(Data(contentsOf: structuredReview))

      let manifestURL = promotedReview.appendingPathComponent(
        ReviewPromotionIntegrity.manifestName)
      let manifestData = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(ReviewPromotionManifest.self, from: manifestData)
      let workspace = structuredReview.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let stagedPrompt = workspace.appendingPathComponent("prompt.md")
      guard manifest.generationID == serviceEvidence.generationID,
        manifest.versionID == serviceEvidence.versionID,
        promotedReview.lastPathComponent.lowercased()
          == serviceEvidence.versionID.uuidString.lowercased(),
        try sha256(Data(contentsOf: structuredReview)) == serviceEvidence.structuredReviewSHA256,
        try sha256(Data(contentsOf: stagedPrompt)) == serviceEvidence.productionPromptSHA256
      else { throw Failure("service evidence does not identify the supplied generation artifacts") }
      _ = try ReviewPromotionIntegrity.verify(
        root: promotedReview, expectedManifestSHA256: sha256(manifestData),
        generationID: manifest.generationID, versionID: manifest.versionID,
        evidenceState: manifest.evidenceState)
      print("PASS: current service evidence, operation review, and promoted artifacts are linked and valid")
      return
    }
    let withConversation = CommandLine.arguments.last == "--with-conversation"
    let expectedArgumentCount = withConversation ? 6 : 5
    guard CommandLine.arguments.count == expectedArgumentCount else {
      throw Failure("usage: Gate0FHarness <repo> <evidence-root> <codex> <timeout-seconds> [--with-conversation]")
    }
    let repository = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let evidenceRoot = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let executable = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
    guard let timeout = TimeInterval(CommandLine.arguments[4]), timeout > 0 else {
      throw Failure("invalid timeout")
    }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: evidenceRoot.path) else {
      throw Failure("evidence root already exists; refusing to overwrite")
    }
    try fm.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
    let sourceFixture = repository.appendingPathComponent("Fixtures/Papers/representative-paper.pdf")
    let sourceBefore = try FileFingerprint.read(sourceFixture).sha256
    let paths = LibraryPaths(applicationSupport: evidenceRoot.appendingPathComponent("ApplicationSupport"))
    try paths.createRootTopology()
    let durable = DurableModelStore(storeURL: paths.storeURL)
    let paperID = UUID(), identity = ReviewGenerationIdentity()
    let source = paths.sourceDirectory(paperID: paperID).appendingPathComponent("paper.pdf")
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: sourceFixture, to: source)
    var snapshot = DurableSnapshot()
    snapshot.papers.append(Paper(
      id: paperID, canonicalTitle: "Gate 0F representative", safeBasename: "gate-0f-representative",
      sourceRelativePath: try paths.relativePath(for: source), sourceSHA256: sourceBefore))
    var seededMessageIDs: [String] = []
    if withConversation {
      let chatSessionID = UUID()
      var completedTurn = CodexOperation(
        sessionID: chatSessionID, kind: "chatTurn", promptSHA256: "scenario-seed",
        journalRelativePath: "scenario/chat/events.jsonl")
      completedTurn.processOutcomeRawValue = ProcessOutcome.turnCompleted.rawValue
      let userMessage = ChatMessage(
        paperID: paperID, sessionID: chatSessionID, operationID: completedTurn.id,
        role: "user",
        committedContent: "이 논문의 결론이 센서 잡음 크기에 민감한지, 논문에 직접 검증한 실험이 있는지 확인해 줘.",
        deliveryState: "committed", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
      let assistantMessage = ChatMessage(
        paperID: paperID, sessionID: chatSessionID, operationID: completedTurn.id,
        role: "assistant",
        committedContent: "논문 본문에는 센서 잡음 민감도를 직접 변화시킨 실험이 보고되지 않았다. 따라서 잡음 수준별 재평가가 미해결 질문으로 남는다.",
        deliveryState: "committed", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
      snapshot.sessions.append(CodexSession(
        id: chatSessionID, paperID: paperID, purpose: .paperChat,
        workspaceRelativePath: "scenario/chat", lifecycle: .active,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
      snapshot.operations.append(completedTurn)
      snapshot.messages += [userMessage, assistantMessage]
      seededMessageIDs = [userMessage.id, assistantMessage.id].map { $0.uuidString.lowercased() }
    }
    try durable.save(snapshot)
    let store = PortableReviewGenerationStore(store: durable)
    let conversation = try ReviewConversationSnapshot.capture(paperID: paperID, store: durable)
    if withConversation {
      guard conversation.messages.map(\.id) == seededMessageIDs else {
        throw Failure("production conversation capture did not preserve the completed seeded turn")
      }
    } else if !conversation.messages.isEmpty {
      throw Failure("paper-only harness unexpectedly captured conversation")
    }
    let formatter = ISO8601DateFormatter(), started = formatter.string(from: Date())
    let service = ReviewGenerationService(
      paths: paths, store: store, transport: BoundedTransport(timeout: timeout))
    let result = try service.generate(
      paperID: paperID, executableURL: executable,
      identity: identity, conversation: conversation,
      metadata: .unavailable(reason: "Bounded offline Gate 0F run"))
    let finished = formatter.string(from: Date())
    let records = try store.generations(paperID: paperID)
    guard let record = records.first(where: { $0.id == identity.generationID }),
      record.reviewVersionID == identity.versionID, record.isSelectable,
      try store.paper(id: paperID).selectedReviewVersionID == identity.versionID
    else { throw Failure("service did not durably promote and select its review") }
    let durableAfter = try durable.load()
    let session = durableAfter.sessions.first(where: { $0.id == identity.sessionID })
    let workspace = paths.generationWorkspace(identity.generationID, paperID: paperID)
    let review = paths.reviewVersion(
      identity.versionID, generationID: identity.generationID, paperID: paperID)
    let journal = paths.operationDirectory(
      operationID: identity.operationID, forAgentWorkspace: workspace
    ).appendingPathComponent("events.jsonl")
    let structuredReview = workspace.appendingPathComponent(
      "output/operations/\(identity.operationID.uuidString.lowercased())/review.json")
    let stagedPrompt = workspace.appendingPathComponent("prompt.md")
    let stagedConversation = workspace.appendingPathComponent("input/conversation.json")
    let generatedDocument = try ReviewDocumentDecoder().decode(Data(contentsOf: structuredReview))
    if withConversation {
      let discussion = generatedDocument.discussion ?? []
      let validIDs = Set(seededMessageIDs)
      guard !discussion.isEmpty,
        discussion.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        discussion.flatMap(\.messageIDs).allSatisfy({ validIDs.contains($0) }),
        discussion.contains(where: {
          !$0.messageIDs.isEmpty
            && ($0.text.localizedCaseInsensitiveContains("잡음")
              || $0.text.localizedCaseInsensitiveContains("노이즈")
              || $0.text.localizedCaseInsensitiveContains("noise"))
        })
      else {
        throw Failure("generated review did not meaningfully synthesize the seeded sensor-noise discussion")
      }
    }
    let evidence = ServiceEvidence(
      status: "passed",
      claimBoundary: withConversation
        ? "Bounded real production-prompt run with targeted verification that completed chat was captured, referenced by exact message IDs, and meaningfully synthesized; broad semantic and visual quality remain unverified."
        : "Bounded real production-prompt process observation and deterministic pipeline checks only; semantic and visual quality remain unverified.",
      startedAt: started, finishedAt: finished,
      productionPromptSHA256: try fileSHA256(stagedPrompt),
      sourceFixtureSHA256Before: sourceBefore,
      sourceFixtureSHA256After: try FileFingerprint.read(sourceFixture).sha256,
      generationID: identity.generationID, operationID: identity.operationID,
      versionID: identity.versionID,
      processOutcome: result.processOutcome,
      structuralValidation: result.structuralValidation,
      evidenceReportState: result.evidenceReportState,
      qualityVerification: record.qualityVerification,
      promotionPhase: record.promotionPhase, selected: result.selected,
      structuredReviewSHA256: try fileSHA256(structuredReview),
      reviewIndexSHA256: try fileSHA256(review.appendingPathComponent("index.html")),
      sanitizationReportSHA256: try fileSHA256(
        review.appendingPathComponent("sanitization-report.json")),
      validationReportSHA256: try fileSHA256(
        review.appendingPathComponent("validation-report.json")),
      evidenceReportSHA256: try fileSHA256(
        review.appendingPathComponent("evidence-report.json")),
      promotionManifestSHA256: try fileSHA256(
        review.appendingPathComponent(ReviewPromotionIntegrity.manifestName)),
      journalSHA256: try fileSHA256(journal),
      externalThreadID: session?.externalThreadID,
      independentlySemanticOrVisualVerified: false,
      scenario: withConversation ? "paper-plus-completed-chat" : "paper-only",
      conversationSHA256: try fileSHA256(stagedConversation),
      conversationMessageIDs: withConversation ? seededMessageIDs : [],
      generatedDiscussion: generatedDocument.discussion)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(
      to: evidenceRoot.appendingPathComponent("real-service-run.json"), options: .withoutOverwriting)
    print(withConversation
      ? "PASS: Gate 0F bounded real paper-plus-chat synthesis run"
      : "PASS: Gate 0F bounded real ReviewGenerationService run")
    print("Evidence: \(evidenceRoot.path)")
  }

  private static func sha256(_ data: Data) -> String {
    ImmutableFileStore.sha256(data)
  }

  private static func fileSHA256(_ url: URL) throws -> String {
    sha256(try Data(contentsOf: url))
  }
}

private struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
