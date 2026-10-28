import Foundation
import PapertrailCore
import SwiftUI

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

struct ChatLiveAssistantState: Equatable, Sendable {
  var reasoning: String?
  var response: String?
}

/// The composer's text, published apart from the controller so a keystroke re-renders only
/// the composer rather than every transcript observer.
@MainActor
final class ChatDraft: ObservableObject {
  @Published var text = ""
}

@MainActor
final class PaperChatController: ObservableObject {
  let draft = ChatDraft()
  var input: String {
    get { draft.text }
    set { draft.text = newValue }
  }
  @Published private(set) var messages: [ChatMessageRecord] = []
  @Published private(set) var isRunning = false
  @Published private(set) var isLoading = true
  @Published private(set) var isRefreshingContext = false
  // Only feeds the activity log; publishing it re-rendered the transcript for nothing.
  var status: String?
  @Published private(set) var liveAssistant: ChatLiveAssistantState?

  private let paperID: UUID
  private let store: any PaperChatStore
  private let paths: LibraryPaths
  private let runtimeRegistry: PaperChatRuntimeRegistry
  private let model: String?
  private let reasoningEffort: AgentReasoningEffort
  private let executableProvider: AgentExecutableProvider
  private let activityLog: AppActivityLog
  var onUserMessage: ((Date) -> Void)?
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var coordinator: PaperChatCoordinator?

  var isAvailable: Bool { !isLoading && !isRefreshingContext }

  #if PPR_PORTABLE_SCHEMA
    init(
      paperID: UUID, paths: LibraryPaths, store: DurableModelStore,
      runtimeRegistry: PaperChatRuntimeRegistry, model: String?,
      reasoningEffort: AgentReasoningEffort, activityLog: AppActivityLog,
      executableProvider: AgentExecutableProvider
    ) {
      self.paperID = paperID
      self.store = PortablePaperChatStore(store: store)
      self.paths = paths
      self.runtimeRegistry = runtimeRegistry
      self.model = model
      self.reasoningEffort = reasoningEffort
      self.executableProvider = executableProvider
      self.activityLog = activityLog
      reload()
    }
  #else
    init(
      paperID: UUID, paths: LibraryPaths, container: ModelContainer,
      runtimeRegistry: PaperChatRuntimeRegistry, model: String?,
      reasoningEffort: AgentReasoningEffort, activityLog: AppActivityLog,
      executableProvider: AgentExecutableProvider
    ) {
      self.paperID = paperID
      self.store = SwiftDataPaperChatStore(container: container)
      self.paths = paths
      self.runtimeRegistry = runtimeRegistry
      self.model = model
      self.reasoningEffort = reasoningEffort
      self.executableProvider = executableProvider
      self.activityLog = activityLog
      reload()
    }
  #endif

