import Darwin
@preconcurrency import Foundation
import PPRProcessSupervisor

public protocol CodexTransport: Sendable {
  func execute(
    _ invocation: CodexInvocation, journal: OperationJournal, cancellation: CodexCancellationToken
  ) throws -> CodexTransportResult
  func execute(
    _ invocation: CodexInvocation, journal: OperationJournal, cancellation: CodexCancellationToken,
    progress: (@Sendable (CodexLiveProgress) -> Void)?
  ) throws -> CodexTransportResult
}

extension CodexTransport {
  public func execute(
    _ invocation: CodexInvocation, journal: OperationJournal, cancellation: CodexCancellationToken,
    progress: (@Sendable (CodexLiveProgress) -> Void)?
  ) throws -> CodexTransportResult {
    try execute(invocation, journal: journal, cancellation: cancellation)
  }
}

public struct CodexTransportResult: Sendable {
  public let state: CodexProjectedState
  public let exitStatus: Int32
  public let terminationReason: Process.TerminationReason
  public let stderr: Data
  public let protocolDiagnostic: CodexProtocolDiagnostic?
  public let diagnosticArtifactURL: URL?
  public let retryDisposition: CodexRetryDisposition

  public init(
    state: CodexProjectedState, exitStatus: Int32,
    terminationReason: Process.TerminationReason, stderr: Data,
    protocolDiagnostic: CodexProtocolDiagnostic? = nil,
    diagnosticArtifactURL: URL? = nil, retryDisposition: CodexRetryDisposition = .none
  ) {
    self.state = state
    self.exitStatus = exitStatus
    self.terminationReason = terminationReason
    self.stderr = stderr
    self.protocolDiagnostic = protocolDiagnostic
    self.diagnosticArtifactURL = diagnosticArtifactURL
    self.retryDisposition = retryDisposition
  }
}

public final class CodexCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var process: OwnedProcessSupervisor?
  private var reason: RequestReason?
  private var terminationGrace: TimeInterval = 2

  private enum RequestReason { case user, timeout }

  public init() {}

  public var isCancellationRequested: Bool {
    lock.withLock { reason == .user }
  }

  fileprivate var isTimedOut: Bool { lock.withLock { reason == .timeout } }

  public func cancel() {
    request(.user)
  }

  fileprivate func timeOut() { request(.timeout) }

  private func request(_ requestedReason: RequestReason) {
    let running: OwnedProcessSupervisor? = lock.withLock {
      if reason == nil { reason = requestedReason }
      return process
    }
    terminateIfRunning(running)
  }

  fileprivate func register(_ process: OwnedProcessSupervisor, terminationGrace: TimeInterval) {
    let shouldTerminate = lock.withLock {
      self.process = process
      self.terminationGrace = terminationGrace
      return reason != nil
    }
    if shouldTerminate { terminateIfRunning(process) }
  }

  fileprivate func unregister() {
    lock.withLock { process = nil }
  }

  private func terminateIfRunning(_ process: OwnedProcessSupervisor?) {
    process?.requestTermination(grace: terminationGrace)
  }
}

public struct DirectProcessCodexTransport: CodexTransport, Sendable {
  private let defaultPolicy: CodexTransportPolicy

  public init(policy: CodexTransportPolicy = .init()) {
    defaultPolicy = policy
  }

  public func execute(
    _ invocation: CodexInvocation, journal: OperationJournal,
    cancellation: CodexCancellationToken = .init()
  ) throws -> CodexTransportResult {
    try execute(invocation, journal: journal, cancellation: cancellation, progress: nil)
  }

  public func execute(
    _ invocation: CodexInvocation, journal: OperationJournal,
    cancellation: CodexCancellationToken = .init(),
    progress: (@Sendable (CodexLiveProgress) -> Void)?
  ) throws -> CodexTransportResult {
    try execute(
      invocation, journal: journal, cancellation: cancellation, policy: defaultPolicy,
      progress: progress)
  }

