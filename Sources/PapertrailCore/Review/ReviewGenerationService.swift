import CryptoKit
import Foundation

public struct ReviewGenerationIdentity: Equatable, Sendable {
  public let generationID: UUID
  public let sessionID: UUID
  public let operationID: UUID
  public let versionID: UUID

  public init(
    generationID: UUID = UUID(), sessionID: UUID = UUID(), operationID: UUID = UUID(),
    versionID: UUID = UUID()
  ) {
    self.generationID = generationID
    self.sessionID = sessionID
    self.operationID = operationID
    self.versionID = versionID
  }
}

public struct ReviewGenerationResult: Equatable, Sendable {
  public let generationID: UUID
  public let versionID: UUID?
  public let processOutcome: ProcessOutcome
  public let structuralValidation: StructuralValidationState
  public let evidenceReportState: EvidenceReportState
  public let label: String
  public let selected: Bool
}

public enum ReviewGenerationServiceError: Error, CustomStringConvertible, LocalizedError {
  case sourceHashMismatch
  case sourceOutsidePaper
  case outputMissing(String)
  case unsafeOutput(String)
  case structuredDocumentInvalid(String)
  case validationFailed(ReviewValidationReport)
  case structuredReviewFailed(StructuredReviewValidationReport)
  case stagedInputMutation
  case simulatedCrash(ReviewGenerationCrashPoint)

  public var description: String {
    switch self {
    case .sourceHashMismatch: "Stored paper hash no longer matches its durable record."
    case .sourceOutsidePaper: "Stored source does not belong to the requested paper."
    case .outputMissing(let path): "Required generation output is missing: \(path)"
    case .unsafeOutput(let path): "Generation output is unsafe or escapes its workspace: \(path)"
    case .structuredDocumentInvalid(let detail):
      "Generated review JSON is invalid: \(detail)"
    case .validationFailed(let report):
      "Generated review failed structural validation: \(report.findings.map(\.code).joined(separator: ", "))"
    case .structuredReviewFailed(let report):
      "Generated review failed semantic validation: \(report.findings.map(\.code).joined(separator: ", "))"
    case .stagedInputMutation: "The staged extracted text changed while the generator was running."
    case .simulatedCrash(let point): "Simulated crash at \(point.rawValue)."
    }
  }

  public var errorDescription: String? { description }
}

public enum ReviewGenerationCrashPoint: String, Sendable {
  case none, afterPromotionIntent, afterFilesMoved, afterStoreCommit
}

public struct ReviewGenerationHooks: @unchecked Sendable {
  public var afterTransport: (() -> Void)?
  public var crashPoint: ReviewGenerationCrashPoint

  public init(
    afterTransport: (() -> Void)? = nil,
    crashPoint: ReviewGenerationCrashPoint = .none
  ) {
    self.afterTransport = afterTransport
    self.crashPoint = crashPoint
  }
}

public struct ReviewGenerationService: Sendable {
  public let paths: LibraryPaths
  public let store: any ReviewGenerationStore
  public let transport: any CodexTransport

  public init(
    paths: LibraryPaths, store: any ReviewGenerationStore,
    transport: any CodexTransport = DirectProcessCodexTransport(
      policy: CodexTransportPolicy(timeout: 1_800))
  ) {
    self.paths = paths
    self.store = store
    self.transport = transport
  }

