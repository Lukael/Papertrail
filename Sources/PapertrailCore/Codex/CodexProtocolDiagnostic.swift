import Foundation

enum CodexTransportProtocolError: Error {
  case terminalReconciliationFailed
}

public struct CodexProtocolDiagnostic: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case invalidUTF8
    case malformedJSON
    case recordTooLarge
    case partialRecordAtEOF
    case projectionFailure
    case journalRecordTooLarge
    case journalTooLarge
    case pipelineFailure
  }

  public let kind: Kind
  public let summary: String
  public let acceptedJournalBytes: Int

  static func classify(_ error: Error, acceptedJournalBytes: Int) -> Self {
    let kind: Kind
    let summary: String
    switch error {
    case CodexFramingError.invalidUTF8:
      kind = .invalidUTF8
      summary =
        "Codex stdout contained invalid UTF-8. The accepted journal prefix is preserved; start a new operation after checking CLI compatibility."
    case CodexFramingError.recordTooLarge:
      kind = .recordTooLarge
      summary =
        "A Codex JSONL record exceeded the 1 MiB protocol limit. The accepted journal prefix is preserved and the operation must not be resumed automatically."
    case CodexFramingError.partialRecordAtEOF:
      kind = .partialRecordAtEOF
      summary =
        "Codex stdout ended with a partial JSONL record. The accepted journal prefix is preserved; retry only as a new operation."
    case CodexEventError.invalidJSON:
      kind = .malformedJSON
      summary =
        "Codex stdout contained malformed JSON. The malformed record was rejected and the accepted journal prefix is preserved."
    case OperationJournalError.recordTooLarge:
      kind = .journalRecordTooLarge
      summary =
        "An accepted event exceeded the private journal record limit. The prior journal prefix is preserved."
    case OperationJournalError.journalTooLarge:
      kind = .journalTooLarge
      summary =
        "The private operation journal reached its 64 MiB limit. The prior journal prefix is preserved and automatic retry is unsafe."
    case is CodexProjectionError, is CodexEventError:
      kind = .projectionFailure
      summary =
        "A syntactically accepted Codex event violated the frozen projection capability mapping. The event was journaled before rejection."
    case CodexTransportProtocolError.terminalReconciliationFailed:
      kind = .pipelineFailure
      summary =
        "Codex terminal events or process exit status violated the frozen completion contract. Inspect the preserved raw journal before starting a new operation."
    default:
      kind = .pipelineFailure
      summary =
        "The Codex event pipeline failed before terminal reconciliation. The accepted journal prefix is preserved."
    }
    return .init(
      kind: kind, summary: String(summary.prefix(512)), acceptedJournalBytes: acceptedJournalBytes)
  }

  @discardableResult
  func persist(in directoryURL: URL) throws -> URL {
    let url = directoryURL.appendingPathComponent("protocol-diagnostic.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }
}

public enum CodexRetryDisposition: String, Codable, Equatable, Sendable {
  case none
  case explicitNewOperationRequired
  case explicitUserDecisionRequired
}

public struct CodexTransportPolicy: Equatable, Sendable {
  public let timeout: TimeInterval
  public let terminationGrace: TimeInterval

  public init(timeout: TimeInterval = 600, terminationGrace: TimeInterval = 2) {
    self.timeout = max(0.05, timeout)
    self.terminationGrace = max(0.05, terminationGrace)
  }
}
