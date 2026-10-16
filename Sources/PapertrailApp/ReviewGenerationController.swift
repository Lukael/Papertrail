import Foundation
import PapertrailCore
import SwiftUI

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

@MainActor
final class ReviewGenerationController: ObservableObject {
  @Published private(set) var generations: [ReviewGenerationRecord] = []
  @Published private(set) var isRunning = false
  @Published var status: String?

  let paperID: UUID
  let paths: LibraryPaths
  let model: String?
  let reasoningEffort: AgentReasoningEffort
  private let store: any ReviewGenerationStore
  private let conversationProvider: () throws -> ReviewConversationSnapshot
  private let activityLog: AppActivityLog
  private let executableProvider: AgentExecutableProvider
  private var cancellation: AgentCancellationToken?
  /// One log line per run that carries the latest progress plus elapsed time, refreshed even
  /// while Claude is silently thinking so a long generation never looks stalled.
  private var liveStatus = "Claude is reading the paper and planning the review"
  private var runStartedAt: Date?
  private var heartbeat: Task<Void, Never>?

  #if PPR_PORTABLE_SCHEMA
    convenience init(
      paperID: UUID, paths: LibraryPaths, store: DurableModelStore, model: String?,
      reasoningEffort: AgentReasoningEffort,
      activityLog: AppActivityLog,
      executableProvider: AgentExecutableProvider
    ) {
      self.init(
        paperID: paperID,
        paths: paths, reviewStore: PortableReviewGenerationStore(store: store), model: model,
        reasoningEffort: reasoningEffort,
        conversationProvider: {
          try ReviewConversationSnapshot.capture(paperID: paperID, store: store)
        },
        activityLog: activityLog,
        executableProvider: executableProvider)
    }
  #else
    convenience init(
      paperID: UUID, paths: LibraryPaths, container: ModelContainer, model: String?,
      reasoningEffort: AgentReasoningEffort,
      activityLog: AppActivityLog,
      executableProvider: AgentExecutableProvider
    ) {
      self.init(
        paperID: paperID,
        paths: paths, reviewStore: SwiftDataReviewGenerationStore(container: container),
        model: model,
        reasoningEffort: reasoningEffort,
        conversationProvider: {
          try ReviewConversationSnapshot.capture(paperID: paperID, container: container)
        },
        activityLog: activityLog,
        executableProvider: executableProvider)
    }
  #endif

  private init(
    paperID: UUID,
    paths: LibraryPaths,
    reviewStore: any ReviewGenerationStore,
    model: String?,
    reasoningEffort: AgentReasoningEffort,
    conversationProvider: @escaping () throws -> ReviewConversationSnapshot,
    activityLog: AppActivityLog,
    executableProvider: AgentExecutableProvider
  ) {
    self.paperID = paperID
    self.paths = paths
    self.store = reviewStore
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.conversationProvider = conversationProvider
    self.activityLog = activityLog
    self.executableProvider = executableProvider
    reconcileAndReload()
  }

  var selectedReviewLocation: SelectedReviewLocation? {
    guard let paper = try? store.paper(id: paperID), let selected = paper.selectedReviewVersionID,
      let record = generations.first(where: { $0.reviewVersionID == selected }),
      let versionID = record.reviewVersionID, let relative = record.reviewRelativePath
    else { return nil }
    let location = SelectedReviewLocation(
      paths: paths, paperID: paperID, generationID: record.id, versionID: versionID,
      persistedRelativePath: relative)
    return (try? location.resolve()) == nil ? nil : location
  }

  var selectedVersionID: UUID? { (try? store.paper(id: paperID))?.selectedReviewVersionID }

  /// Verified excerpts of the selected review, read from its rendered document.
  func selectedEvidence() -> [ReviewEvidenceAnchor] {
    guard let indexURL = try? selectedReviewLocation?.resolve().indexURL,
      let html = try? String(contentsOf: indexURL, encoding: .utf8)
    else { return [] }
    return ReviewEvidenceAnchor.anchors(inReviewHTML: html)
  }

