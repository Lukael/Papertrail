import CryptoKit
import Darwin
import Foundation
import PDFKit

public enum PDFExtractedTextCacheError: Error, Equatable, LocalizedError, Sendable {
  case invalidSourceSHA256
  case sourceOutsidePaper
  case sourceNotRegularFile
  case sourceTooLarge(Int64, maximum: Int64)
  case sourceHashMismatch(expected: String, actual: String)
  case unreadablePDF
  case lockedPDF
  case unsupportedPageCount(Int)
  case missingPage(Int)
  case extractedTextTooLarge(Int, maximum: Int)
  case insufficientExtractableText(documentScalars: Int, largestPageScalars: Int)
  case cacheLockFailed(Int32)
  case cacheInvalid(String)
  case cacheWriteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSourceSHA256:
      "The stored source SHA-256 is not a lowercase hexadecimal digest."
    case .sourceOutsidePaper:
      "The PDF source is outside the paper's app-owned source directory."
    case .sourceNotRegularFile:
      "The PDF source is not a regular, non-symbolic-link file."
    case .sourceTooLarge(let actual, let maximum):
      "The PDF source is \(actual) bytes; the supported maximum is \(maximum) bytes."
    case .sourceHashMismatch(let expected, let actual):
      "The PDF source SHA-256 is \(actual), but the durable record expects \(expected)."
    case .unreadablePDF:
      "The stored PDF could not be opened for text extraction."
    case .lockedPDF:
      "The stored PDF is locked and cannot be extracted."
    case .unsupportedPageCount(let count):
      "The PDF has \(count) pages; supported documents contain 1 through 1000 pages."
    case .missingPage(let pageIndex):
      "PDF page \(pageIndex) could not be read."
    case .extractedTextTooLarge(let actual, let maximum):
      "The extracted text is \(actual) bytes; the supported maximum is \(maximum) bytes."
    case .insufficientExtractableText(let documentScalars, let largestPageScalars):
      "The PDF does not contain enough extractable text (document: \(documentScalars), largest page: \(largestPageScalars) non-whitespace Unicode scalars)."
    case .cacheLockFailed(let code):
      "The extracted-text cache lock failed with errno \(code)."
    case .cacheInvalid(let path):
      "The extracted-text cache failed integrity validation at \(path)."
    case .cacheWriteFailed(let path):
      "The extracted-text cache could not be finalized at \(path)."
    }
  }
}

public struct PDFExtractedTextPageManifest: Codable, Equatable, Sendable {
  public let pageIndex: Int
  public let byteOffset: Int
  public let byteCount: Int
  public let nonWhitespaceScalarCount: Int

  public init(
    pageIndex: Int, byteOffset: Int, byteCount: Int, nonWhitespaceScalarCount: Int
  ) {
    self.pageIndex = pageIndex
    self.byteOffset = byteOffset
    self.byteCount = byteCount
    self.nonWhitespaceScalarCount = nonWhitespaceScalarCount
  }
}

public struct PDFExtractedTextManifest: Codable, Equatable, Sendable {
  public let manifestSchemaVersion: Int
  public let extractorSchemaVersion: Int
  public let sourceSHA256: String
  public let pageCount: Int
  public let textSHA256: String
  public let textByteCount: Int
  public let createdAt: Date
  public let pages: [PDFExtractedTextPageManifest]

  public init(
    manifestSchemaVersion: Int, extractorSchemaVersion: Int, sourceSHA256: String,
    pageCount: Int, textSHA256: String, textByteCount: Int, createdAt: Date,
    pages: [PDFExtractedTextPageManifest]
  ) {
    self.manifestSchemaVersion = manifestSchemaVersion
    self.extractorSchemaVersion = extractorSchemaVersion
    self.sourceSHA256 = sourceSHA256
    self.pageCount = pageCount
    self.textSHA256 = textSHA256
    self.textByteCount = textByteCount
    self.createdAt = createdAt
    self.pages = pages
  }
}

/// A source-identity artifact that can be shared by review generation and paper chat.
/// The URL is returned only after the manifest, source identity, text hash, byte count,
/// page boundaries, usability thresholds, and read-only permissions have been verified.
public struct VerifiedPDFExtractedText: Equatable, Sendable {
  public let cacheDirectoryURL: URL
  public let textURL: URL
  public let manifestURL: URL
  public let manifest: PDFExtractedTextManifest

