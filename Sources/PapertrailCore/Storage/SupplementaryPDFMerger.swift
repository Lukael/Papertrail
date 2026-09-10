import Foundation
import PDFKit

public enum SupplementaryPDFMergeError: Error, Equatable, LocalizedError {
  case currentSourceChanged
  case currentSourceOutsidePaper
  case unreadablePDF(String)
  case lockedPDF(String)
  case emptyPDF(String)
  case tooManyPages(Int, maximum: Int)
  case writeFailed
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .currentSourceChanged:
      "The stored paper changed before the supplementary PDF could be added."
    case .currentSourceOutsidePaper:
      "The stored paper path is outside this paper's private source directory."
    case .unreadablePDF(let name):
      "\(name) could not be opened as a PDF."
    case .lockedPDF(let name):
      "\(name) is password protected and cannot be merged."
    case .emptyPDF(let name):
      "\(name) has no pages to merge."
    case .tooManyPages(let count, let maximum):
      "The combined PDF would have \(count) pages; the supported limit is \(maximum)."
    case .writeFailed:
      "The combined PDF could not be written."
    case .verificationFailed:
      "The combined PDF did not pass the post-write verification check."
    }
  }
}

public struct SupplementaryPDFMergeReceipt: Equatable, Sendable {
  public let sourceRelativePath: String
  public let sourceSHA256: String
  public let byteCount: Int
  public let originalPageCount: Int
  public let supplementaryPageCount: Int
  public let combinedPageCount: Int
  public let supplementaryRelativePath: String

  public var createdRelativePaths: [String] {
    [supplementaryRelativePath, sourceRelativePath]
  }
}

public struct SupplementaryPDFMerger: Sendable {
  public static let maximumPageCount = 1_000

  public let paths: LibraryPaths
  public let policy: PDFImportPolicy
  private let immutableStore: ImmutableFileStore

  public init(paths: LibraryPaths, policy: PDFImportPolicy = PDFImportPolicy()) {
    self.paths = paths
    self.policy = policy
    self.immutableStore = ImmutableFileStore(paths: paths)
  }

  public func merge(
    paperID: UUID, currentSourceRelativePath: String, expectedSourceSHA256: String,
    supplementaryURL: URL, fileManager: FileManager = .default
  ) throws -> SupplementaryPDFMergeReceipt {
    let currentSource = try paths.url(forRelativePath: currentSourceRelativePath)
    let sourceDirectory = paths.sourceDirectory(paperID: paperID)
    let containedSource: URL
    do {
      containedSource = try SecurePathContainment.requireExisting(
        currentSource, inside: sourceDirectory)
    } catch {
      throw SupplementaryPDFMergeError.currentSourceOutsidePaper
    }
    let currentFingerprint = try FileFingerprint.read(
      containedSource, maximumByteCount: policy.maximumByteCount)
    guard currentFingerprint.sha256 == expectedSourceSHA256 else {
      throw SupplementaryPDFMergeError.currentSourceChanged
    }

    _ = try PDFImporter(paths: paths, policy: policy).prepare(supplementaryURL)
    let currentDocument = try openDocument(containedSource)
    let supplementaryDocument = try openDocument(supplementaryURL)
    let combinedCount = currentDocument.pageCount + supplementaryDocument.pageCount
    guard combinedCount <= Self.maximumPageCount else {
      throw SupplementaryPDFMergeError.tooManyPages(
        combinedCount, maximum: Self.maximumPageCount)
    }

    let supplementaryID = UUID()
    let storedSupplementary = sourceDirectory.appendingPathComponent(
      "supplementary-\(supplementaryID.uuidString.lowercased()).pdf")
    let supplementaryReceipt = try immutableStore.copy(
      supplementaryURL, to: storedSupplementary, maximumByteCount: policy.maximumByteCount,
      fileManager: fileManager)
    let combinedURL = sourceDirectory.appendingPathComponent(
      "combined-\(UUID().uuidString.lowercased()).pdf")
    let temporaryURL = sourceDirectory.appendingPathComponent(
      ".partial-combined-\(UUID().uuidString.lowercased()).pdf")
    defer { try? fileManager.removeItem(at: temporaryURL) }

    do {
      let combined = PDFDocument()
      try appendPages(from: currentDocument, to: combined)
      try appendPages(from: supplementaryDocument, to: combined)
      guard combined.write(to: temporaryURL) else {
        throw SupplementaryPDFMergeError.writeFailed
      }
      try fileManager.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
      guard let reopened = PDFDocument(url: temporaryURL), !reopened.isLocked,
        reopened.pageCount == combinedCount
      else { throw SupplementaryPDFMergeError.verificationFailed }
      let fingerprint = try FileFingerprint.read(
        temporaryURL, maximumByteCount: policy.maximumByteCount)
      try fileManager.moveItem(at: temporaryURL, to: combinedURL)
      let finalFingerprint = try FileFingerprint.read(
        combinedURL, maximumByteCount: policy.maximumByteCount)
      guard finalFingerprint == fingerprint else {
        try? fileManager.removeItem(at: combinedURL)
        throw SupplementaryPDFMergeError.verificationFailed
      }
      return SupplementaryPDFMergeReceipt(
        sourceRelativePath: try paths.relativePath(for: combinedURL),
        sourceSHA256: fingerprint.sha256, byteCount: fingerprint.byteCount,
        originalPageCount: currentDocument.pageCount,
        supplementaryPageCount: supplementaryDocument.pageCount,
        combinedPageCount: combinedCount,
        supplementaryRelativePath: supplementaryReceipt.relativePath)
    } catch {
      try? fileManager.removeItem(at: combinedURL)
      try? fileManager.removeItem(at: storedSupplementary)
      throw error
    }
  }

  public func removeCreatedFiles(
    from receipt: SupplementaryPDFMergeReceipt, fileManager: FileManager = .default
  ) {
    for relativePath in receipt.createdRelativePaths {
      guard let url = try? paths.url(forRelativePath: relativePath) else { continue }
      try? fileManager.removeItem(at: url)
    }
  }

  private func openDocument(_ url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else {
      throw SupplementaryPDFMergeError.unreadablePDF(url.lastPathComponent)
    }
    guard !document.isLocked else {
      throw SupplementaryPDFMergeError.lockedPDF(url.lastPathComponent)
    }
    guard document.pageCount > 0 else {
      throw SupplementaryPDFMergeError.emptyPDF(url.lastPathComponent)
    }
    return document
  }

  private func appendPages(from source: PDFDocument, to destination: PDFDocument) throws {
    for index in 0..<source.pageCount {
      guard let page = source.page(at: index)?.copy() as? PDFPage else {
        throw SupplementaryPDFMergeError.verificationFailed
      }
      destination.insert(page, at: destination.pageCount)
    }
  }
}
