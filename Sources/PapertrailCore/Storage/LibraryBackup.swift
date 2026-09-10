import Foundation

public enum LibraryBackupError: Error, Equatable {
  case sourceMissing
  case destinationExists(String)
  case symbolicLinkRejected(String)
  case unsupportedItem(String)
  case unsafePath(String)
  case invalidManifest
  case duplicateEntry(String)
  case unexpectedPayloadItem(String)
  case verificationFailed(String)
}

public struct LibraryBackupEntry: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sha256: String
  public let byteCount: Int

  public init(relativePath: String, sha256: String, byteCount: Int) {
    self.relativePath = relativePath
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

public struct LibraryBackupManifest: Codable, Equatable, Sendable {
  public let format: String
  public let version: Int
  public let entries: [LibraryBackupEntry]

  public init(entries: [LibraryBackupEntry]) {
    self.format = "PERSONAL_PAPER_REVIEW_BACKUP"
    self.version = 1
    self.entries = entries
  }
}

public struct LibraryBackupReceipt: Equatable, Sendable {
  public let entryCount: Int
  public let byteCount: Int
  public let manifestSHA256: String
}

/// Creates and restores verified, immutable private-local snapshots.
///
/// Restore is intentionally fail-closed: the destination library must not exist, every payload
/// byte is verified before staging, and the staged tree is atomically moved into place only after
/// a second verification pass. This API never merges with or overwrites a live library.
public struct LibraryBackup: Sendable {
  public static let manifestName = "manifest.json"
  public static let payloadName = "payload"

  public init() {}

  public func export(
    libraryRoot: URL, to destination: URL, fileManager: FileManager = .default
  ) throws -> LibraryBackupReceipt {
    guard fileManager.fileExists(atPath: libraryRoot.path) else {
      throw LibraryBackupError.sourceMissing
    }
    try rejectSymlink(libraryRoot, fileManager: fileManager)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw LibraryBackupError.destinationExists(destination.path)
    }

    let items = try regularFiles(in: libraryRoot, fileManager: fileManager)
    let staging = destination.deletingLastPathComponent()
      .appendingPathComponent(".partial-backup-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    let payload = staging.appendingPathComponent(Self.payloadName, isDirectory: true)
    try makeOwnerDirectory(payload, fileManager: fileManager)

    var entries: [LibraryBackupEntry] = []
    for (relative, source) in items {
      let before = try FileFingerprint.read(source)
      let target = payload.appendingPathComponent(relative)
      try makeOwnerDirectory(target.deletingLastPathComponent(), fileManager: fileManager)
      try fileManager.copyItem(at: source, to: target)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      let afterSource = try FileFingerprint.read(source)
      let copied = try FileFingerprint.read(target)
      guard before == afterSource, before == copied else {
        throw LibraryBackupError.verificationFailed(relative)
      }
      entries.append(
        LibraryBackupEntry(
          relativePath: relative, sha256: copied.sha256, byteCount: copied.byteCount))
    }
    entries.sort { $0.relativePath < $1.relativePath }

    let manifest = LibraryBackupManifest(entries: entries)
    let manifestData = try JSONEncoder.backupEncoder.encode(manifest)
    let manifestURL = staging.appendingPathComponent(Self.manifestName)
    try manifestData.write(to: manifestURL, options: .withoutOverwriting)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    try secureTreePermissions(staging, fileManager: fileManager)
    try fileManager.moveItem(at: staging, to: destination)
    let fingerprint = try FileFingerprint.read(destination.appendingPathComponent(Self.manifestName))
    return LibraryBackupReceipt(
      entryCount: entries.count,
      byteCount: entries.reduce(0) { $0 + $1.byteCount },
      manifestSHA256: fingerprint.sha256)
  }

  public func restore(
    from backup: URL, toApplicationSupport applicationSupport: URL,
    fileManager: FileManager = .default
  ) throws -> LibraryBackupReceipt {
    try rejectSymlink(backup, fileManager: fileManager)
    let liveRoot = LibraryPaths(applicationSupport: applicationSupport).root
    guard !fileManager.fileExists(atPath: liveRoot.path) else {
      throw LibraryBackupError.destinationExists(liveRoot.path)
    }

    let manifestURL = backup.appendingPathComponent(Self.manifestName)
    let payload = backup.appendingPathComponent(Self.payloadName, isDirectory: true)
    try requireRegularFile(manifestURL, relativePath: Self.manifestName, fileManager: fileManager)
    try rejectSymlink(payload, fileManager: fileManager)
    let manifestData = try Data(contentsOf: manifestURL)
    guard
      let manifest = try? JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData),
      manifest.format == "PERSONAL_PAPER_REVIEW_BACKUP", manifest.version == 1
    else { throw LibraryBackupError.invalidManifest }

    var expected: [String: LibraryBackupEntry] = [:]
    for entry in manifest.entries {
      try validate(relativePath: entry.relativePath)
      guard expected.updateValue(entry, forKey: entry.relativePath) == nil else {
        throw LibraryBackupError.duplicateEntry(entry.relativePath)
      }
    }
    let actual = try regularFiles(in: payload, fileManager: fileManager)
    guard Set(actual.map(\.0)) == Set(expected.keys) else {
      let unexpected = Set(actual.map(\.0)).subtracting(expected.keys).sorted().first
        ?? Set(expected.keys).subtracting(actual.map(\.0)).sorted().first ?? "payload"
      throw LibraryBackupError.unexpectedPayloadItem(unexpected)
    }
    for (relative, source) in actual {
      guard let entry = expected[relative] else {
        throw LibraryBackupError.unexpectedPayloadItem(relative)
      }
      let fingerprint = try FileFingerprint.read(source)
      guard fingerprint.sha256 == entry.sha256, fingerprint.byteCount == entry.byteCount else {
        throw LibraryBackupError.verificationFailed(relative)
      }
    }

    try makeOwnerDirectory(applicationSupport, fileManager: fileManager)
    let staging = applicationSupport.appendingPathComponent(
      ".partial-restore-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    try makeOwnerDirectory(staging, fileManager: fileManager)
    for (relative, source) in actual {
      let target = staging.appendingPathComponent(relative)
      try makeOwnerDirectory(target.deletingLastPathComponent(), fileManager: fileManager)
      try fileManager.copyItem(at: source, to: target)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      let restored = try FileFingerprint.read(target)
      guard let entry = expected[relative], restored.sha256 == entry.sha256,
        restored.byteCount == entry.byteCount
      else { throw LibraryBackupError.verificationFailed(relative) }
    }
    try secureTreePermissions(staging, fileManager: fileManager)
    try fileManager.moveItem(at: staging, to: liveRoot)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: liveRoot.path)
    let manifestFingerprint = FileFingerprint(
      sha256: ImmutableFileStore.sha256(manifestData), byteCount: manifestData.count)
    return LibraryBackupReceipt(
      entryCount: expected.count,
      byteCount: expected.values.reduce(0) { $0 + $1.byteCount },
      manifestSHA256: manifestFingerprint.sha256)
  }

  private func regularFiles(
    in root: URL, fileManager: FileManager
  ) throws -> [(String, URL)] {
    var enumerationError: Error?
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        options: [], errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else { throw LibraryBackupError.sourceMissing }
    var result: [(String, URL)] = []
    while let item = enumerator.nextObject() as? URL {
      let relative = try lexicalRelativePath(item, root: root)
      let values = try item.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw LibraryBackupError.symbolicLinkRejected(relative)
      }
      if values.isRegularFile == true {
        result.append((relative, item))
      } else if values.isDirectory != true {
        throw LibraryBackupError.unsupportedItem(relative)
      }
    }
    if enumerationError != nil { throw LibraryBackupError.verificationFailed(root.path) }
    return result.sorted { $0.0 < $1.0 }
  }

  private func lexicalRelativePath(_ item: URL, root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let itemPath = item.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard itemPath.hasPrefix(prefix) else { throw LibraryBackupError.unsafePath(item.path) }
    let relative = String(itemPath.dropFirst(prefix.count))
    try validate(relativePath: relative)
    return relative
  }

  private func validate(relativePath: String) throws {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
      throw LibraryBackupError.unsafePath(relativePath)
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw LibraryBackupError.unsafePath(relativePath)
    }
  }

  private func rejectSymlink(_ url: URL, fileManager: FileManager) throws {
    guard fileManager.fileExists(atPath: url.path) else { throw LibraryBackupError.sourceMissing }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw LibraryBackupError.symbolicLinkRejected(url.path)
    }
  }

  private func requireRegularFile(
    _ url: URL, relativePath: String, fileManager: FileManager
  ) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw LibraryBackupError.symbolicLinkRejected(relativePath)
    }
    guard values.isRegularFile == true else {
      throw LibraryBackupError.unsupportedItem(relativePath)
    }
  }

  private func makeOwnerDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func secureTreePermissions(_ root: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])
    else { throw LibraryBackupError.verificationFailed(root.path) }
    while let item = enumerator.nextObject() as? URL {
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values.isDirectory == true {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
      } else if values.isRegularFile == true {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.path)
      }
    }
  }
}

private extension JSONEncoder {
  static var backupEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