  public init(
    cacheDirectoryURL: URL, textURL: URL, manifestURL: URL,
    manifest: PDFExtractedTextManifest
  ) {
    self.cacheDirectoryURL = cacheDirectoryURL
    self.textURL = textURL
    self.manifestURL = manifestURL
    self.manifest = manifest
  }

  public func readText() throws -> String {
    let data = try Data(
      contentsOf: textURL, options: [.mappedIfSafe, .uncached])
    guard data.count == manifest.textByteCount,
      ImmutableFileStore.sha256(data) == manifest.textSHA256,
      let text = String(data: data, encoding: .utf8)
    else {
      throw PDFExtractedTextCacheError.cacheInvalid(textURL.path)
    }
    return text
  }

  public func readPages() throws -> [String] {
    let data = try Data(
      contentsOf: textURL, options: [.mappedIfSafe, .uncached])
    guard data.count == manifest.textByteCount,
      ImmutableFileStore.sha256(data) == manifest.textSHA256
    else {
      throw PDFExtractedTextCacheError.cacheInvalid(textURL.path)
    }
    return try manifest.pages.map { page in
      guard page.byteOffset >= 0, page.byteCount >= 0,
        page.byteOffset <= data.count,
        page.byteCount <= data.count - page.byteOffset,
        let value = String(
          data: data.subdata(
            in: page.byteOffset..<(page.byteOffset + page.byteCount)),
          encoding: .utf8)
      else { throw PDFExtractedTextCacheError.cacheInvalid(textURL.path) }
      return value
    }
  }
}

public struct PDFExtractedTextCache: Sendable {
  public static let manifestSchemaVersion = 1
  public static let currentExtractorSchemaVersion = 1
  public static let maximumSourceByteCount: Int64 = 512 * 1_024 * 1_024
  public static let maximumTextByteCount = 64 * 1_024 * 1_024
  public static let maximumManifestByteCount = 1 * 1_024 * 1_024
  public static let maximumPageCount = 1_000
  public static let minimumDocumentNonWhitespaceScalars = 512
  public static let minimumPageNonWhitespaceScalars = 128

  public let paths: LibraryPaths
  public let extractorSchemaVersion: Int

  public init(
    paths: LibraryPaths,
    extractorSchemaVersion: Int = PDFExtractedTextCache.currentExtractorSchemaVersion
  ) {
    precondition(extractorSchemaVersion > 0)
    self.paths = paths
    self.extractorSchemaVersion = extractorSchemaVersion
  }

  /// Resolves a verified cache entry. PDFKit is invoked only when the matching entry is absent
  /// or invalid. Invalid derived data is rebuilt from the authoritative stored PDF.
  public func resolve(
    paperID: UUID, sourceURL: URL, expectedSourceSHA256: String,
    fileManager: FileManager = .default
  ) throws -> VerifiedPDFExtractedText {
    guard Self.isValidSHA256(expectedSourceSHA256) else {
      throw PDFExtractedTextCacheError.invalidSourceSHA256
    }
    let sourceRoot = paths.sourceDirectory(paperID: paperID)
    do {
      _ = try SecurePathContainment.requireExisting(sourceURL, inside: sourceRoot)
    } catch {
      throw PDFExtractedTextCacheError.sourceOutsidePaper
    }
    let sourceValues = try sourceURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw PDFExtractedTextCacheError.sourceNotRegularFile
    }
    let sourceByteCount = Int64(sourceValues.fileSize ?? 0)
    guard sourceByteCount <= Self.maximumSourceByteCount else {
      throw PDFExtractedTextCacheError.sourceTooLarge(
        sourceByteCount, maximum: Self.maximumSourceByteCount)
    }
    let sourceFingerprint = try FileFingerprint.read(
      sourceURL, maximumByteCount: Self.maximumSourceByteCount)
    guard sourceFingerprint.sha256 == expectedSourceSHA256 else {
      throw PDFExtractedTextCacheError.sourceHashMismatch(
        expected: expectedSourceSHA256, actual: sourceFingerprint.sha256)
    }

    let parent = cacheParent(paperID: paperID, sourceSHA256: expectedSourceSHA256)
    try SecurePathContainment.rejectSymlinkComponents(
      from: paths.paper(paperID), through: parent, fileManager: fileManager)
    try createOwnerOnlyCacheParents(
      paperID: paperID, sourceSHA256: expectedSourceSHA256, fileManager: fileManager)

