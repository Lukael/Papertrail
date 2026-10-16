import Foundation

/// Turns one Claude result into a validated review document. The app is the only writer of the
/// operation output path, so a pre-existing file or symlink there is reported as unsafe output
/// and is never offered for correction; content problems become a `Rejection` whose findings
/// can be sent back to the same session.
struct ReturnedDocumentCheck {
  struct Rejection: Error {
    let findings: [StructuredReviewValidationFinding]
    let serviceError: ReviewGenerationServiceError
    /// The readable document when only its content failed, for a patch or pruning.
    var document: ReviewDocumentV2? = nil
  }

  let documentURL: URL
  let relativePath: String
  let workspace: URL
  let pageTexts: [String]
  let conversationMessageIDs: Set<String>
  let fileManager: FileManager

  private var validationURL: URL { workspace.appendingPathComponent("semantic-validation.json") }

  /// Validates a returned document. When `previous` is given and the result is a correction
  /// patch rather than a whole document, the patch is kept beside the output and applied to it.
  func validate(_ resultText: String?, correcting previous: ReviewDocumentV2? = nil) throws
    -> ReviewDocumentV2
  {
    var returned: Data
    do {
      returned = try ReviewPromptBuilder.extractDocument(from: resultText)
    } catch {
      throw Rejection(
        findings: [.init(code: "invalid-document", path: "$", message: error.localizedDescription)],
        serviceError: .structuredDocumentInvalid(error.localizedDescription), document: previous)
    }
    if let previous, !ReviewDocumentDecoder.isWholeDocument(returned) {
      try writeOutput(returned, to: patchURL)
      let patch: ReviewDocumentPatch
      do {
        patch = try ReviewDocumentDecoder().decodePatch(returned)
      } catch {
        throw Rejection(
          findings: [.init(code: "schema", path: "$", message: String(describing: error))],
          serviceError: .structuredDocumentInvalid(String(describing: error)), document: previous)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      returned = try encoder.encode(previous.applying(patch))
    }
    try writeOutput(returned, to: documentURL)
    let document: ReviewDocumentV2
    do {
      _ = try FileFingerprint.read(
        documentURL, maximumByteCount: Int64(ReviewDocumentDecoder.maximumDocumentBytes))
      document = try ReviewDocumentDecoder().decode(
        Data(contentsOf: documentURL, options: [.mappedIfSafe, .uncached]))
    } catch {
      throw Rejection(
        findings: [.init(code: "schema", path: "$", message: String(describing: error))],
        serviceError: .structuredDocumentInvalid(String(describing: error)), document: previous)
    }
    let report = ReviewDocumentValidator().validate(
      document, pageTexts: pageTexts, conversationMessageIDs: conversationMessageIDs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(try encoder.encode(report), to: validationURL)
    guard report.passed else {
      throw Rejection(
        findings: report.findings, serviceError: .structuredReviewFailed(report), document: document)
    }
    return document
  }

  /// Keeps a rejected attempt and its findings beside the output for audit, freeing the paths
  /// for the corrected document.
  func archiveAttempt(_ number: Int) throws {
    for url in [documentURL, validationURL, patchURL] where fileManager.fileExists(atPath: url.path) {
      let archived = url.deletingPathExtension()
        .appendingPathExtension("attempt-\(number).json")
      try fileManager.moveItem(at: url, to: archived)
    }
  }

  private var patchURL: URL {
    documentURL.deletingLastPathComponent().appendingPathComponent("review.patch.json")
  }

  /// The app is the only writer of these paths: anything already there is unsafe output.
  private func writeOutput(_ data: Data, to url: URL) throws {
    // `attributesOfItem` reports a dangling symlink without following it.
    guard (try? fileManager.attributesOfItem(atPath: url.path)) == nil else {
      throw ReviewGenerationServiceError.unsafeOutput(relativePath)
    }
    try writePrivate(data, to: url)
    guard fileManager.fileExists(atPath: url.path) else {
      throw ReviewGenerationServiceError.outputMissing(relativePath)
    }
    do {
      _ = try SecurePathContainment.requireExisting(url, inside: workspace)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ReviewGenerationServiceError.unsafeOutput(relativePath)
      }
    } catch let error as ReviewGenerationServiceError {
      throw error
    } catch {
      throw ReviewGenerationServiceError.unsafeOutput(relativePath)
    }
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.withoutOverwriting])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
