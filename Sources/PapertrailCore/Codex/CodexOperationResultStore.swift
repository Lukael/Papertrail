import Darwin
import Foundation

public enum CodexTerminationReason: String, Codable, Equatable, Sendable {
  case exit
  case uncaughtSignal

  public init(_ reason: Process.TerminationReason) {
    switch reason {
    case .exit: self = .exit
    case .uncaughtSignal: self = .uncaughtSignal
    @unknown default: self = .uncaughtSignal
    }
  }

  public var processValue: Process.TerminationReason {
    switch self {
    case .exit: return .exit
    case .uncaughtSignal: return .uncaughtSignal
    }
  }
}

public struct CodexOperationResultV1: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let operationID: UUID
  public let journalByteCount: Int
  public let outcome: CodexOperationOutcome
  public let terminalEvent: String?
  public let exitStatus: Int32
  public let terminationReason: CodexTerminationReason
  public let retryDisposition: CodexRetryDisposition

  public init(
    operationID: UUID, journalByteCount: Int, state: CodexProjectedState, exitStatus: Int32,
    terminationReason: CodexTerminationReason,
    retryDisposition: CodexRetryDisposition = .none
  ) {
    schemaVersion = 1
    self.operationID = operationID
    self.journalByteCount = journalByteCount
    outcome = state.outcome
    terminalEvent = state.terminalEvents.last
    self.exitStatus = exitStatus
    self.terminationReason = terminationReason
    self.retryDisposition = retryDisposition
  }
}

public enum CodexOperationResultStoreError: Error, Equatable {
  case invalidResult
  case resultTooLarge
  case unsafeResult
  case resultIO(Int32)
}

public struct CodexOperationResultStore: Sendable {
  public static let boundedDefault = 2_097_152

  public let directoryURL: URL
  public let resultURL: URL
  private let maximumBytes: Int

  public init(directoryURL: URL, maximumBytes: Int = Self.boundedDefault) {
    self.directoryURL = directoryURL
    resultURL = directoryURL.appendingPathComponent("operation-result.json")
    self.maximumBytes = maximumBytes
  }

  public func write(_ result: CodexOperationResultV1) throws {
    guard result.schemaVersion == 1, result.journalByteCount >= 0, maximumBytes > 0 else {
      throw CodexOperationResultStoreError.invalidResult
    }
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(directoryURL.path, 0o700) == 0 else {
      throw CodexOperationResultStoreError.resultIO(errno)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(result)
    guard data.count <= maximumBytes else {
      throw CodexOperationResultStoreError.resultTooLarge
    }
    let temporaryURL = directoryURL.appendingPathComponent(
      ".operation-result-\(UUID().uuidString.lowercased()).tmp")
    let descriptor = Darwin.open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CodexOperationResultStoreError.resultIO(errno) }
    var shouldRemoveTemporary = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw CodexOperationResultStoreError.resultIO(errno)
        }
        guard written > 0 else { throw CodexOperationResultStoreError.resultIO(EIO) }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CodexOperationResultStoreError.resultIO(errno)
    }
    guard Darwin.rename(temporaryURL.path, resultURL.path) == 0 else {
      throw CodexOperationResultStoreError.resultIO(errno)
    }
    shouldRemoveTemporary = false
    let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else { throw CodexOperationResultStoreError.resultIO(errno) }
    defer { Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw CodexOperationResultStoreError.resultIO(errno)
    }
  }

  public func read(
    expectedOperationID: UUID, expectedJournalByteCount: Int
  ) throws -> CodexOperationResultV1? {
    guard FileManager.default.fileExists(atPath: resultURL.path) else { return nil }
    var status = stat()
    guard lstat(resultURL.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1, status.st_uid == geteuid(), status.st_size >= 0,
      status.st_size <= maximumBytes
    else { throw CodexOperationResultStoreError.unsafeResult }
    let data = try Data(contentsOf: resultURL, options: [.mappedIfSafe])
    guard data.count <= maximumBytes,
      let result = try? JSONDecoder().decode(CodexOperationResultV1.self, from: data),
      result.schemaVersion == 1, result.operationID == expectedOperationID,
      result.journalByteCount == expectedJournalByteCount,
      result.outcome != .running
    else { throw CodexOperationResultStoreError.invalidResult }
    return result
  }
}
