import Darwin
import Foundation

public struct DurablePDFImportCoordinator: Sendable {
  public let paths: LibraryPaths
  public let policy: PDFImportPolicy

  public init(paths: LibraryPaths, policy: PDFImportPolicy = PDFImportPolicy()) {
    self.paths = paths
    self.policy = policy
  }

  public func begin(
    from sourceURL: URL, title: String, paperID: UUID = UUID(), existingPapers: [Paper]
  ) throws -> PDFImportResult {
    let importer = PDFImporter(paths: paths, policy: policy)
    _ = try importer.prepare(sourceURL)
    guard let canonicalTitle = FilenameSanitizer.displayTitle(title) else {
      throw PDFImportError.emptyTitle
    }
    let safeBasename = FilenameSanitizer.collisionProofPDFName(
      title: canonicalTitle, paperID: paperID)
    let sourceRelativePath = try paths.relativePath(
      for: paths.sourceDirectory(paperID: paperID).appendingPathComponent(safeBasename))
    guard !FileManager.default.fileExists(atPath: paths.paper(paperID).path) else {
      throw ImmutableFileStoreError.destinationExists(sourceRelativePath)
    }
    let fingerprint = try ImmutableFileStore.sha256(
      fileAt: sourceURL, maximumByteCount: policy.maximumByteCount)
    let intent = PDFImportIntent(
      paperID: paperID, canonicalTitle: canonicalTitle, safeBasename: safeBasename,
      sourceRelativePath: sourceRelativePath, sourceSHA256: fingerprint.sha256,
      byteCount: fingerprint.byteCount)
    let intentStore = PDFImportIntentStore(paths: paths)
    try intentStore.record(intent)

    do {
      let imported = try importer.importPDF(
        from: sourceURL, title: canonicalTitle, paperID: paperID,
        existingPapers: existingPapers)
      guard imported.receipt.relativePath == intent.sourceRelativePath,
        imported.receipt.sha256 == intent.sourceSHA256,
        imported.receipt.byteCount == intent.byteCount
      else {
        throw ImmutableFileStoreError.verificationFailed(intent.sourceRelativePath)
      }
      return PDFImportResult(
        paper: imported.paper, receipt: imported.receipt,
        duplicatePaperIDs: imported.duplicatePaperIDs)
    } catch {
      // Ordinary failures clean up eagerly. A crash leaves the intent for startup recovery.
      try? intentStore.removeFailedBeginArtifacts(for: intent)
      try? intentStore.complete(paperID: paperID)
      throw error
    }
  }

  public func complete(paperID: UUID) throws {
    try PDFImportIntentStore(paths: paths).complete(paperID: paperID)
  }
}

public struct PDFImportRecovery: Sendable {
  public let paths: LibraryPaths

  public init(paths: LibraryPaths) { self.paths = paths }

  public func reconcile(
    existingPapers: [Paper], commit: (Paper) throws -> Void
  ) throws -> [LibraryRecoveryIssue] {
    let store = PDFImportIntentStore(paths: paths)
    var papersByID = Dictionary(uniqueKeysWithValues: existingPapers.map { ($0.id, $0) })
    var issues = try store.cleanInvalidEntries()
    for intent in try store.intents() {
      let issuePath = store.relativeIntentPath(paperID: intent.paperID)
      if let existing = papersByID[intent.paperID] {
        if !intent.matches(existing) { issues.append(.recoverablePartial(relativePath: issuePath)) }
        try store.complete(paperID: intent.paperID)
        continue
      }
      let sourceStatus = store.finalSourceStatus(intent)
      guard sourceStatus == .matches else {
        issues.append(
          .importRecoveryPending(relativePath: issuePath, reason: sourceStatus.issueReason))
        continue
      }
      let paper = intent.makePaper()
      try commit(paper)
      papersByID[paper.id] = paper
      try store.complete(paperID: paper.id)
      issues.append(.recoverablePartial(relativePath: issuePath))
    }
    return issues
  }
}