    return try withExclusiveLock(at: lockURL(parent: parent), fileManager: fileManager) {
      let destination = cacheDirectory(parent: parent)
      if let verified = try? verify(
        directory: destination, sourceSHA256: expectedSourceSHA256,
        fileManager: fileManager)
      {
        return verified
      }

      let temporary = parent.appendingPathComponent(
        ".partial-extractor-v\(extractorSchemaVersion)-\(UUID().uuidString.lowercased())",
        isDirectory: true)
      defer {
        try? makeOwnerWritable(temporary, fileManager: fileManager)
        try? fileManager.removeItem(at: temporary)
      }
      try fileManager.createDirectory(
        at: temporary, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try extract(
        sourceURL: sourceURL, expectedSourceSHA256: expectedSourceSHA256,
        into: temporary, fileManager: fileManager)
      _ = try verify(
        directory: temporary, sourceSHA256: expectedSourceSHA256,
        fileManager: fileManager)
      try install(
        temporary: temporary, destination: destination, parent: parent,
        fileManager: fileManager)
      guard
        let verified = try? verify(
          directory: destination, sourceSHA256: expectedSourceSHA256,
          fileManager: fileManager)
      else { throw PDFExtractedTextCacheError.cacheInvalid(destination.path) }
      return verified
    }
  }

