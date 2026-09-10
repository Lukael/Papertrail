import Foundation

public struct ChatTurnResult: Sendable {
  public let operationID: UUID
  public let sessionID: UUID
  public let outcome: CodexOperationOutcome
  public let replacementSessionID: UUID?
}

public actor PaperChatCoordinator {
  private struct DurableResultAwaitingCommit: Error {
    let underlying: Error
  }

  private let store: any PaperChatStore
  private let paths: LibraryPaths
  private let executableURL: URL
  private let model: String?
  private let reasoningEffort: CodexReasoningEffort?
  private let transport: DirectProcessCodexTransport
  private let runtimeRegistry: PaperChatRuntimeRegistry

  public init(
    store: any PaperChatStore, paths: LibraryPaths, executableURL: URL, model: String? = nil,
    reasoningEffort: CodexReasoningEffort? = nil,
    transport: DirectProcessCodexTransport = .init(),
    runtimeRegistry: PaperChatRuntimeRegistry = .init()
  ) {
    self.store = store
    self.paths = paths
    self.executableURL = executableURL
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.transport = transport
    self.runtimeRegistry = runtimeRegistry
  }

  public func messages(paperID: UUID) throws -> [ChatMessageRecord] {
    try store.messages(paperID: paperID)
  }

  public func send(
    paperID: UUID, text: String,
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil
  ) async throws -> ChatTurnResult {
    let session = try await ensureInitialSession(paperID: paperID)
    return try await executeTurn(
      paperID: paperID, session: session, text: text, progress: progress)
  }

  public func retry(
    paperID: UUID, failedOperationID: UUID, text: String,
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil
  ) async throws -> ChatTurnResult {
    let session = try await ensureInitialSession(paperID: paperID)
    return try await executeTurn(
      paperID: paperID, session: session, text: text,
      retryPredecessorID: failedOperationID, progress: progress)
  }

  public func refreshContext(paperID: UUID, reason: String = "explicit context refresh") async throws
    -> ChatSessionRecord
  {
    guard let predecessor = try store.currentSession(paperID: paperID) else {
      return try await ensureInitialSession(paperID: paperID)
    }
    return try stageAndCommitReplacement(
      paperID: paperID, predecessor: predecessor, reason: reason)
  }

  public func cancel(operationID: UUID) async {
    await runtimeRegistry.cancel(operationID: operationID)
  }

  public func cancelCurrent(paperID: UUID) async {
    guard let session = try? store.currentSession(paperID: paperID) else { return }
    guard let workspace = try? paths.url(forRelativePath: session.workspaceRelativePath) else {
      return
    }
    await runtimeRegistry.cancelCurrent(
      key: ChatQueueKey(sessionID: session.id, workspaceURL: workspace))
  }

  private func ensureInitialSession(paperID: UUID) async throws -> ChatSessionRecord {
    let paper = try store.paper(id: paperID)
    if let current = try store.currentSession(paperID: paperID) {
      let workspace = try paths.url(forRelativePath: current.workspaceRelativePath)
      if hasCurrentChatContext(workspace: workspace, sourceSHA256: paper.sourceSHA256) {
        return current
      }
      return try stageAndCommitReplacement(
        paperID: paperID, predecessor: current,
        reason: replacementReason(workspace: workspace, sourceSHA256: paper.sourceSHA256))
    }
    let sessionID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paperID)
    let source = try paths.url(forRelativePath: paper.sourceRelativePath)
    let extractedText = try PDFExtractedTextCache(paths: paths).resolve(
      paperID: paperID, sourceURL: source, expectedSourceSHA256: paper.sourceSHA256)
    let review = try selectedReview(paperID: paperID)
    _ = try ChatBootstrapBuilder().stage(
      sourceURL: source, expectedSourceSHA256: paper.sourceSHA256, workspaceURL: workspace,
      context: ChatBootstrapContext(
        paperID: paperID, title: paper.title,
        selectedReviewRelativePath: review == nil ? nil : "selected-review/index.html",
        selectedReviewQualityNote: review?.context.qualityNote),
      extractedText: extractedText,
      selectedReviewURL: review?.url)
    return try store.createInitialSession(
      paperID: paperID, sessionID: sessionID,
      workspaceRelativePath: paths.relativePath(for: workspace))
  }

  private func hasCurrentChatContext(workspace: URL, sourceSHA256: String) -> Bool {
    guard let bootstrap = try? String(
      contentsOf: workspace.appendingPathComponent("bootstrap.txt"), encoding: .utf8),
      bootstrap.contains(PaperChatSystemPromptBuilder.marker),
      metadataValue("source_sha256", in: bootstrap) == sourceSHA256,
      let expectedTextSHA256 = metadataValue("primary_text_sha256", in: bootstrap),
      expectedTextSHA256.count == 64
    else { return false }
    let stagedText = workspace.appendingPathComponent("input/paper-text.txt")
    guard let values = try? stagedText.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ]), values.isRegularFile == true, values.isSymbolicLink != true,
      let fingerprint = try? FileFingerprint.read(
        stagedText, maximumByteCount: Int64(PDFExtractedTextCache.maximumTextByteCount))
    else { return false }
    return fingerprint.sha256 == expectedTextSHA256
  }

  private func replacementReason(workspace: URL, sourceSHA256: String) -> String {
    let bootstrap = try? String(
      contentsOf: workspace.appendingPathComponent("bootstrap.txt"), encoding: .utf8)
    if bootstrap.flatMap({ metadataValue("source_sha256", in: $0) }) != sourceSHA256 {
      return "paper source changed after supplementary PDF merge"
    }
    return "paper chat cached context was missing, changed, or upgraded to \(PaperChatSystemPromptBuilder.marker)"
  }

  private func metadataValue(_ key: String, in bootstrap: String) -> String? {
    let prefix = key + ": "
    return bootstrap.split(separator: "\n", omittingEmptySubsequences: false)
      .first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
  }

  private func executeTurn(
    paperID: UUID, session: ChatSessionRecord, text: String,
    retryPredecessorID: UUID? = nil,
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil
  ) async throws -> ChatTurnResult {
    let workspace = try paths.url(forRelativePath: session.workspaceRelativePath)
    let operationID = UUID()
    let operationDirectory = paths.operationDirectory(
      operationID: operationID, forAgentWorkspace: workspace)
    let journalRelative = try paths.relativePath(for: operationDirectory)
    let prepared = try store.prepareTurn(
      paperID: paperID, sessionID: session.id, prompt: text, operationID: operationID,
      userMessageID: UUID(), journalRelativePath: journalRelative,
      retryPredecessorID: retryPredecessorID)
    let key = ChatQueueKey(sessionID: session.id, workspaceURL: workspace)
    let cancellation = CodexCancellationToken()

    do {
      return try await runtimeRegistry.run(
        key: key, operationID: operationID, cancellation: cancellation
      ) { [transport, executableURL, model, reasoningEffort, store] in
        guard let current = try store.currentSession(paperID: paperID), current.id == session.id,
          current.workspaceRelativePath == session.workspaceRelativePath
        else { throw ChatStoreError.sessionNotCurrent }
        try store.assertCurrentSession(
          paperID: paperID, sessionID: current.id,
          externalThreadID: current.externalThreadID)
        let result: CodexTransportResult
        do {
          result = try await Task.detached(priority: .userInitiated) {
            let bootstrap = try String(
              contentsOf: workspace.appendingPathComponent("bootstrap.txt"), encoding: .utf8)
            let isNew = current.externalThreadID == nil
            let prompt = isNew ? bootstrap + "\nUSER_TURN:\n" + prepared.prompt : prepared.prompt
            let invocation = try CodexInvocation(
              executableURL: executableURL,
              kind: current.externalThreadID.map(CodexInvocation.Kind.resume) ?? .new,
              prompt: prompt, workingDirectory: workspace, model: model,
              reasoningEffort: reasoningEffort, ignoreUserConfiguration: true)
            let journal = try OperationJournal(directoryURL: operationDirectory)
            return try transport.execute(
              invocation, journal: journal, cancellation: cancellation, progress: progress)
          }.value
        } catch {
          throw error
        }
        try CodexOperationResultStore(directoryURL: operationDirectory).write(
          CodexOperationResultV1(
            operationID: operationID, journalByteCount: journalSize(at: operationDirectory),
            state: result.state, exitStatus: result.exitStatus,
            terminationReason: CodexTerminationReason(result.terminationReason),
            retryDisposition: result.retryDisposition))
        do {
          try store.applyTransportResult(operationID: operationID, result: result)
        } catch {
          // Keep the operation running so launch reconciliation can apply the durable result.
          throw DurableResultAwaitingCommit(underlying: error)
        }
        if let thread = result.state.externalThreadID {
          try await runtimeRegistry.bind(externalThreadID: thread, to: key)
        }
        return ChatTurnResult(
          operationID: operationID, sessionID: current.id, outcome: result.state.outcome,
          replacementSessionID: nil)
      }
    } catch let pending as DurableResultAwaitingCommit {
      throw pending.underlying
    } catch {
      try? store.recordOperationFailure(operationID: operationID, outcome: .interrupted)
      throw error
    }
  }

  nonisolated private func journalSize(at operationDirectory: URL) throws -> Int {
    let values = try operationDirectory.appendingPathComponent("events.jsonl").resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size >= 0
    else { throw OperationJournalError.unsafeJournal }
    return size
  }

  private func stageAndCommitReplacement(
    paperID: UUID, predecessor: ChatSessionRecord, reason: String
  ) throws -> ChatSessionRecord {
    let paper = try store.paper(id: paperID)
    guard predecessor.paperID == paperID else { throw ChatStoreError.crossPaperReference }
    let successorID = UUID()
    let workspace = paths.chatWorkspace(successorID, paperID: paperID)
    let source = try paths.url(forRelativePath: paper.sourceRelativePath)
    let extractedText = try PDFExtractedTextCache(paths: paths).resolve(
      paperID: paperID, sourceURL: source, expectedSourceSHA256: paper.sourceSHA256)
    let review = try selectedReview(paperID: paperID)
    let messages = try store.predecessorTranscript(sessionID: predecessor.id)
    let transcript = TranscriptContextProjector().project(
      predecessorSessionID: predecessor.id.uuidString.lowercased(), messages: messages)
    _ = try ChatBootstrapBuilder().stage(
      sourceURL: source, expectedSourceSHA256: paper.sourceSHA256, workspaceURL: workspace,
      context: ChatBootstrapContext(
        paperID: paperID, title: paper.title, predecessorSessionID: predecessor.id,
        transcript: transcript,
        selectedReviewRelativePath: review == nil ? nil : "selected-review/index.html",
        selectedReviewQualityNote: review?.context.qualityNote),
      extractedText: extractedText,
      selectedReviewURL: review?.url)
    do {
      return try store.commitReplacement(
        paperID: paperID, predecessorSessionID: predecessor.id,
        successorSessionID: successorID, workspaceRelativePath: paths.relativePath(for: workspace),
        reason: reason)
    } catch {
      // The staged workspace is deliberately preserved as a recovery candidate.
      throw error
    }
  }

  private func selectedReview(paperID: UUID) throws
    -> (context: SelectedReviewChatContext, url: URL)?
  {
    guard let context = try store.selectedReviewContext(paperID: paperID) else { return nil }
    let url = try paths.url(forRelativePath: context.relativePath)
    let paperRoot = paths.paper(paperID).standardizedFileURL.resolvingSymlinksInPath()
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
    guard canonical.path.hasPrefix(paperRoot.path + "/") else {
      throw ChatStoreError.crossPaperReference
    }
    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    return (context, values.isDirectory == true ? url : url.deletingLastPathComponent())
  }
}
