import Darwin
import Foundation

public enum PaperTagStoreError: Error, Equatable, LocalizedError, Sendable {
  case paperDirectoryMissing(UUID)
  case unsafePaperDirectory(UUID)
  case unsafeTagFile(UUID)
  case invalidSchemaVersion(Int)
  case tooManyTags(actual: Int, maximum: Int)
  case tagTooLong(String, maximumCharacters: Int)
  case fileSystemError(Int32)

  public var errorDescription: String? {
    switch self {
    case .paperDirectoryMissing:
      "The paper directory no longer exists."
    case .unsafePaperDirectory:
      "The paper directory is not a regular directory."
    case .unsafeTagFile:
      "The paper tag file is not a regular file."
    case .invalidSchemaVersion(let version):
      "The paper tag file uses unsupported schema version \(version)."
    case .tooManyTags(let actual, let maximum):
      "A paper can have at most \(maximum) tags; \(actual) were provided."
    case .tagTooLong(let tag, let maximumCharacters):
      "The tag “\(tag)” exceeds the \(maximumCharacters)-character limit."
    case .fileSystemError(let code):
      "The paper tag file could not be saved (error \(code))."
    }
  }
}

/// Stores tags beside each paper without coupling tag edits to the persistent model schema.
public struct PaperTagStore: Sendable {
  public static let maximumTagCount = 32
  public static let maximumTagCharacterCount = 64

  public let paths: LibraryPaths

  public init(paths: LibraryPaths) {
    self.paths = paths
  }

  /// Returns an empty list when no sidecar has been created for the paper.
  public func load(paperID: UUID) throws -> [String] {
    let fileURL = try tagFileURL(paperID: paperID)
    var status = stat()
    guard lstat(fileURL.path, &status) == 0 else {
      if errno == ENOENT { return [] }
      throw PaperTagStoreError.fileSystemError(errno)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw PaperTagStoreError.unsafeTagFile(paperID)
    }

    let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
    guard payload.schemaVersion == 1 else {
      throw PaperTagStoreError.invalidSchemaVersion(payload.schemaVersion)
    }
    return try Self.normalize(payload.tags)
  }

  /// Trims tags, ignores blank entries, and keeps the first spelling of case-insensitive duplicates.
  /// Validation finishes before the existing sidecar is replaced.
  @discardableResult
  public func save(_ tags: [String], paperID: UUID) throws -> [String] {
    let normalized = try Self.normalize(tags)
    let paperDirectory = try paperDirectoryURL(paperID: paperID)
    try requireExistingPaperDirectory(paperDirectory, paperID: paperID)
    let fileURL = try tagFileURL(paperID: paperID)
    try requireSafeExistingTagFileIfPresent(fileURL, paperID: paperID)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Payload(schemaVersion: 1, tags: normalized))
    let temporaryURL = paperDirectory.appendingPathComponent(
      ".tags-\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

    let descriptor = Darwin.open(temporaryURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PaperTagStoreError.fileSystemError(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw PaperTagStoreError.fileSystemError(errno)
    }
    guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
      throw PaperTagStoreError.fileSystemError(errno)
    }

    // The rename is the commit point. Directory syncing improves crash durability, but a failure
    // after that point must not report the save as failed because the new tags are already visible.
    let directoryDescriptor = Darwin.open(
      paperDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if directoryDescriptor >= 0 {
      _ = Darwin.fsync(directoryDescriptor)
      Darwin.close(directoryDescriptor)
    }
    return normalized
  }

  private struct Payload: Codable {
    let schemaVersion: Int
    let tags: [String]
  }

  private func paperDirectoryURL(paperID: UUID) throws -> URL {
    try paths.url(
      forRelativePath: "Papers/\(paperID.uuidString.lowercased())")
  }

  private func tagFileURL(paperID: UUID) throws -> URL {
    try paths.url(
      forRelativePath: "Papers/\(paperID.uuidString.lowercased())/tags.json")
  }

  private func requireExistingPaperDirectory(_ url: URL, paperID: UUID) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      if errno == ENOENT { throw PaperTagStoreError.paperDirectoryMissing(paperID) }
      throw PaperTagStoreError.fileSystemError(errno)
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
      throw PaperTagStoreError.unsafePaperDirectory(paperID)
    }
  }

  private func requireSafeExistingTagFileIfPresent(_ url: URL, paperID: UUID) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      if errno == ENOENT { return }
      throw PaperTagStoreError.fileSystemError(errno)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw PaperTagStoreError.unsafeTagFile(paperID)
    }
  }

  private static func normalize(_ tags: [String]) throws -> [String] {
    var normalized: [String] = []
    var seen: Set<String> = []
    for candidate in tags {
      let tag = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !tag.isEmpty else { continue }
      guard tag.count <= maximumTagCharacterCount else {
        throw PaperTagStoreError.tagTooLong(
          tag, maximumCharacters: maximumTagCharacterCount)
      }
      let comparisonKey = tag.folding(
        options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      if seen.insert(comparisonKey).inserted { normalized.append(tag) }
    }
    guard normalized.count <= maximumTagCount else {
      throw PaperTagStoreError.tooManyTags(
        actual: normalized.count, maximum: maximumTagCount)
    }
    return normalized
  }
}
