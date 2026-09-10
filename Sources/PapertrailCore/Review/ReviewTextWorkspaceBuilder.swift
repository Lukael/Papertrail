import Foundation

public enum ReviewTextWorkspaceError: Error, Equatable, CustomStringConvertible {
  case destinationAlreadyExists(String)
  case copyHashMismatch(String)

  public var description: String {
    switch self {
    case .destinationAlreadyExists(let path): "Generation workspace already exists: \(path)"
    case .copyHashMismatch(let path): "Extracted-text copy did not preserve bytes: \(path)"
    }
  }
}

public struct ReviewTextStagingManifest: Codable, Equatable, Sendable {
  public let workspacePath: String
  public let textOriginalPath: String
  public let textCopyPath: String
  public let sourceSHA256: String
  public let textSHA256Before: String
  public let textSHA256After: String

  public let conversationPath: String?
  public let conversationSHA256: String?

  public var copiesAreExact: Bool { textSHA256Before == textSHA256After }
}

public struct ReviewTextWorkspaceBuilder: Sendable {
  public init() {}

  public func build(
    extractedText: VerifiedPDFExtractedText, workspace: URL,
    conversation: ReviewConversationSnapshot? = nil,
    fileManager: FileManager = .default
  ) throws -> ReviewTextStagingManifest {
    guard !fileManager.fileExists(atPath: workspace.path) else {
      throw ReviewTextWorkspaceError.destinationAlreadyExists(workspace.path)
    }
    _ = try extractedText.readText()
    let originalValues = try extractedText.textURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard originalValues.isRegularFile == true, originalValues.isSymbolicLink != true else {
      throw PDFExtractedTextCacheError.cacheInvalid(extractedText.textURL.path)
    }

    try fileManager.createDirectory(
      at: workspace, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let inputDirectory = workspace.appendingPathComponent("input", isDirectory: true)
    let outputDirectory = workspace.appendingPathComponent("output", isDirectory: true)
    try fileManager.createDirectory(
      at: inputDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try fileManager.createDirectory(
      at: outputDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])

    let stagedText = inputDirectory.appendingPathComponent("paper-text.txt")
    try fileManager.copyItem(at: extractedText.textURL, to: stagedText)
    let stagedFingerprint = try FileFingerprint.read(
      stagedText, maximumByteCount: Int64(PDFExtractedTextCache.maximumTextByteCount))
    guard stagedFingerprint.sha256 == extractedText.manifest.textSHA256 else {
      throw ReviewTextWorkspaceError.copyHashMismatch(stagedText.path)
    }
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stagedText.path)
    let conversationURL = inputDirectory.appendingPathComponent("conversation.json")
    var conversationHash: String?
    if let conversation {
      try conversation.encoded().write(to: conversationURL, options: .atomic)
      conversationHash = try FileFingerprint.read(conversationURL,
        maximumByteCount: Int64(ReviewConversationSnapshot.maximumByteCount)).sha256
      try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: conversationURL.path)
    }
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inputDirectory.path)

    return ReviewTextStagingManifest(
      workspacePath: workspace.path,
      textOriginalPath: extractedText.textURL.path,
      textCopyPath: stagedText.path,
      sourceSHA256: extractedText.manifest.sourceSHA256,
      textSHA256Before: extractedText.manifest.textSHA256,
      textSHA256After: stagedFingerprint.sha256,
      conversationPath: conversation == nil ? nil : conversationURL.path,
      conversationSHA256: conversationHash)
  }

  public static func verifyUnchanged(
    _ manifest: ReviewTextStagingManifest, fileManager: FileManager = .default
  ) throws -> Bool {
    let original = URL(fileURLWithPath: manifest.textOriginalPath)
    let copy = URL(fileURLWithPath: manifest.textCopyPath)
    for file in [original, copy] {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
    }
    if let path = manifest.conversationPath {
      let url = URL(fileURLWithPath: path)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        try FileFingerprint.read(url, maximumByteCount: Int64(ReviewConversationSnapshot.maximumByteCount)).sha256
          == manifest.conversationSHA256 else { return false }
    } else if manifest.conversationSHA256 != nil { return false }
    let maximum = Int64(PDFExtractedTextCache.maximumTextByteCount)
    return try FileFingerprint.read(original, maximumByteCount: maximum).sha256
      == manifest.textSHA256Before
      && FileFingerprint.read(copy, maximumByteCount: maximum).sha256
        == manifest.textSHA256After
      && manifest.copiesAreExact
  }
}