private struct PDFImportIntent: Codable, Sendable {
  static let currentSchemaVersion = 1
  let schemaVersion: Int
  let paperID: UUID
  let canonicalTitle: String
  let safeBasename: String
  let sourceRelativePath: String
  let sourceSHA256: String
  let byteCount: Int
  // Kept optional so import intents written by versions that scheduled an automatic
  // review remain decodable during recovery. New imports never set the marker.
  let automaticReviewRequiredAt: Date?

  init(
    paperID: UUID, canonicalTitle: String, safeBasename: String, sourceRelativePath: String,
    sourceSHA256: String, byteCount: Int, automaticReviewRequiredAt: Date? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.paperID = paperID
    self.canonicalTitle = canonicalTitle
    self.safeBasename = safeBasename
    self.sourceRelativePath = sourceRelativePath
    self.sourceSHA256 = sourceSHA256
    self.byteCount = byteCount
    self.automaticReviewRequiredAt = automaticReviewRequiredAt
  }

  func makePaper() -> Paper {
    var paper = Paper(
      id: paperID, canonicalTitle: canonicalTitle, safeBasename: safeBasename,
      sourceRelativePath: sourceRelativePath, sourceSHA256: sourceSHA256)
    // Preserve the old marker if this is a legacy crash-recovery intent. The app no
    // longer consumes it, but recovery must not silently rewrite persisted history.
    paper.automaticReviewRequiredAt = automaticReviewRequiredAt
    return paper
  }

  func matches(_ paper: Paper) -> Bool {
    paper.id == paperID && paper.canonicalTitle == canonicalTitle
      && paper.safeBasename == safeBasename && paper.sourceRelativePath == sourceRelativePath
      && paper.sourceSHA256 == sourceSHA256
  }
}

private struct PDFImportIntentStore: Sendable {
  private static let maximumIntentByteCount: Int64 = 1_048_576
  let paths: LibraryPaths
  private var fileManager: FileManager { .default }

  func record(_ intent: PDFImportIntent) throws {
    try createDirectory()
    let destination = intentURL(paperID: intent.paperID)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ImmutableFileStoreError.destinationExists(relativeIntentPath(paperID: intent.paperID))
    }
    let temporary = paths.importIntentsDirectory.appendingPathComponent(
      ".partial-import-intent-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: temporary) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(intent).write(to: temporary, options: [.withoutOverwriting])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try fileManager.moveItem(at: temporary, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  func complete(paperID: UUID) throws {
    let url = intentURL(paperID: paperID)
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }

  func intents() throws -> [PDFImportIntent] {
    guard fileManager.fileExists(atPath: paths.importIntentsDirectory.path) else { return [] }
    try validateIntentDirectory()
    return try fileManager.contentsOfDirectory(
      at: paths.importIntentsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }.compactMap { url in
      guard isOwnerOnlyRegularFile(url, maximumByteCount: Self.maximumIntentByteCount) else {
        return nil
      }
      guard let data = try? Data(contentsOf: url),
        let intent = try? JSONDecoder().decode(PDFImportIntent.self, from: data)
      else { return nil }
      guard url.deletingPathExtension().lastPathComponent == intent.paperID.uuidString.lowercased(),
        isValid(intent)
      else { return nil }
      return intent
    }.sorted { $0.paperID.uuidString < $1.paperID.uuidString }
  }

  func cleanInvalidEntries() throws -> [LibraryRecoveryIssue] {
    guard fileManager.fileExists(atPath: paths.importIntentsDirectory.path) else { return [] }
    try validateIntentDirectory()
    var issues: [LibraryRecoveryIssue] = []
    for url in try fileManager.contentsOfDirectory(
      at: paths.importIntentsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) {
      let name = url.lastPathComponent
      let valid: Bool
      if name.hasPrefix(".partial-import-intent-") {
        valid = false
      } else if url.pathExtension == "json" {
        if isOwnerOnlyRegularFile(url, maximumByteCount: Self.maximumIntentByteCount),
          let data = try? Data(contentsOf: url),
          let intent = try? JSONDecoder().decode(PDFImportIntent.self, from: data)
        {
          valid =
            url.deletingPathExtension().lastPathComponent
            == intent.paperID.uuidString.lowercased() && isValid(intent)
        } else {
          valid = false
        }
      } else {
        valid = false
      }
      if !valid {
        let reason = name.hasPrefix(".partial-import-intent-") ? "partial-intent" : "invalid-intent"
        issues.append(
          .importRecoveryPending(
            relativePath: "Store/ImportIntents/\(name)", reason: reason))
      }
    }
    return issues
  }

