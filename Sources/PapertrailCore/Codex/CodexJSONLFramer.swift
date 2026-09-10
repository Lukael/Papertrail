import Foundation

public enum CodexFramingError: Error, Equatable {
  case recordTooLarge
  case invalidUTF8
  case partialRecordAtEOF
}

public struct CodexFramingBatch: Equatable, Sendable {
  public let records: [Data]
  public let error: CodexFramingError?
}

public struct CodexJSONLFramer: Sendable {
  public let maximumRecordBytes: Int
  private var buffer = Data()
  private var terminalError: CodexFramingError?

  public init(maximumRecordBytes: Int = 1_048_576) {
    self.maximumRecordBytes = maximumRecordBytes
  }

  /// Returns every complete valid record preceding a framing failure in the
  /// same chunk. Callers must consume `records` before handling `error`.
  public mutating func consume(_ data: Data) -> CodexFramingBatch {
    if let terminalError { return .init(records: [], error: terminalError) }
    buffer.append(data)
    var records: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var record = buffer[..<newline]
      if record.last == 0x0D { record = record.dropLast() }
      guard record.count <= maximumRecordBytes else {
        terminalError = .recordTooLarge
        return .init(records: records, error: terminalError)
      }
      guard String(data: record, encoding: .utf8) != nil else {
        terminalError = .invalidUTF8
        return .init(records: records, error: terminalError)
      }
      if !record.isEmpty { records.append(Data(record)) }
      buffer.removeSubrange(...newline)
    }
    if buffer.count > maximumRecordBytes {
      terminalError = .recordTooLarge
      return .init(records: records, error: terminalError)
    }
    return .init(records: records, error: nil)
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    let batch = consume(data)
    if let error = batch.error { throw error }
    return batch.records
  }

  public mutating func finish() throws {
    if let terminalError { throw terminalError }
    guard buffer.isEmpty else { throw CodexFramingError.partialRecordAtEOF }
  }
}
