import CryptoKit
import Foundation

public enum ImmutableFileStoreError: Error, Equatable {
  case destinationExists(String)
  case destinationOutsideLibrary(String)
  case sourceIsNotRegularFile(String)
  case symbolicLinkRejected(String)
  case verificationFailed(String)
  case sourceChanged(String)
  case sourceTooLarge(Int64, maximum: Int64)
}

public struct ImmutableWriteReceipt: Equatable, Sendable {
  public let relativePath: String
  public let sha256: String
  public let byteCount: Int
}

public struct ImmutableFileStore: Sendable {
  public let paths: LibraryPaths

  public init(paths: LibraryPaths) { self.paths = paths }

  public func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws
    -> ImmutableWriteReceipt
  {
    let relative = try paths.relativePath(for: destination)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ImmutableFileStoreError.destinationExists(relative)
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".partial-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.withoutOverwriting])
    try fileManager.moveItem(at: temporary, to: destination)
    let stored = try Data(contentsOf: destination)
    guard stored == data else { throw ImmutableFileStoreError.verificationFailed(relative) }
    return ImmutableWriteReceipt(
      relativePath: relative, sha256: Self.sha256(stored), byteCount: stored.count)
  }

  public func copy(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws
    -> ImmutableWriteReceipt
  {
    try copy(source, to: destination, maximumByteCount: .max, fileManager: fileManager)
  }

  public func copy(
    _ source: URL, to destination: URL, maximumByteCount: Int64,
    fileManager: FileManager = .default
  ) throws -> ImmutableWriteReceipt {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw ImmutableFileStoreError.symbolicLinkRejected(source.path)
    }
    guard values.isRegularFile == true else {
      throw ImmutableFileStoreError.sourceIsNotRegularFile(source.path)
    }
    let sourceSize = try Self.regularFileSize(source, fileManager: fileManager)
    guard sourceSize <= maximumByteCount else {
      throw ImmutableFileStoreError.sourceTooLarge(sourceSize, maximum: maximumByteCount)
    }
    let sourceHashBefore = try Self.sha256(fileAt: source, maximumByteCount: maximumByteCount)
    let relative = try paths.relativePath(for: destination)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ImmutableFileStoreError.destinationExists(relative)
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".partial-import-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: temporary) }

    guard
      fileManager.createFile(
        atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: temporary)
    defer {
      try? input.close()
      try? output.close()
    }
    var copied = 0
    var copiedHash = SHA256()
    while true {
      let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      copied += chunk.count
      guard Int64(copied) <= maximumByteCount else {
        throw ImmutableFileStoreError.sourceTooLarge(Int64(copied), maximum: maximumByteCount)
      }
      copiedHash.update(data: chunk)
      try output.write(contentsOf: chunk)
    }
    try output.synchronize()
    try output.close()
    let stagedHash = copiedHash.finalize().map { String(format: "%02x", $0) }.joined()
    let sourceHashAfter = try Self.sha256(fileAt: source, maximumByteCount: maximumByteCount)
    guard sourceHashBefore.sha256 == sourceHashAfter.sha256,
      sourceHashAfter.byteCount == copied,
      stagedHash == sourceHashAfter.sha256
    else { throw ImmutableFileStoreError.sourceChanged(source.path) }
    let verifiedStaged = try Self.sha256(fileAt: temporary, maximumByteCount: maximumByteCount)
    guard verifiedStaged.sha256 == stagedHash, verifiedStaged.byteCount == copied else {
      throw ImmutableFileStoreError.verificationFailed(relative)
    }
    try fileManager.moveItem(at: temporary, to: destination)
    let destinationHash = try Self.sha256(fileAt: destination, maximumByteCount: maximumByteCount)
    guard destinationHash == verifiedStaged else {
      try? fileManager.removeItem(at: destination)
      throw ImmutableFileStoreError.verificationFailed(relative)
    }
    return ImmutableWriteReceipt(relativePath: relative, sha256: stagedHash, byteCount: copied)
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256(fileAt url: URL, maximumByteCount: Int64 = .max) throws
    -> (sha256: String, byteCount: Int)
  {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var digest = SHA256()
    var count = 0
    while true {
      let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      count += chunk.count
      guard Int64(count) <= maximumByteCount else {
        throw ImmutableFileStoreError.sourceTooLarge(Int64(count), maximum: maximumByteCount)
      }
      digest.update(data: chunk)
    }
    return (
      digest.finalize().map { String(format: "%02x", $0) }.joined(),
      count
    )
  }

  private static func regularFileSize(_ url: URL, fileManager: FileManager) throws -> Int64 {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }
}