  func finalSourceStatus(_ intent: PDFImportIntent) -> PDFImportSourceStatus {
    let paperDirectory = paths.paper(intent.paperID)
    let source = paths.sourceDirectory(paperID: intent.paperID)
    let sourceFile = source.appendingPathComponent(intent.safeBasename)
    guard entryExists(paperDirectory), entryExists(source), entryExists(sourceFile) else {
      return .missingSource
    }
    guard isOwnerOnlyDirectory(paperDirectory), isOwnerOnlyDirectory(source),
      isOwnerOnlyRegularFile(sourceFile)
    else { return .unsafeSource }
    do {
      let fingerprint = try ImmutableFileStore.sha256(
        fileAt: sourceFile, maximumByteCount: Int64(intent.byteCount))
      guard fingerprint.sha256 == intent.sourceSHA256,
        fingerprint.byteCount == intent.byteCount
      else { return .sourceMismatch }
      return .matches
    } catch {
      return .sourceVerificationFailed
    }
  }

  func removeFailedBeginArtifacts(for intent: PDFImportIntent) throws {
    let paperDirectory = paths.paper(intent.paperID)
    if entryExists(paperDirectory) {
      try fileManager.removeItem(at: paperDirectory)
    }
  }

  func relativeIntentPath(paperID: UUID) -> String {
    "Store/ImportIntents/\(paperID.uuidString.lowercased()).json"
  }

  private func intentURL(paperID: UUID) -> URL {
    paths.importIntentsDirectory.appendingPathComponent(
      "\(paperID.uuidString.lowercased()).json")
  }

  private func createDirectory() throws {
    try fileManager.createDirectory(
      at: paths.importIntentsDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try validateIntentDirectory()
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: paths.importIntentsDirectory.path)
  }

  private func validateIntentDirectory() throws {
    guard isOwnerOnlyDirectory(paths.importIntentsDirectory) else {
      throw ImmutableFileStoreError.symbolicLinkRejected(paths.importIntentsDirectory.path)
    }
  }

  private func entryExists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
  }

  private func isOwnerOnlyDirectory(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
      && status.st_uid == geteuid() && (status.st_mode & 0o077) == 0
  }

  private func isOwnerOnlyRegularFile(
    _ url: URL, maximumByteCount: Int64 = .max
  ) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
      && status.st_uid == geteuid() && status.st_nlink == 1 && (status.st_mode & 0o077) == 0
      && status.st_size >= 0 && status.st_size <= maximumByteCount
  }

  private func isValid(_ intent: PDFImportIntent) -> Bool {
    guard intent.schemaVersion == PDFImportIntent.currentSchemaVersion,
      intent.byteCount > 0,
      intent.sourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      FilenameSanitizer.displayTitle(intent.canonicalTitle) == intent.canonicalTitle,
      FilenameSanitizer.collisionProofPDFName(
        title: intent.canonicalTitle, paperID: intent.paperID) == intent.safeBasename
    else { return false }
    let expected = "Papers/\(intent.paperID.uuidString.lowercased())/source/\(intent.safeBasename)"
    return intent.sourceRelativePath == expected
  }
}

private enum PDFImportSourceStatus: Equatable {
  case matches
  case missingSource
  case unsafeSource
  case sourceMismatch
  case sourceVerificationFailed

  var issueReason: String {
    switch self {
    case .matches: return ""
    case .missingSource: return "missing-source"
    case .unsafeSource: return "unsafe-source"
    case .sourceMismatch: return "source-mismatch"
    case .sourceVerificationFailed: return "source-verification-failed"
    }
  }
}
