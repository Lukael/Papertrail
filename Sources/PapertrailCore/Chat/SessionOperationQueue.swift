import Foundation

public struct ChatQueueKey: Hashable, Sendable {
  public let sessionID: UUID
  public let workspacePath: String

  public init(sessionID: UUID, workspaceURL: URL) {
    self.sessionID = sessionID
    self.workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

public enum SessionOperationQueueError: Error, Equatable {
  case externalThreadMismatch(expected: String, presented: String)
}

/// FIFO serialization belongs to the internal session and its exact workspace.
/// Different keys intentionally remain concurrent (for example review generation
/// and the current paper chat).
public actor SessionOperationQueue {
  private var running = Set<ChatQueueKey>()
  private var waiters: [ChatQueueKey: [CheckedContinuation<Void, Never>]] = [:]
  private var boundThreads: [ChatQueueKey: String] = [:]

  public init() {}

  public func run<T: Sendable>(
    key: ChatQueueKey, operation: @Sendable () async throws -> T
  ) async rethrows -> T {
    await acquire(key)
    defer { release(key) }
    return try await operation()
  }

  public func run<T: Sendable>(
    key: ChatQueueKey, presentedExternalThreadID: String?,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try validate(key: key, presented: presentedExternalThreadID)
    await acquire(key)
    defer { release(key) }
    try validate(key: key, presented: presentedExternalThreadID)
    return try await operation()
  }

  public func bind(externalThreadID: String, to key: ChatQueueKey) throws {
    if let existing = boundThreads[key], existing != externalThreadID {
      throw SessionOperationQueueError.externalThreadMismatch(
        expected: existing, presented: externalThreadID)
    }
    boundThreads[key] = externalThreadID
  }

  private func validate(key: ChatQueueKey, presented: String?) throws {
    guard let expected = boundThreads[key], expected != presented else { return }
    throw SessionOperationQueueError.externalThreadMismatch(
      expected: expected, presented: presented ?? "<unbound>")
  }

  private func acquire(_ key: ChatQueueKey) async {
    if running.insert(key).inserted { return }
    await withCheckedContinuation { continuation in
      waiters[key, default: []].append(continuation)
    }
  }

  private func release(_ key: ChatQueueKey) {
    guard var pending = waiters[key], !pending.isEmpty else {
      running.remove(key)
      waiters[key] = nil
      return
    }
    let next = pending.removeFirst()
    waiters[key] = pending.isEmpty ? nil : pending
    next.resume()
  }
}

/// App-root-owned runtime state for every paper-chat coordinator. The exact
/// session/workspace key is the authority for both FIFO execution and active
/// cancellation, so transient controllers cannot create independent queues.
public actor PaperChatRuntimeRegistry {
  private let queue = SessionOperationQueue()
  private var activeOperations: [
    ChatQueueKey: (operationID: UUID, token: CodexCancellationToken)
  ] = [:]

  public init() {}

  public func run<T: Sendable>(
    key: ChatQueueKey, operationID: UUID, cancellation: CodexCancellationToken,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await queue.run(key: key) {
      try await self.runRegistered(
        key: key, operationID: operationID, cancellation: cancellation,
        operation: operation)
    }
  }

  public func bind(externalThreadID: String, to key: ChatQueueKey) async throws {
    try await queue.bind(externalThreadID: externalThreadID, to: key)
  }

  public func cancelCurrent(key: ChatQueueKey) {
    activeOperations[key]?.token.cancel()
  }

  public func cancel(operationID: UUID) {
    activeOperations.values.first(where: { $0.operationID == operationID })?.token.cancel()
  }

  private func runRegistered<T: Sendable>(
    key: ChatQueueKey, operationID: UUID, cancellation: CodexCancellationToken,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    guard activeOperations[key] == nil else {
      throw ChatStoreError.operationAlreadyRunning
    }
    activeOperations[key] = (operationID, cancellation)
    defer {
      if activeOperations[key]?.operationID == operationID {
        activeOperations[key] = nil
      }
    }
    return try await operation()
  }
}
