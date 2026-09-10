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

@MainActor
final class PaperChatController: ObservableObject {
  @Published var input = ""
  @Published private(set) var messages: [ChatMessageRecord] = []
  @Published private(set) var isRunning = false
  @Published var status: String?
  @Published private(set) var liveAssistant: ChatLiveAssistantState?
  @Published private(set) var liveRevision = 0

  private let paperID: UUID
  private let store: any PaperChatStore
  private let paths: LibraryPaths
  private let runtimeRegistry: PaperChatRuntimeRegistry
  private let model: String?
  private let reasoningEffort: CodexReasoningEffort
  private let executableProvider: CodexExecutableProvider
  private let activityLog: AppActivityLog
  private var coordinator: PaperChatCoordinator?

  var isAvailable: Bool { true }

  #if PPR_PORTABLE_SCHEMA
    init(
      paperID: UUID, paths: LibraryPaths, store: DurableModelStore,
      runtimeRegistry: PaperChatRuntimeRegistry, model: String?,
      reasoningEffort: CodexReasoningEffort, activityLog: AppActivityLog,
      executableProvider: CodexExecutableProvider
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
      reasoningEffort: CodexReasoningEffort, activityLog: AppActivityLog,
      executableProvider: CodexExecutableProvider
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
    guard !trimmedInput.isEmpty, !isRunning else { return }
    input = ""
    isRunning = true
    messages.append(
      ChatMessageRecord(
        id: UUID(), paperID: paperID, sessionID: UUID(), operationID: nil,
        role: "user", content: trimmedInput, draft: nil,
        deliveryState: "sending", createdAt: Date()))
    liveAssistant = ChatLiveAssistantState(reasoning: "Thinking…", response: nil)
    liveRevision += 1
    status = "Codex is answering in this paper's private session…"
    activityLog.append(level: .info, status ?? "Chat request started.")
    Task {
      do {
        let coordinator = try await resolvedCoordinator()
        let result = try await coordinator.send(
          paperID: paperID, text: trimmedInput, progress: progressHandler())
        status = Self.statusText(for: result)
        activityLog.append(
          level: result.outcome == .turnCompleted ? .success : .warning,
          status ?? "Chat request completed.")
      } catch {
        status = "Chat failed recoverably: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Chat request failed.")
      }
      isRunning = false
      reloadNow()
      liveAssistant = nil
      liveRevision += 1
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
      && ["failed", "cancelled", "interrupted", "protocolFailure"]
        .contains(message.deliveryState)
  }

  func retry(_ message: ChatMessageRecord) {
    guard !isRunning, canRetry(message), let operationID = message.operationID
    else { return }
    isRunning = true
    liveAssistant = ChatLiveAssistantState(reasoning: "Thinking…", response: nil)
    liveRevision += 1
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
      reloadNow()
      liveAssistant = nil
      liveRevision += 1
    }
  }

  func refreshContext() {
    guard !isRunning else { return }
    Task {
      do {
        let coordinator = try await resolvedCoordinator()
        _ = try await coordinator.refreshContext(paperID: paperID)
        status = "Created a replacement context while preserving historical lineage."
        activityLog.append(level: .success, status ?? "Chat context refreshed.")
      } catch {
        status = "Context refresh failed; the prior session remains authoritative: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Chat context refresh failed.")
      }
      reload()
    }
  }

  private func reload() {
    Task {
      do {
        messages = try store.messages(paperID: paperID)
      } catch {
        status = "Stored chat could not be loaded: \(error.localizedDescription)"
        activityLog.append(level: .error, status ?? "Stored chat load failed.")
      }
    }
  }

  private func reloadNow() {
    do {
      messages = try store.messages(paperID: paperID)
    } catch {
      status = "Stored chat could not be loaded: \(error.localizedDescription)"
      activityLog.append(level: .error, status ?? "Stored chat load failed.")
    }
  }

  private func progressHandler() -> @Sendable (CodexLiveProgress) -> Void {
    { [weak self] update in
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
        }
        self.liveRevision += 1
        self.activityLog.upsert(
          key: "chat-\(update.itemID ?? update.kind.rawValue)", source: .codex,
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
    ChatOutcomePresentation.message(
      outcome: result.outcome, replacementCompleted: result.replacementSessionID != nil)
  }
}