  public func execute(
    _ invocation: CodexInvocation, journal: OperationJournal,
    cancellation: CodexCancellationToken = .init(), policy: CodexTransportPolicy,
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil
  ) throws -> CodexTransportResult {
    try CodexInvocation.validate(
      arguments: invocation.arguments, workingDirectory: invocation.workingDirectory)
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = Pipe()
    for descriptor in [
      stdout.fileHandleForReading.fileDescriptor,
      stdout.fileHandleForWriting.fileDescriptor,
      stderr.fileHandleForReading.fileDescriptor,
      stderr.fileHandleForWriting.fileDescriptor,
      stdin.fileHandleForReading.fileDescriptor,
      stdin.fileHandleForWriting.fileDescriptor,
    ] {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    }
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let projectionBox = ProjectionBox(journal: journal, progress: progress)
    let errBox = DataBox()
    let stderrErrorBox = ErrorBox()
    let process = try OwnedProcessSupervisor.spawn(
      invocation: invocation,
      environment: CodexCapabilityChecker.minimalEnvironment(),
      stdinFD: stdin.fileHandleForReading.fileDescriptor,
      stdoutFD: stdout.fileHandleForWriting.fileDescriptor,
      stderrFD: stderr.fileHandleForWriting.fileDescriptor)
    do {
      try stdin.fileHandleForReading.close()
      try stdout.fileHandleForWriting.close()
      try stderr.fileHandleForWriting.close()
    } catch {
      process.requestTermination(grace: 0)
      _ = try? process.waitForExitAndCleanOwnedGroup(grace: 0)
      try? stdin.fileHandleForWriting.close()
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      throw error
    }
    cancellation.register(process, terminationGrace: policy.terminationGrace)
    let timeoutWork = DispatchWorkItem { cancellation.timeOut() }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + policy.timeout, execute: timeoutWork)
    defer { timeoutWork.cancel() }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        while let chunk = try stdout.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
          try projectionBox.consume(chunk)
        }
        try projectionBox.finish()
      } catch {
        projectionBox.fail(error)
        process.requestTermination(grace: policy.terminationGrace)
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      var bounded = Data()
      do {
        while let chunk = try stderr.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
          if bounded.count < 1_048_576 {
            bounded.append(chunk.prefix(1_048_576 - bounded.count))
          }
        }
      } catch {
        stderrErrorBox.set(error)
        process.requestTermination(grace: policy.terminationGrace)
      }
      errBox.set(bounded)
      group.leave()
    }

    var inputError: Error?
    do {
      try stdin.fileHandleForWriting.write(contentsOf: invocation.standardInput)
      try stdin.fileHandleForWriting.close()
    } catch {
      inputError = error
      try? stdin.fileHandleForWriting.close()
      process.requestTermination(grace: policy.terminationGrace)
    }
    let termination: OwnedProcessTermination
    do {
      termination = try process.waitForExitAndCleanOwnedGroup(
        grace: policy.terminationGrace)
    } catch {
      process.requestTermination(grace: 0)
      _ = try? process.waitForExitAndCleanOwnedGroup(grace: 0)
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      cancellation.unregister()
      throw error
    }
    timeoutWork.cancel()
    let drainDeadline = DispatchTime.now() + max(0.25, min(policy.terminationGrace, 2))
    if group.wait(timeout: drainDeadline) == .timedOut {
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      if group.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
        projectionBox.fail(PipeDrainError.timedOut)
        stderrErrorBox.set(PipeDrainError.timedOut)
      }
    }
    cancellation.unregister()

    var projector = projectionBox.projector()
    projector.reconcile(
      exitStatus: termination.status,
      terminationReason: termination.reason,
      cancellationRequested: cancellation.isCancellationRequested,
      timedOut: cancellation.isTimedOut,
      framingCompleted: projectionBox.error() == nil
    )
    if let inputError, !cancellation.isCancellationRequested { throw inputError }
    if let stderrError = stderrErrorBox.get(), !cancellation.isCancellationRequested {
      throw stderrError
    }
    let diagnosticError: Error? =
      projectionBox.error()
      ?? (projector.state.outcome == .protocolFailure
        ? CodexTransportProtocolError.terminalReconciliationFailed : nil)
    let protocolDiagnostic = diagnosticError.map {
      CodexProtocolDiagnostic.classify($0, acceptedJournalBytes: journal.sizeBytes)
    }
    let diagnosticArtifactURL = try protocolDiagnostic?.persist(in: journal.directoryURL)
    let retryDisposition: CodexRetryDisposition
    switch projector.state.outcome {
    case .turnCompleted:
      retryDisposition = .none
    case .failed, .cancelled:
      retryDisposition = .explicitUserDecisionRequired
    case .timedOut, .interrupted, .protocolFailure, .running:
      retryDisposition = .explicitNewOperationRequired
    }
    return CodexTransportResult(
      state: projector.state,
      exitStatus: termination.status,
      terminationReason: termination.reason,
      stderr: errBox.get(),
      protocolDiagnostic: protocolDiagnostic,
      diagnosticArtifactURL: diagnosticArtifactURL,
      retryDisposition: retryDisposition
    )
  }
}

private struct OwnedProcessTermination {
  let status: Int32
  let reason: Process.TerminationReason
}

private enum PipeDrainError: Error {
  case timedOut
}

private final class OwnedProcessSupervisor: @unchecked Sendable {
  private let pid: pid_t
  private let pgid: pid_t
  private let lock = NSLock()
  private var terminationDeadline: UInt64?
  private var killSent = false
  private var killSentAt: UInt64?

  private init(pid: pid_t) {
    self.pid = pid
    pgid = pid
  }