  func generate() {
    guard !isRunning else { return }
    let conversation: ReviewConversationSnapshot
    do {
      // Capture at the button click boundary so messages sent while Claude Code is resolving
      // belong to the next synthesis rather than changing this one underneath it.
      conversation = try conversationProvider()
    } catch {
      status = "The conversation could not be prepared for review: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Review conversation preparation failed.")
      return
    }
    isRunning = true
    status = "Checking Claude Code compatibility…"
    Task {
      do {
        let executable = try await executableProvider.executableURL()
        beginGeneration(conversation: conversation, executable: executable)
      } catch {
        status =
          "Claude Code could not be used. Existing reviews remain readable: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Claude Code resolution failed.")
        isRunning = false
      }
    }
  }

  private func beginGeneration(
    conversation: ReviewConversationSnapshot, executable: URL
  ) {
    let identity = ReviewGenerationIdentity()
    status = "Synthesizing the paper and conversation into a new review version…"
    activityLog.append(level: .info, status ?? "Review generation started.")
    let token = AgentCancellationToken()
    cancellation = token
    runStartedAt = Date()
    liveStatus = "Claude is reading the paper and planning the review"
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, self.isRunning, !Task.isCancelled else { return }
        self.refreshLiveLine()
      }
    }
    let predecessor = generations.last?.id
    let service = ReviewGenerationService(paths: paths, store: store)
    let progressHandler: @Sendable (AgentLiveProgress) -> Void = { [weak self] update in
      Task { @MainActor [weak self] in self?.appendLiveProgress(update) }
    }
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        [paperID, model = self.model, reasoningEffort = self.reasoningEffort] in
        Result {
          try service.generate(
            paperID: paperID, executableURL: executable,
            predecessorGenerationID: predecessor, identity: identity,
            conversation: conversation, model: model,
            reasoningEffort: reasoningEffort,
            cancellation: token, progress: progressHandler)
        }
      }.value
      switch result {
      case .success(let value):
        status = value.label + (value.structuralValidation == .passed
          ? " · source excerpts verified" : "")
          + (value.runSummary.map { " · \($0)" } ?? "")
        activityLog.append(
          level: value.versionID == nil ? .warning : .success,
          status ?? "Review generation completed.")
      case .failure(let error):
        let failureStatus =
          "Generation stopped without replacing the selected review: \(error.localizedDescription)"
        status = failureStatus
        activityLog.append(level: .error, failureStatus)
      }
      heartbeat?.cancel()
      heartbeat = nil
      cancellation = nil
      isRunning = false
      reload()
    }
  }

  private func appendLiveProgress(_ update: AgentLiveProgress) {
    // The service summarizes raw deltas into section progress before they reach the controller.
    guard update.kind != .draft else { return }
    if update.itemID == "review-draft" || update.itemID == "thinking-tokens" {
      liveStatus = update.text
      refreshLiveLine()
      return
    }
    let level: AppActivityLogLevel = update.kind == .reasoning ? .debug : .info
    // The response is the raw review JSON; the log notes its arrival instead of echoing it.
    let message =
      update.kind == .response ? "Received the review document; validating it…" : update.text
    if let itemID = update.itemID {
      activityLog.upsert(
        key: "review:\(paperID.uuidString):\(itemID)", source: .agent, level: level,
        message: message)
    } else {
      activityLog.append(source: .agent, level: level, message)
    }
  }

  private func refreshLiveLine() {
    let elapsed = Int(Date().timeIntervalSince(runStartedAt ?? Date()))
    let clock = elapsed >= 60 ? "\(elapsed / 60)m \(elapsed % 60)s" : "\(elapsed)s"
    activityLog.upsert(
      key: "review:\(paperID.uuidString):live", source: .agent,
      message: "\(liveStatus) · \(clock)")
  }

  func cancel() {
    cancellation?.cancel()
    status = "Cancellation requested. Prior review versions remain unchanged."
    activityLog.append(level: .warning, status ?? "Review cancellation requested.")
  }

  func select(_ generation: ReviewGenerationRecord) {
    guard let version = generation.reviewVersionID, generation.isSelectable else { return }
    do {
      try store.select(paperID: paperID, versionID: version)
      reload()
      activityLog.append(level: .info, "Review version selected: \(version.uuidString)")
    } catch {
      status = "Review selection failed safely: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Review selection failed.")
    }
  }

  private func reconcileAndReload() {
    do {
      let interrupted = try store.reconcileInterruptedGenerations()
      if !interrupted.isEmpty {
        status = "Recovered \(interrupted.count) interrupted generation(s); prior selections were preserved."
        activityLog.append(level: .warning, status ?? "Interrupted generations recovered.")
      }
      let promotions = try ReviewPromotionReconciler().reconcile(
        paperID: paperID, paths: paths, store: store)
      if !promotions.isEmpty {
        status = "Recovered \(promotions.count) incomplete promotion(s); prior selections were preserved."
        activityLog.append(level: .warning, status ?? "Incomplete promotions recovered.")
      }
    } catch {
      status = "Generation recovery needs attention: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Generation recovery failed.")
    }
    reload()
  }

  private func reload() {
    do {
      generations = try store.generations(paperID: paperID)
    } catch {
      status = "Review history could not be loaded: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Review history load failed.")
    }
  }

}