  private func extract(
    sourceURL: URL, expectedSourceSHA256: String, into directory: URL,
    fileManager: FileManager
  ) throws {
    guard let document = PDFDocument(url: sourceURL) else {
      throw PDFExtractedTextCacheError.unreadablePDF
    }
    guard !document.isLocked else { throw PDFExtractedTextCacheError.lockedPDF }
    guard (1...Self.maximumPageCount).contains(document.pageCount) else {
      throw PDFExtractedTextCacheError.unsupportedPageCount(document.pageCount)
    }

    var textData = Data()
    textData.reserveCapacity(min(Self.maximumTextByteCount, document.pageCount * 4_096))
    var pageRecords: [PDFExtractedTextPageManifest] = []
    pageRecords.reserveCapacity(document.pageCount)
    var documentScalarCount = 0
    var largestPageScalarCount = 0

    for zeroBasedIndex in 0..<document.pageCount {
      let pageIndex = zeroBasedIndex + 1
      guard let page = document.page(at: zeroBasedIndex) else {
        throw PDFExtractedTextCacheError.missingPage(pageIndex)
      }
      let pageText = page.string ?? ""
      let pageData = Data(pageText.utf8)
      let header = Data("===== PDF PAGE \(pageIndex) =====\n".utf8)
      let projectedByteCount = textData.count + header.count + pageData.count + 1
      guard projectedByteCount <= Self.maximumTextByteCount else {
        throw PDFExtractedTextCacheError.extractedTextTooLarge(
          projectedByteCount, maximum: Self.maximumTextByteCount)
      }
      textData.append(header)
      let byteOffset = textData.count
      textData.append(pageData)
      textData.append(0x0A)

      let scalarCount = Self.nonWhitespaceScalarCount(pageText)
      documentScalarCount += scalarCount
      largestPageScalarCount = max(largestPageScalarCount, scalarCount)
      pageRecords.append(
        PDFExtractedTextPageManifest(
          pageIndex: pageIndex, byteOffset: byteOffset, byteCount: pageData.count,
          nonWhitespaceScalarCount: scalarCount))
    }

    guard documentScalarCount >= Self.minimumDocumentNonWhitespaceScalars,
      largestPageScalarCount >= Self.minimumPageNonWhitespaceScalars
    else {
      throw PDFExtractedTextCacheError.insufficientExtractableText(
        documentScalars: documentScalarCount, largestPageScalars: largestPageScalarCount)
    }
    let sourceFingerprintAfter = try FileFingerprint.read(
      sourceURL, maximumByteCount: Self.maximumSourceByteCount)
    guard sourceFingerprintAfter.sha256 == expectedSourceSHA256 else {
      throw PDFExtractedTextCacheError.sourceHashMismatch(
        expected: expectedSourceSHA256, actual: sourceFingerprintAfter.sha256)
    }

    let textURL = directory.appendingPathComponent("paper-text.txt")
    try writeSynchronized(textData, to: textURL, fileManager: fileManager)
    let manifest = PDFExtractedTextManifest(
      manifestSchemaVersion: Self.manifestSchemaVersion,
      extractorSchemaVersion: extractorSchemaVersion,
      sourceSHA256: expectedSourceSHA256, pageCount: document.pageCount,
      textSHA256: ImmutableFileStore.sha256(textData), textByteCount: textData.count,
      createdAt: Date(), pages: pageRecords)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try writeSynchronized(
      try encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"),
      fileManager: fileManager)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: textURL.path)
    try fileManager.setAttributes(
      [.posixPermissions: 0o400],
      ofItemAtPath: directory.appendingPathComponent("manifest.json").path)
    try synchronizeDirectory(directory)
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  }

  private func verify(
    directory: URL, sourceSHA256: String, fileManager: FileManager
  ) throws -> VerifiedPDFExtractedText {
    let directoryValues = try directory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
      try Self.hasPermissions(0o500, at: directory, fileManager: fileManager)
    else { throw PDFExtractedTextCacheError.cacheInvalid(directory.path) }
    let inventory = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
    guard inventory == ["manifest.json", "paper-text.txt"] else {
      throw PDFExtractedTextCacheError.cacheInvalid(directory.path)
    }

    let textURL = directory.appendingPathComponent("paper-text.txt")
    let manifestURL = directory.appendingPathComponent("manifest.json")
    for file in [textURL, manifestURL] {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        try Self.hasPermissions(0o400, at: file, fileManager: fileManager)
      else { throw PDFExtractedTextCacheError.cacheInvalid(file.path) }
    }
    let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard manifestSize <= Self.maximumManifestByteCount else {
      throw PDFExtractedTextCacheError.cacheInvalid(manifestURL.path)
    }
    let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe, .uncached])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(PDFExtractedTextManifest.self, from: manifestData)
    guard manifest.manifestSchemaVersion == Self.manifestSchemaVersion,
      manifest.extractorSchemaVersion == extractorSchemaVersion,
      manifest.sourceSHA256 == sourceSHA256,
      Self.isValidSHA256(manifest.textSHA256),
      (1...Self.maximumPageCount).contains(manifest.pageCount),
      manifest.pages.count == manifest.pageCount,
      manifest.textByteCount <= Self.maximumTextByteCount
    else { throw PDFExtractedTextCacheError.cacheInvalid(manifestURL.path) }

    let textData = try Data(contentsOf: textURL, options: [.mappedIfSafe, .uncached])
    guard textData.count == manifest.textByteCount,
      ImmutableFileStore.sha256(textData) == manifest.textSHA256,
      String(data: textData, encoding: .utf8) != nil
    else { throw PDFExtractedTextCacheError.cacheInvalid(textURL.path) }
    var totalScalars = 0
    var largestPageScalars = 0
    var expectedHeaderOffset = 0
    for (zeroBasedIndex, page) in manifest.pages.enumerated() {
      let header = Data("===== PDF PAGE \(page.pageIndex) =====\n".utf8)
      let expectedPageOffset = expectedHeaderOffset + header.count
      guard page.pageIndex == zeroBasedIndex + 1,
        page.byteOffset >= 0, page.byteCount >= 0,
        page.byteOffset == expectedPageOffset,
        page.byteOffset <= textData.count,
        page.byteCount <= textData.count - page.byteOffset,
        expectedHeaderOffset <= textData.count,
        header.count <= textData.count - expectedHeaderOffset,
        textData.subdata(in: expectedHeaderOffset..<expectedPageOffset) == header,
        page.byteOffset + page.byteCount < textData.count,
        textData[page.byteOffset + page.byteCount] == 0x0A,
        let pageText = String(
          data: textData.subdata(
            in: page.byteOffset..<(page.byteOffset + page.byteCount)), encoding: .utf8)
      else { throw PDFExtractedTextCacheError.cacheInvalid(textURL.path) }
      let scalarCount = Self.nonWhitespaceScalarCount(pageText)
      guard scalarCount == page.nonWhitespaceScalarCount else {
        throw PDFExtractedTextCacheError.cacheInvalid(textURL.path)
      }
      totalScalars += scalarCount
      largestPageScalars = max(largestPageScalars, scalarCount)
      expectedHeaderOffset = page.byteOffset + page.byteCount + 1
    }
    guard expectedHeaderOffset == textData.count else {
      throw PDFExtractedTextCacheError.cacheInvalid(textURL.path)
    }
    guard totalScalars >= Self.minimumDocumentNonWhitespaceScalars,
      largestPageScalars >= Self.minimumPageNonWhitespaceScalars
    else { throw PDFExtractedTextCacheError.cacheInvalid(textURL.path) }
    return VerifiedPDFExtractedText(
      cacheDirectoryURL: directory, textURL: textURL, manifestURL: manifestURL,
      manifest: manifest)
  }

  private func install(
    temporary: URL, destination: URL, parent: URL, fileManager: FileManager
  ) throws {
    let quarantine = parent.appendingPathComponent(
      ".invalid-extractor-v\(extractorSchemaVersion)-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    let destinationExists = fileManager.fileExists(atPath: destination.path)
    if destinationExists {
      try fileManager.moveItem(at: destination, to: quarantine)
    }
    do {
      try fileManager.moveItem(at: temporary, to: destination)
      try synchronizeDirectory(parent)
      if destinationExists {
        try? makeOwnerWritable(quarantine, fileManager: fileManager)
        try? fileManager.removeItem(at: quarantine)
      }
    } catch {
      if destinationExists, !fileManager.fileExists(atPath: destination.path) {
        try? fileManager.moveItem(at: quarantine, to: destination)
      }
      throw error
    }
  }

  private func cacheParent(paperID: UUID, sourceSHA256: String) -> URL {
    paths.paper(paperID).appendingPathComponent("derived", isDirectory: true)
      .appendingPathComponent("extracted-text", isDirectory: true)
      .appendingPathComponent(sourceSHA256, isDirectory: true)
  }

  private func createOwnerOnlyCacheParents(
    paperID: UUID, sourceSHA256: String, fileManager: FileManager
  ) throws {
    let paper = paths.paper(paperID)
    let derived = paper.appendingPathComponent("derived", isDirectory: true)
    let extractedText = derived.appendingPathComponent("extracted-text", isDirectory: true)
    let sourceIdentity = extractedText.appendingPathComponent(sourceSHA256, isDirectory: true)
    for directory in [derived, extractedText, sourceIdentity] {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }

  private func cacheDirectory(parent: URL) -> URL {
    parent.appendingPathComponent("extractor-v\(extractorSchemaVersion)", isDirectory: true)
  }

  private func lockURL(parent: URL) -> URL {
    parent.appendingPathComponent(".extractor-v\(extractorSchemaVersion).lock")
  }

  private func withExclusiveLock<T>(
    at url: URL, fileManager: FileManager, body: () throws -> T
  ) throws -> T {
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw PDFExtractedTextCacheError.cacheLockFailed(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
      throw PDFExtractedTextCacheError.cacheLockFailed(errno)
    }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return try body()
  }

  private func writeSynchronized(_ data: Data, to url: URL, fileManager: FileManager) throws {
    guard
      fileManager.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw PDFExtractedTextCacheError.cacheWriteFailed(url.path) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
  }

  private func makeOwnerWritable(_ root: URL, fileManager: FileManager) throws {
    guard fileManager.fileExists(atPath: root.path) else { return }
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { return }
    if values.isDirectory == true {
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      if let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      {
        for case let item as URL in enumerator {
          let itemValues = try item.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
          ])
          guard itemValues.isSymbolicLink != true else { continue }
          try fileManager.setAttributes(
            [.posixPermissions: itemValues.isDirectory == true ? 0o700 : 0o600],
            ofItemAtPath: item.path)
        }
      }
    } else {
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
    }
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw PDFExtractedTextCacheError.cacheLockFailed(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw PDFExtractedTextCacheError.cacheLockFailed(errno)
    }
  }

  private static func nonWhitespaceScalarCount(_ value: String) -> Int {
    value.precomposedStringWithCanonicalMapping.unicodeScalars.reduce(into: 0) { count, scalar in
      if !scalar.properties.isWhitespace { count += 1 }
    }
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
          || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
      }
  }

  private static func hasPermissions(
    _ expected: Int, at url: URL, fileManager: FileManager
  ) throws -> Bool {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
    return permissions.intValue & 0o777 == expected
  }
}
