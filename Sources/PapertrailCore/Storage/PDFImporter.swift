import Foundation

public enum PDFImportError: Error, Equatable, LocalizedError {
  case nonFileURL
  case unsafePath(String)
  case symbolicLink(String)
  case notRegularFile(String)
  case notPDF(String)
  case emptyTitle
  case sourceTooLarge(Int64, maximum: Int64)

  public var errorDescription: String? {
    switch self {
    case .nonFileURL: return "Only local PDF files can be imported."
    case .unsafePath: return "The selected path is unsafe."
    case .symbolicLink: return "Symbolic links are not accepted for import."
    case .notRegularFile: return "The selection is not a regular file."
    case .notPDF: return "The selected file is not a readable PDF."
    case .emptyTitle: return "Enter a title before importing."
    case .sourceTooLarge(let size, let maximum):
      return "The PDF is \(size) bytes; the import limit is \(maximum) bytes."
    }
  }
}

public struct PDFImportPolicy: Equatable, Sendable {
  public var maximumByteCount: Int64
  public init(maximumByteCount: Int64 = 512 * 1024 * 1024) {
    self.maximumByteCount = maximumByteCount
  }
}

public struct PreparedPDFImport: Equatable, Sendable {
  public let sourceURL: URL
  public let extractedTitle: ExtractedPDFTitle
  public let byteCount: Int
}

public struct PDFImportResult {
  public let paper: Paper
  public let receipt: ImmutableWriteReceipt
  public let duplicatePaperIDs: [UUID]
}

public struct PDFImporter: Sendable {
  public let paths: LibraryPaths
  public let policy: PDFImportPolicy
  private let store: ImmutableFileStore

  public init(paths: LibraryPaths, policy: PDFImportPolicy = PDFImportPolicy()) {
    self.paths = paths
    self.policy = policy
    self.store = ImmutableFileStore(paths: paths)
  }

  public func prepare(_ sourceURL: URL) throws -> PreparedPDFImport {
    let size = try validateSource(sourceURL)
    return PreparedPDFImport(
      sourceURL: sourceURL,
      extractedTitle: try PDFTitleExtractor().extract(from: sourceURL),
      byteCount: Int(size))
  }

  public func importPDF(
    from sourceURL: URL, title requestedTitle: String, paperID: UUID = UUID(),
    existingPapers: [Paper] = []
  ) throws -> PDFImportResult {
    _ = try validateSource(sourceURL)
    _ = try PDFTitleExtractor().extract(from: sourceURL)
    guard let title = FilenameSanitizer.displayTitle(requestedTitle) else {
      throw PDFImportError.emptyTitle
    }
    let safeName = FilenameSanitizer.collisionProofPDFName(title: title, paperID: paperID)
    let destination = paths.sourceDirectory(paperID: paperID).appendingPathComponent(safeName)
    let receipt: ImmutableWriteReceipt
    do {
      receipt = try store.copy(
        sourceURL, to: destination, maximumByteCount: policy.maximumByteCount)
    } catch ImmutableFileStoreError.sourceTooLarge(let size, let maximum) {
      throw PDFImportError.sourceTooLarge(size, maximum: maximum)
    }
    let paper = Paper(
      id: paperID, canonicalTitle: title, safeBasename: safeName,
      sourceRelativePath: receipt.relativePath, sourceSHA256: receipt.sha256)
    let duplicates = existingPapers.filter { $0.sourceSHA256 == receipt.sha256 }.map(\.id).sorted {
      $0.uuidString < $1.uuidString
    }
    return PDFImportResult(paper: paper, receipt: receipt, duplicatePaperIDs: duplicates)
  }

  private func validateSource(_ sourceURL: URL, fileManager: FileManager = .default) throws
    -> Int64
  {
    guard sourceURL.isFileURL else { throw PDFImportError.nonFileURL }
    guard !sourceURL.path.isEmpty, !sourceURL.path.contains("\0"), sourceURL.path.hasPrefix("/")
    else { throw PDFImportError.unsafePath(sourceURL.path) }
    let values = try sourceURL.resourceValues(forKeys: [
      .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
    ])
    guard values.isSymbolicLink != true else { throw PDFImportError.symbolicLink(sourceURL.path) }
    guard values.isRegularFile == true else { throw PDFImportError.notRegularFile(sourceURL.path) }
    let size = Int64(values.fileSize ?? 0)
    guard size <= policy.maximumByteCount else {
      throw PDFImportError.sourceTooLarge(size, maximum: policy.maximumByteCount)
    }
    guard sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else {
      throw PDFImportError.notPDF(sourceURL.path)
    }
    let handle = try FileHandle(forReadingFrom: sourceURL)
    defer { try? handle.close() }
    let magic = try handle.read(upToCount: 5) ?? Data()
    guard magic == Data("%PDF-".utf8) else { throw PDFImportError.notPDF(sourceURL.path) }
    return size
  }
}
