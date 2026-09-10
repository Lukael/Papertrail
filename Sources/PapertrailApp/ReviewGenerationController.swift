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
  let reasoningEffort: CodexReasoningEffort
  private let store: any ReviewGenerationStore
  private let conversationProvider: () throws -> ReviewConversationSnapshot
  private let activityLog: AppActivityLog
  private let executableProvider: CodexExecutableProvider
  private var cancellation: CodexCancellationToken?

  #if PPR_PORTABLE_SCHEMA
    convenience init(
      paperID: UUID, paths: LibraryPaths, store: DurableModelStore, model: String?,
      reasoningEffort: CodexReasoningEffort,
      activityLog: AppActivityLog,
      executableProvider: CodexExecutableProvider
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
      reasoningEffort: CodexReasoningEffort,
      activityLog: AppActivityLog,
      executableProvider: CodexExecutableProvider
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
    reasoningEffort: CodexReasoningEffort,
    conversationProvider: @escaping () throws -> ReviewConversationSnapshot,
    activityLog: AppActivityLog,
    executableProvider: CodexExecutableProvider
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

  func generate() {
    guard !isRunning else { return }
    let conversation: ReviewConversationSnapshot
    do {
      // Capture at the button click boundary so messages sent while Codex is resolving
      // belong to the next synthesis rather than changing this one underneath it.
      conversation = try conversationProvider()
    } catch {
      status = "The conversation could not be prepared for review: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Review conversation preparation failed.")
      return
    }
    isRunning = true
    status = "Checking Codex CLI compatibility…"
    Task {
      do {
        let executable = try await executableProvider.executableURL()
        beginGeneration(conversation: conversation, executable: executable)
      } catch {
        status =
          "Codex CLI could not be resolved. Existing reviews remain readable: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Codex CLI resolution failed.")
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
    let token = CodexCancellationToken()
    cancellation = token
    let predecessor = generations.last?.id
    let service = ReviewGenerationService(paths: paths, store: store)
    let progressHandler: @Sendable (CodexLiveProgress) -> Void = { [weak self] update in
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
        activityLog.append(
          level: value.versionID == nil ? .warning : .success,
          status ?? "Review generation completed.")
      case .failure(let error):
        let failureStatus =
          "Generation stopped without replacing the selected review: \(error.localizedDescription)"
        status = failureStatus
        activityLog.append(level: .error, failureStatus)
      }
      cancellation = nil
      isRunning = false
      reload()
    }
  }

  private func appendLiveProgress(_ update: CodexLiveProgress) {
    let level: AppActivityLogLevel = update.kind == .reasoning ? .debug : .info
    if let itemID = update.itemID {
      activityLog.upsert(
        key: "review:\(paperID.uuidString):\(itemID)", source: .codex, level: level,
        message: update.text)
    } else {
      activityLog.append(source: .codex, level: level, update.text)
    }
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
