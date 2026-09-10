import Darwin
import Foundation

public enum OperationJournalError: Error, Equatable {
  case recordTooLarge
  case journalTooLarge
  case unsafeJournal
  case journalTampered
  case journalIO(Int32)
}

public final class OperationJournal: @unchecked Sendable {
  public static let defaultRecordLimit = 1_048_576
  public static let defaultJournalLimit = 67_108_864

  public let directoryURL: URL
  public let eventsURL: URL
  private let recordLimit: Int
  private let journalLimit: Int
  private let lock = NSLock()
  private let descriptor: Int32
  private let device: dev_t
  private let inode: ino_t
  private var byteCount: Int

  public var sizeBytes: Int { lock.withLock { byteCount } }

  public init(
    directoryURL: URL,
    recordLimit: Int = OperationJournal.defaultRecordLimit,
    journalLimit: Int = OperationJournal.defaultJournalLimit
  ) throws {
    self.directoryURL = directoryURL
    eventsURL = directoryURL.appendingPathComponent("events.jsonl")
    self.recordLimit = recordLimit
    self.journalLimit = journalLimit
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Self.requireSecureDirectory(directoryURL)
    let fd = Darwin.open(
      eventsURL.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw OperationJournalError.journalIO(errno) }
    do {
      guard Darwin.fchmod(fd, 0o600) == 0 else { throw OperationJournalError.journalIO(errno) }
      let identity = try Self.requireSecureFile(fd: fd)
      descriptor = fd
      device = identity.device
      inode = identity.inode
      byteCount = identity.size
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  deinit { Darwin.close(descriptor) }

  public func append(_ rawRecord: Data) throws {
    guard rawRecord.count <= recordLimit else { throw OperationJournalError.recordTooLarge }
    let appendedBytes = rawRecord.count + 1
    try lock.withLock {
      try verifyIdentity(expectedSize: byteCount)
      guard byteCount + appendedBytes <= journalLimit else {
        throw OperationJournalError.journalTooLarge
      }
      var record = rawRecord
      record.append(0x0A)
      try record.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(
            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw OperationJournalError.journalIO(errno)
          }
          guard written > 0 else { throw OperationJournalError.journalIO(EIO) }
          offset += written
        }
      }
      guard Darwin.fsync(descriptor) == 0 else { throw OperationJournalError.journalIO(errno) }
      byteCount += appendedBytes
      try verifyIdentity(expectedSize: byteCount)
    }
  }

  public func replay() throws -> CodexEventProjector {
    let recovered = try replayAcceptedPrefix()
    if let error = recovered.error { throw error }
    return recovered.projector
  }

  public func replayAcceptedPrefix() throws -> (projector: CodexEventProjector, error: Error?) {
    let data = try readVerifiedBytes()
    var projector = CodexEventProjector()
    var framer = CodexJSONLFramer(maximumRecordBytes: recordLimit)
    let batch = framer.consume(data)
    for raw in batch.records {
      do {
        try projector.project(CodexEvent(raw: raw))
      } catch {
        return (projector, error)
      }
    }
    if let error = batch.error { return (projector, error) }
    do {
      try framer.finish()
      return (projector, nil)
    } catch {
      return (projector, error)
    }
  }

  private func readVerifiedBytes() throws -> Data {
    try lock.withLock {
      try verifyIdentity(expectedSize: byteCount)
      var result = Data(count: byteCount)
      try result.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.pread(
            descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset)
          )
          if count < 0 {
            if errno == EINTR { continue }
            throw OperationJournalError.journalIO(errno)
          }
          guard count > 0 else { throw OperationJournalError.journalTampered }
          offset += count
        }
      }
      try verifyIdentity(expectedSize: byteCount)
      return result
    }
  }

  private func verifyIdentity(expectedSize: Int) throws {
    let identity: (device: dev_t, inode: ino_t, size: Int)
    do {
      identity = try Self.requireSecureFile(fd: descriptor)
    } catch OperationJournalError.unsafeJournal {
      throw OperationJournalError.journalTampered
    }
    guard identity.device == device, identity.inode == inode, identity.size == expectedSize else {
      throw OperationJournalError.journalTampered
    }
    var pathStatus = stat()
    guard lstat(eventsURL.path, &pathStatus) == 0, pathStatus.st_dev == device,
      pathStatus.st_ino == inode, (pathStatus.st_mode & S_IFMT) == S_IFREG,
      pathStatus.st_nlink == 1
    else { throw OperationJournalError.journalTampered }
  }

  private static func requireSecureDirectory(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_nlink >= 1
    else { throw OperationJournalError.unsafeJournal }
    guard chmod(url.path, 0o700) == 0 else { throw OperationJournalError.journalIO(errno) }
  }

  private static func requireSecureFile(fd: Int32) throws -> (
    device: dev_t, inode: ino_t, size: Int
  ) {
    var status = stat()
    guard fstat(fd, &status) == 0 else { throw OperationJournalError.journalIO(errno) }
    guard (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1,
      status.st_uid == geteuid(), status.st_size >= 0, status.st_size <= Int64(Int.max)
    else { throw OperationJournalError.unsafeJournal }
    return (status.st_dev, status.st_ino, Int(status.st_size))
  }
}