  static func spawn(
    invocation: CodexInvocation,
    environment: [String: String],
    stdinFD: Int32,
    stdoutFD: Int32,
    stderrFD: Int32
  ) throws -> OwnedProcessSupervisor {
    let arguments = [invocation.executableURL.path] + invocation.arguments
    let environmentEntries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var spawnedPID: pid_t = -1
    let error = try withMutableCStringArray(arguments) { argumentPointers in
      try withMutableCStringArray(environmentEntries) { environmentPointers in
        invocation.executableURL.path.withCString { executablePointer in
          invocation.workingDirectory.path.withCString { directoryPointer in
            ppr_spawn_owned_process_group(
              executablePointer, argumentPointers, environmentPointers, directoryPointer,
              stdinFD, stdoutFD, stderrFD, &spawnedPID)
          }
        }
      }
    }
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    return OwnedProcessSupervisor(pid: spawnedPID)
  }

  func requestTermination(grace: TimeInterval) {
    let shouldSignal = lock.withLock { () -> Bool in
      let nanoseconds = UInt64(max(0, grace) * 1_000_000_000)
      let requestedDeadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
      if let currentDeadline = terminationDeadline {
        terminationDeadline = min(currentDeadline, requestedDeadline)
        return false
      }
      terminationDeadline = requestedDeadline
      return true
    }
    guard shouldSignal else { return }
    let error = ppr_signal_owned_process_group(pid, pgid, SIGTERM)
    if error != 0 && error != ESRCH {
      lock.withLock {
        terminationDeadline = DispatchTime.now().uptimeNanoseconds
      }
    }
  }

  func waitForExitAndCleanOwnedGroup(grace: TimeInterval) throws -> OwnedProcessTermination {
    while true {
      var observed: Int32 = 0
      let observeError = ppr_observe_exit(pid, &observed)
      if observeError != 0 { throw POSIXError(POSIXErrorCode(rawValue: observeError) ?? .EIO) }
      let leaderExited = observed != 0

      let now = DispatchTime.now().uptimeNanoseconds
      let deadline = lock.withLock { terminationDeadline }
      if let deadline, now >= deadline {
        let shouldKill = lock.withLock { () -> Bool in
          guard !killSent else { return false }
          killSent = true
          killSentAt = now
          return true
        }
        if shouldKill {
          let error = ppr_signal_owned_process_group(pid, pgid, SIGKILL)
          if error != 0 && error != ESRCH {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
          }
        }
      }

      if leaderExited {
        if deadline == nil {
          requestTermination(grace: min(max(0, grace), 0.05))
        } else if let killSentAt = lock.withLock({ self.killSentAt }),
          now &- killSentAt >= 100_000_000
        {
          return try reap()
        }
      }
      usleep(5_000)
    }
  }

  private func reap() throws -> OwnedProcessTermination {
    var status: Int32 = 0
    var signaled: Int32 = 0
    let error = ppr_reap_process(pid, &status, &signaled)
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    return OwnedProcessTermination(
      status: status,
      reason: signaled == 0 ? .exit : .uncaughtSignal)
  }
}

private func withMutableCStringArray<Result>(
  _ strings: [String],
  _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
  var storage: [UnsafeMutablePointer<CChar>?] = []
  for string in strings {
    guard let pointer = strdup(string) else {
      for allocated in storage { free(allocated) }
      throw POSIXError(.ENOMEM)
    }
    storage.append(pointer)
  }
  storage.append(nil)
  defer {
    for pointer in storage.dropLast() { free(pointer) }
  }
  return try storage.withUnsafeMutableBufferPointer { buffer in
    try body(buffer.baseAddress!)
  }
}

private final class DataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Data()
  func set(_ data: Data) { lock.withLock { value = data } }
  func get() -> Data { lock.withLock { value } }
}

private final class ErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Error?
  func set(_ error: Error) { lock.withLock { value = error } }
  func get() -> Error? { lock.withLock { value } }
}

private final class ProjectionBox: @unchecked Sendable {
  private let lock = NSLock()
  private let journal: OperationJournal
  private var framer = CodexJSONLFramer()
  private var eventProjector = CodexEventProjector()
  private var projectionError: Error?
  private let progress: (@Sendable (CodexLiveProgress) -> Void)?

  init(
    journal: OperationJournal,
    progress: (@Sendable (CodexLiveProgress) -> Void)? = nil
  ) {
    self.journal = journal
    self.progress = progress
  }

  func consume(_ data: Data) throws {
    let updates: [CodexLiveProgress] = try lock.withLock {
      guard projectionError == nil else { return [] }
      var updates: [CodexLiveProgress] = []
      let batch = framer.consume(data)
      for raw in batch.records {
        let event = try CodexEvent(raw: raw)
        // A syntactically accepted event is durable before any projection or
        // capability-floor validation can mutate/reject visible state.
        try journal.append(raw)
        try eventProjector.project(event)
        if let update = CodexLiveProgress.visibleUpdate(for: event) { updates.append(update) }
      }
      if let error = batch.error { throw error }
      return updates
    }
    for update in updates { progress?(update) }
  }

  func finish() throws { try lock.withLock { try framer.finish() } }
  func fail(_ error: Error) { lock.withLock { projectionError = error } }
  func projector() -> CodexEventProjector { lock.withLock { eventProjector } }
  func error() -> Error? { lock.withLock { projectionError } }
}