  func send() {
    let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedInput.isEmpty, !isRunning, isAvailable else { return }
    input = ""
    isRunning = true
    loadTask?.cancel()
    messages.append(
      ChatMessageRecord(
        id: UUID(), paperID: paperID, sessionID: UUID(), operationID: nil,
        role: "user", content: trimmedInput, draft: nil,
        deliveryState: "sending", createdAt: Date()))
    liveAssistant = ChatLiveAssistantState(reasoning: "Thinking…", response: nil)
    status = "Claude is answering in this paper's private session…"
    activityLog.append(level: .info, status ?? "Chat request started.")
    Task {
      var failed = false
      do {
        let coordinator = try await resolvedCoordinator()
        let result = try await coordinator.send(
          paperID: paperID, text: trimmedInput, progress: progressHandler())
        status = Self.statusText(for: result)
        activityLog.append(
          level: result.outcome == .turnCompleted ? .success : .warning,
          status ?? "Chat request completed.")
      } catch {
        failed = true
        status = "Chat failed recoverably: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Chat request failed.")
      }
      isRunning = false
      await reloadNow()
      liveAssistant = nil
      // A send that failed before the message was stored (logged out, oversized, no PDF text)
      // would otherwise lose what the user typed.
      if failed, input.isEmpty,
        !messages.contains(where: { $0.role == "user" && $0.content == trimmedInput })
      {
        input = trimmedInput
      }
    }
  }

  func cancel() {
    guard let coordinator else { return }
    Task { await coordinator.cancelCurrent(paperID: paperID) }
    status = "Cancellation requested. The message and operation record will remain recoverable."
    activityLog.append(level: .warning, status ?? "Chat cancellation requested.")
  }

  func canRetry(_ message: ChatMessageRecord) -> Bool {
    message.role == "user" && message.operationID != nil
      // The store keeps a timed-out turn's raw outcome on its message.
      && ["failed", "cancelled", "interrupted", "protocolFailure", "timedOut"]
        .contains(message.deliveryState)
      // A retry re-sends the same text; once it exists, retrying the original only duplicates it.
      && !messages.contains {
        $0.role == "user" && $0.createdAt > message.createdAt && $0.content == message.content
      }
  }

  func retry(_ message: ChatMessageRecord) {
    guard !isRunning, isAvailable, canRetry(message), let operationID = message.operationID
    else { return }
    isRunning = true
    liveAssistant = ChatLiveAssistantState(reasoning: "Thinking…", response: nil)
    status = "Retrying as a new durable operation…"
    activityLog.append(level: .info, status ?? "Chat retry started.")
    Task {
      do {
        let coordinator = try await resolvedCoordinator()
        let result = try await coordinator.retry(
          paperID: paperID, failedOperationID: operationID, text: message.content,
          progress: progressHandler())
        status = Self.statusText(for: result)
        activityLog.append(level: .success, status ?? "Chat retry completed.")
      } catch {
        status = "Retry failed recoverably: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Chat retry failed.")
      }
      isRunning = false
      await reloadNow()
      liveAssistant = nil
    }
  }

  func refreshContext() {
    guard !isRunning, isAvailable else { return }
    isRefreshingContext = true
    Task {
      defer { isRefreshingContext = false }
      do {
        let coordinator = try await resolvedCoordinator()
        _ = try await coordinator.refreshContext(paperID: paperID)
        status = "Created a replacement context while preserving historical lineage."
        activityLog.append(level: .success, status ?? "Chat context refreshed.")
      } catch {
        status = "Context refresh failed; the prior session remains authoritative: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Chat context refresh failed.")
      }
      await reloadNow()
    }
  }

  private func reload() {
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      await self?.reloadNow()
    }
  }

  private func reloadNow() async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    let store = store
    let paperID = paperID
    do {
      // Each adapter owns its context/lock. Only value records cross back to UI.
      let loaded = try await Task.detached(priority: .userInitiated) {
        try store.messages(paperID: paperID)
      }.value
      guard !Task.isCancelled, generation == loadGeneration else { return }
      messages = loaded
      if let latestUserDate = loaded.last(where: { $0.role == "user" })?.createdAt {
        onUserMessage?(latestUserDate)
      }
    } catch {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      status = "Stored chat could not be loaded: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Stored chat load failed.")
    }
  }

  private func progressHandler() -> @Sendable (AgentLiveProgress) -> Void {
    { [weak self] update in
      // Chat turns do not request partial messages; ignore any stray deltas.
      guard update.kind != .draft else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        var live = self.liveAssistant ?? ChatLiveAssistantState()
        switch update.kind {
        case .status:
          self.status = update.text
        case .reasoning:
          live.reasoning = update.text
          self.liveAssistant = live
        case .response:
          live.response = update.text
          self.liveAssistant = live
        case .draft:
          break
        }
        self.activityLog.upsert(
          key: "chat-\(update.itemID ?? update.kind.rawValue)", source: .agent,
          message: update.text)
      }
    }
  }

  private func resolvedCoordinator() async throws -> PaperChatCoordinator {
    if let coordinator { return coordinator }
    let executable = try await executableProvider.executableURL()
    let resolved = PaperChatCoordinator(
      store: store, paths: paths, executableURL: executable,
      model: model, reasoningEffort: reasoningEffort, runtimeRegistry: runtimeRegistry)
    coordinator = resolved
    return resolved
  }

  static func statusText(for result: ChatTurnResult) -> String {
    let message = ChatOutcomePresentation.message(
      outcome: result.outcome, replacementCompleted: result.replacementSessionID != nil)
    return result.failureDetail.map { "\(message) Claude Code: \($0)" } ?? message
  }
}