  public func generate(
    paperID: UUID, executableURL: URL,
    predecessorGenerationID: UUID? = nil, identity: ReviewGenerationIdentity = .init(),
    conversation: ReviewConversationSnapshot? = nil,
    metadata: NetworkMetadataResult = .unavailable(reason: "Network metadata was not requested."),
    autoSelect: Bool = true, model: String? = nil,
    reasoningEffort: CodexReasoningEffort? = nil,
    cancellation: CodexCancellationToken = .init(),
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil,
    hooks: ReviewGenerationHooks = .init(),
    fileManager: FileManager = .default
  ) throws -> ReviewGenerationResult {
    let conversation = conversation ?? ReviewConversationSnapshot(paperID: paperID)
    guard conversation.paperID == paperID else {
      throw ReviewGenerationServiceError.structuredDocumentInvalid("Conversation belongs to another paper.")
    }
    _ = try conversation.encoded()
    let paper = try store.paper(id: paperID)
    let source = try paths.url(forRelativePath: paper.sourceRelativePath)
    let extractedText: VerifiedPDFExtractedText
    do {
      extractedText = try PDFExtractedTextCache(paths: paths).resolve(
        paperID: paperID, sourceURL: source, expectedSourceSHA256: paper.sourceSHA256,
        fileManager: fileManager)
    } catch PDFExtractedTextCacheError.sourceOutsidePaper {
      throw ReviewGenerationServiceError.sourceOutsidePaper
    } catch PDFExtractedTextCacheError.sourceHashMismatch {
      throw ReviewGenerationServiceError.sourceHashMismatch
    }

    let workspace = paths.generationWorkspace(identity.generationID, paperID: paperID)
    let manifest = try ReviewTextWorkspaceBuilder().build(
      extractedText: extractedText, workspace: workspace, conversation: conversation, fileManager: fileManager)
    let operationOutputRelativePath =
      "output/operations/\(identity.operationID.uuidString.lowercased())/review.json"
    try fileManager.createDirectory(
      at: workspace.appendingPathComponent(operationOutputRelativePath)
        .deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let prompt = ReviewPromptBuilder().productionPrompt(
      textPath: "input/paper-text.txt", reviewRelativePath: operationOutputRelativePath,
      conversationPath: "input/conversation.json")
    let promptHash = SHA256.hash(data: Data(prompt.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let operationDirectory = paths.operationDirectory(
      operationID: identity.operationID, forAgentWorkspace: workspace)
    let journal = try OperationJournal(directoryURL: operationDirectory)
    let workspaceRelative = try paths.relativePath(for: workspace)
    let journalRelative = try paths.relativePath(for: operationDirectory)

    // Review generation is deliberately isolated from the long-lived paper-chat
    // thread. The selected immutable review is staged into chat context later.
    let sessionWorkspaceRelative = workspaceRelative

    try writeJSON(manifest, to: workspace.appendingPathComponent("staging-manifest.json"))
    try writeJSON(metadata, to: workspace.appendingPathComponent("metadata-result.json"))
    try writePrivate(Data(prompt.utf8), to: workspace.appendingPathComponent("prompt.md"))
    _ = try store.createGeneration(
      generationID: identity.generationID, paperID: paperID, sessionID: identity.sessionID,
      operationID: identity.operationID, workspaceRelativePath: workspaceRelative,
      sessionWorkspaceRelativePath: sessionWorkspaceRelative,
      promptSHA256: promptHash, journalRelativePath: journalRelative,
      predecessorGenerationID: predecessorGenerationID)

    let invocation = try CodexInvocation(
      executableURL: executableURL,
      kind: .new, prompt: prompt,
      workingDirectory: workspace, model: model, reasoningEffort: reasoningEffort,
      ignoreUserConfiguration: true)
    let result: CodexTransportResult
    do {
      result = try transport.execute(
        invocation, journal: journal, cancellation: cancellation, progress: progress)
      try store.recordProcessResult(generationID: identity.generationID, result: result)
    } catch {
      try? store.recordPreparationFailure(generationID: identity.generationID, outcome: .interrupted)
      throw error
    }
    hooks.afterTransport?()
    if cancellation.isCancellationRequested {
      if result.state.outcome == .turnCompleted {
        try store.transitionProcess(generationID: identity.generationID, to: .cancelled)
      }
      return ReviewGenerationResult(
        generationID: identity.generationID, versionID: nil, processOutcome: .cancelled,
        structuralValidation: .notRun, evidenceReportState: .missing,
        label: ProcessOutcome.cancelled.rawValue, selected: false)
    }
    guard result.state.outcome == .turnCompleted else {
      return ReviewGenerationResult(
        generationID: identity.generationID, versionID: nil,
        processOutcome: Self.persisted(result.state.outcome), structuralValidation: .notRun,
        evidenceReportState: .missing, label: Self.persisted(result.state.outcome).rawValue,
        selected: false)
    }

    let stagedInputsUnchanged =
      (try? ReviewTextWorkspaceBuilder.verifyUnchanged(manifest, fileManager: fileManager)) == true
    guard stagedInputsUnchanged else {
      try quarantineGeneratedOutput(
        workspace: workspace, reason: "staged-input-mutation", fileManager: fileManager)
      try store.transitionProcess(generationID: identity.generationID, to: .protocolFailure)
      throw ReviewGenerationServiceError.stagedInputMutation
    }
    try store.transitionStructure(generationID: identity.generationID, to: .running)

    let reviewDocumentURL = workspace.appendingPathComponent(operationOutputRelativePath)
    guard fileManager.fileExists(atPath: reviewDocumentURL.path) else {
      try store.transitionStructure(generationID: identity.generationID, to: .failed)
      throw ReviewGenerationServiceError.outputMissing(operationOutputRelativePath)
    }
    do {
      _ = try SecurePathContainment.requireExisting(reviewDocumentURL, inside: workspace)
      let values = try reviewDocumentURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ReviewGenerationServiceError.unsafeOutput(operationOutputRelativePath)
      }
    } catch {
      try store.transitionStructure(generationID: identity.generationID, to: .failed)
      if let serviceError = error as? ReviewGenerationServiceError {
        throw serviceError
      }
      throw ReviewGenerationServiceError.unsafeOutput(operationOutputRelativePath)
    }
    let reviewDocument: ReviewDocumentV1
    do {
      _ = try FileFingerprint.read(
        reviewDocumentURL,
        maximumByteCount: Int64(ReviewDocumentDecoder.maximumDocumentBytes))
      let reviewData = try Data(
        contentsOf: reviewDocumentURL, options: [.mappedIfSafe, .uncached])
      reviewDocument = try ReviewDocumentDecoder().decode(reviewData)
    } catch {
      try store.transitionStructure(generationID: identity.generationID, to: .failed)
      throw ReviewGenerationServiceError.structuredDocumentInvalid(String(describing: error))
    }
    let semanticValidation = ReviewDocumentValidator().validate(
      reviewDocument, pageTexts: try extractedText.readPages(),
      conversationMessageIDs: Set(conversation.messages.map(\.id)))
    try writeJSON(
      semanticValidation,
      to: workspace.appendingPathComponent("semantic-validation.json"))
    guard semanticValidation.passed else {
      try store.transitionStructure(generationID: identity.generationID, to: .failed)
      throw ReviewGenerationServiceError.structuredReviewFailed(semanticValidation)
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o400], ofItemAtPath: reviewDocumentURL.path)
    let renderedHTML = ReviewHTMLRenderer().render(document: reviewDocument)

    let finalVersion = paths.reviewVersion(
      identity.versionID, generationID: identity.generationID, paperID: paperID)
    let stagedVersion = finalVersion.deletingLastPathComponent()
      .appendingPathComponent(".partial-\(identity.versionID.uuidString.lowercased())", isDirectory: true)
    guard !fileManager.fileExists(atPath: finalVersion.path),
      !fileManager.fileExists(atPath: stagedVersion.path)
    else { throw ReviewGenerationStoreError.versionAlreadyExists }
    try fileManager.createDirectory(
      at: stagedVersion, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? fileManager.removeItem(at: stagedVersion) }

    let sanitized = try ReviewResourceSanitizer().sanitize(renderedHTML)
    let normalizedHTML = try ReviewFootnoteNormalizer().normalize(sanitized.html)
    try writePrivate(Data(normalizedHTML.utf8), to: stagedVersion.appendingPathComponent("index.html"))
    try writeJSON(
      sanitized.report, to: stagedVersion.appendingPathComponent("sanitization-report.json"))
    let evidenceState = EvidenceReportState.missing
    try writeJSON(
      ReviewFallbackEvidence(),
      to: stagedVersion.appendingPathComponent("evidence-report.json"))

    let validation = try ReviewValidator().validate(
      reviewDirectory: stagedVersion, html: normalizedHTML, fileManager: fileManager)
    try writeJSON(validation, to: stagedVersion.appendingPathComponent("validation-report.json"))
    let reviewRelative = try paths.relativePath(for: finalVersion)
    guard validation.passed else {
      try store.transitionStructure(generationID: identity.generationID, to: .failed)
      throw ReviewGenerationServiceError.validationFailed(validation)
    }
    try store.transitionStructure(generationID: identity.generationID, to: .passed)
    if cancellation.isCancellationRequested {
      try store.transitionProcess(generationID: identity.generationID, to: .cancelled)
      return Self.cancelled(identity)
    }
    let promotionManifest = try ReviewPromotionIntegrity.makeManifest(
      root: stagedVersion, generationID: identity.generationID,
      versionID: identity.versionID, evidenceState: evidenceState, fileManager: fileManager)
    let promotionManifestURL = stagedVersion.appendingPathComponent(
      ReviewPromotionIntegrity.manifestName)
    try writeJSON(promotionManifest, to: promotionManifestURL)
    let promotionManifestSHA256 = try FileFingerprint.read(
      promotionManifestURL,
      maximumByteCount: ReviewPromotionIntegrity.maximumManifestBytes).sha256
    try store.beginPromotion(
      generationID: identity.generationID, versionID: identity.versionID,
      reviewRelativePath: reviewRelative,
      manifestSHA256: promotionManifestSHA256, autoSelect: autoSelect)
    if hooks.crashPoint == .afterPromotionIntent {
      throw ReviewGenerationServiceError.simulatedCrash(.afterPromotionIntent)
    }
    if cancellation.isCancellationRequested {
      try quarantine(stagedVersion, workspace: workspace, reason: "cancelled-before-promotion", fileManager: fileManager)
      try store.markPromotionPhase(generationID: identity.generationID, phase: .quarantined)
      try store.transitionProcess(generationID: identity.generationID, to: .cancelled)
      return Self.cancelled(identity)
    }
    try fileManager.moveItem(at: stagedVersion, to: finalVersion)
    try makeImmutableTree(finalVersion, fileManager: fileManager)
    try ReviewPromotionIntegrity.verify(
      root: finalVersion, expectedManifestSHA256: promotionManifestSHA256,
      generationID: identity.generationID, versionID: identity.versionID,
      evidenceState: evidenceState, fileManager: fileManager)
    try store.markPromotionFilesMoved(generationID: identity.generationID)
    if hooks.crashPoint == .afterFilesMoved {
      throw ReviewGenerationServiceError.simulatedCrash(.afterFilesMoved)
    }
    if cancellation.isCancellationRequested {
      try quarantine(finalVersion, workspace: workspace, reason: "cancelled-after-files-moved", fileManager: fileManager)
      try store.markPromotionPhase(generationID: identity.generationID, phase: .quarantined)
      try store.transitionProcess(generationID: identity.generationID, to: .cancelled)
      return Self.cancelled(identity)
    }
    try store.commitPromotion(generationID: identity.generationID, applySelection: true)
    if hooks.crashPoint == .afterStoreCommit {
      throw ReviewGenerationServiceError.simulatedCrash(.afterStoreCommit)
    }
    return ReviewGenerationResult(
      generationID: identity.generationID, versionID: identity.versionID,
      processOutcome: .turnCompleted, structuralValidation: .passed,
      evidenceReportState: evidenceState,
      label: ReviewQualityLabel.generatedStructureChecked.rawValue, selected: autoSelect)
  }

  private func quarantineGeneratedOutput(
    workspace: URL, reason: String, fileManager: FileManager
  ) throws {
    let output = workspace.appendingPathComponent("output", isDirectory: true)
    guard fileManager.fileExists(atPath: output.path) else { return }
    try quarantine(output, workspace: workspace, reason: reason, fileManager: fileManager)
  }

  private func quarantine(
    _ item: URL, workspace: URL, reason: String, fileManager: FileManager
  ) throws {
    let root = workspace.appendingPathComponent("quarantine", isDirectory: true)
    try fileManager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let destination = root.appendingPathComponent(
      "\(reason)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try fileManager.moveItem(at: item, to: destination)
  }

  private func makeImmutableTree(_ root: URL, fileManager: FileManager) throws {
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }
    var directories = [root]
    for case let item as URL in enumerator {
      if (try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        directories.append(item)
      } else {
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: item.path)
      }
    }
    for directory in directories.reversed() {
      try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }
  }

  private func writePrivate<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(try encoder.encode(value), to: url)
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try writePrivate(value, to: url)
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.withoutOverwriting])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func persisted(_ outcome: CodexOperationOutcome) -> ProcessOutcome {
    switch outcome {
    case .turnCompleted: .turnCompleted
    case .failed: .failed
    case .cancelled: .cancelled
    case .timedOut, .interrupted: .interrupted
    case .protocolFailure: .protocolFailure
    case .running: .running
    }
  }

  private static func cancelled(_ identity: ReviewGenerationIdentity) -> ReviewGenerationResult {
    ReviewGenerationResult(
      generationID: identity.generationID, versionID: nil, processOutcome: .cancelled,
      structuralValidation: .passed, evidenceReportState: .missing,
      label: ProcessOutcome.cancelled.rawValue, selected: false)
  }
}
