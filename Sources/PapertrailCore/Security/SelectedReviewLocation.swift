import Foundation

public struct ResolvedReviewLocation: Equatable, Sendable {
  public let indexURL: URL
  public let readRoot: URL
}

public struct SelectedReviewLocationIdentity: Equatable, Sendable {
  public let paperID: UUID
  public let generationID: UUID
  public let versionID: UUID
  public let canonicalIndexPath: String
  public let canonicalReadRootPath: String
}

public struct SelectedReviewSelectionKey: Equatable, Sendable {
  public let libraryRootPath: String
  public let paperID: UUID
  public let generationID: UUID
  public let versionID: UUID
  public let persistedRelativePath: String
}

public struct SelectedReviewLocation: Sendable {
  public let paths: LibraryPaths
  public let paperID: UUID
  public let generationID: UUID
  public let versionID: UUID
  public let persistedRelativePath: String

  public init(
    paths: LibraryPaths, paperID: UUID, generationID: UUID, versionID: UUID,
    persistedRelativePath: String
  ) {
    self.paths = paths
    self.paperID = paperID
    self.generationID = generationID
    self.versionID = versionID
    self.persistedRelativePath = persistedRelativePath
  }

  public var selectionKey: SelectedReviewSelectionKey {
    SelectedReviewSelectionKey(
      libraryRootPath: paths.root.standardizedFileURL.path,
      paperID: paperID, generationID: generationID, versionID: versionID,
      persistedRelativePath: persistedRelativePath)
  }

  public func identity(fileManager: FileManager = .default) throws -> SelectedReviewLocationIdentity {
    let resolved = try resolve(fileManager: fileManager)
    return SelectedReviewLocationIdentity(
      paperID: paperID, generationID: generationID, versionID: versionID,
      canonicalIndexPath: resolved.indexURL.path,
      canonicalReadRootPath: resolved.readRoot.path)
  }

  public func resolve(fileManager: FileManager = .default) throws -> ResolvedReviewLocation {
    let id = { (value: UUID) in value.uuidString.lowercased() }
    let expectedRelative =
      "Papers/\(id(paperID))/generations/\(id(generationID))/review/\(id(versionID))"
    guard persistedRelativePath == expectedRelative else {
      throw SelectedReviewLocationError.persistedPathMismatch
    }
    let paperRoot = paths.paper(paperID).standardizedFileURL
    let reviewRoot = paths.reviewVersion(
      versionID, generationID: generationID, paperID: paperID
    ).standardizedFileURL
    let indexURL = reviewRoot.appendingPathComponent("index.html").standardizedFileURL

    try SecurePathContainment.rejectSymlinkComponents(
      from: paths.root, through: indexURL, fileManager: fileManager)
    try SecurePathContainment.rejectSymlinkComponents(
      from: paths.papersDirectory, through: indexURL, fileManager: fileManager)
    let canonicalPaper = try SecurePathContainment.requireExisting(
      paperRoot, inside: paths.papersDirectory)
    let canonicalReview = try SecurePathContainment.requireExisting(
      reviewRoot, inside: canonicalPaper)
    let canonicalIndex = try SecurePathContainment.requireExisting(
      indexURL, inside: canonicalReview)
    let rootValues = try canonicalReview.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let indexValues = try canonicalIndex.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw SelectedReviewLocationError.reviewRootInvalid
    }
    guard indexValues.isRegularFile == true, indexValues.isSymbolicLink != true,
      canonicalIndex.deletingLastPathComponent() == canonicalReview
    else { throw SelectedReviewLocationError.indexInvalid }
    return ResolvedReviewLocation(indexURL: canonicalIndex, readRoot: canonicalReview)
  }
}

public enum SelectedReviewLocationError: Error, Equatable {
  case persistedPathMismatch
  case reviewRootInvalid
  case indexInvalid
}
