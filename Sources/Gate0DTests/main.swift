import Foundation
import PDFKit
import PapertrailCore

struct Gate0DTestFailure: Error, CustomStringConvertible {
  let description: String
}

@main
enum Gate0DTests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("safe collision-proof names", testSafeNames),
      ("lossless atomic import", testLosslessImport),
      ("duplicate and revision imports stay distinct", testDuplicateAndRevisionImports),
      ("supplementary PDFs merge without changing prior sources", testSupplementaryMerge),
      ("unsafe import inputs fail closed", testUnsafeInputs),
      ("oversize import is rejected before copying", testOversize),
      ("immutable destination and partial cleanup", testNoOverwrite),
      ("durable import intent recovers final-source orphan", testImportIntentRecovery),
      ("PDF title extraction is truthful", testTitleExtraction),
      ("relative stored paths cannot escape", testRelativePathGuard),
      ("nonexistent descendants under private tmp remain contained", testPrivateTmpContainment),
      ("paper reading state survives store reopen", testReadingStateRestoration),
      ("stored source opens with PDFKit", testPDFKitOpen),
      ("final source without model commit is completed on launch", testImportCommitRecovery),
      ("committed import intent cleanup is idempotent", testCommittedImportRecovery),
      ("missing and partial import state is preserved for repair", testMissingImportRecovery),
      ("corrupt and symlink final sources are preserved for repair", testUnsafeFinalImportRecovery),
      ("corrupt durable import intent preserves source state", testCorruptIntentRecovery),
      ("import UI and manual-only review lifecycle are wired", testUISourceContract),
    ]
    for (name, test) in tests {
      try test()
      print("PASS: \(name)")
    }
    print("PASS: \(tests.count) Gate 0D test groups")
  }

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }

  private static var representativePDF: URL {
    repositoryRoot.appendingPathComponent("Fixtures/Papers/representative-paper.pdf")
  }

  private static var injectionPDF: URL {
    repositoryRoot.appendingPathComponent("Fixtures/Papers/untrusted-content-paper.pdf")
  }

  private static func temporarySupport() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws
  {
    guard try condition() else { throw Gate0DTestFailure(description: message) }
  }

  private static func testSafeNames() throws {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let name = FilenameSanitizer.collisionProofPDFName(
      title: " ../A\u{0} Paper／測試  ".replacingOccurrences(of: "\\u{0}", with: "\0"),
      paperID: id)
    try expect(!name.contains("/"), "sanitized name retained a path separator")
    try expect(!name.contains(".."), "sanitized name retained traversal")
    try expect(name.hasSuffix("--11111111-2222-3333-4444-555555555555.pdf"), "full UUID missing")
    try expect(name.utf8.count < 140, "bounded safe name grew unexpectedly")
    let other = FilenameSanitizer.collisionProofPDFName(title: "A Paper", paperID: UUID())
    try expect(name != other, "different paper IDs collided")
  }

  private static func testLosslessImport() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let before = try FileFingerprint.read(representativePDF)
    let result = try PDFImporter(paths: paths).importPDF(
      from: representativePDF, title: "Representative / Paper")
    let stored = try paths.url(forRelativePath: result.paper.sourceRelativePath)
    let after = try FileFingerprint.read(representativePDF)
    let copied = try FileFingerprint.read(stored)
    try expect(before == after, "original PDF bytes changed")
    try expect(copied == before, "stored PDF is not byte-identical")
    try expect(result.paper.sourceSHA256 == before.sha256, "paper fingerprint differs")
    try expect(!stored.isSymbolicLink, "stored source is a symbolic link")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions]
      as? NSNumber
    try expect(permissions?.intValue == 0o600, "stored source is not owner-only")
    try expect(
      stored.deletingLastPathComponent() == paths.sourceDirectory(paperID: result.paper.id),
      "wrong topology")
  }

  private static func testPrivateTmpContainment() throws {
    let support = URL(
      fileURLWithPath: "/private/tmp/gate0d-private-tmp-\(UUID().uuidString)/Application Support",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let probe = paths.sourceDirectory(paperID: UUID()).appendingPathComponent("probe.pdf")
    try SecurePathContainment.rejectSymlinkComponents(from: paths.root, through: probe)
    let result = try DurablePDFImportCoordinator(paths: paths).begin(
      from: representativePDF, title: "Private tmp containment", existingPapers: [])
    try expect(
      result.paper.sourceRelativePath.hasPrefix("Papers/"),
      "private tmp import did not produce a library-relative path")
  }

  private static func testDuplicateAndRevisionImports() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let importer = PDFImporter(paths: paths)
    let first = try importer.importPDF(from: representativePDF, title: "Same Title")
    let duplicate = try importer.importPDF(
      from: representativePDF, title: "Renamed Copy", existingPapers: [first.paper])
    let revision = try importer.importPDF(
      from: injectionPDF, title: "Same Title", existingPapers: [first.paper, duplicate.paper])
    try expect(duplicate.duplicatePaperIDs == [first.paper.id], "duplicate bytes were not reported")
    try expect(
      first.paper.sourceRelativePath != duplicate.paper.sourceRelativePath,
      "duplicate overwrote source")
    try expect(
      first.paper.sourceRelativePath != revision.paper.sourceRelativePath, "revision path collided")
    try expect(
      first.paper.sourceSHA256 != revision.paper.sourceSHA256, "different PDF revision was hidden")
  }

  private static func testSupplementaryMerge() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let imported = try PDFImporter(paths: paths).importPDF(
      from: representativePDF, title: "Paper with Supplement")
    let originalURL = try paths.url(forRelativePath: imported.paper.sourceRelativePath)
    let originalFingerprint = try FileFingerprint.read(originalURL)
    let supplementaryFingerprint = try FileFingerprint.read(injectionPDF)
    guard let originalDocument = PDFDocument(url: originalURL),
      let supplementaryDocument = PDFDocument(url: injectionPDF)
    else { throw Gate0DTestFailure(description: "fixture PDF did not open") }

    let receipt = try SupplementaryPDFMerger(paths: paths).merge(
      paperID: imported.paper.id,
      currentSourceRelativePath: imported.paper.sourceRelativePath,
      expectedSourceSHA256: imported.paper.sourceSHA256,
      supplementaryURL: injectionPDF)
    let combinedURL = try paths.url(forRelativePath: receipt.sourceRelativePath)
    let storedSupplementary = try paths.url(forRelativePath: receipt.supplementaryRelativePath)
    guard let combinedDocument = PDFDocument(url: combinedURL) else {
      throw Gate0DTestFailure(description: "combined PDF did not reopen")
    }

    try expect(
      try FileFingerprint.read(originalURL) == originalFingerprint,
      "merge changed the prior source PDF")
    try expect(
      try FileFingerprint.read(storedSupplementary) == supplementaryFingerprint,
      "stored supplementary PDF differs from the selection")
    try expect(
      combinedDocument.pageCount == originalDocument.pageCount + supplementaryDocument.pageCount,
      "combined PDF page count differs")
    try expect(
      receipt.combinedPageCount == combinedDocument.pageCount,
      "merge receipt page count differs")
    try expect(
      try FileFingerprint.read(combinedURL).sha256 == receipt.sourceSHA256,
      "combined PDF fingerprint differs")
    try expect(
      combinedURL.deletingLastPathComponent() == paths.sourceDirectory(paperID: imported.paper.id),
      "combined PDF escaped the paper source directory")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: combinedURL.path)[.posixPermissions]
      as? NSNumber
    try expect(permissions?.intValue == 0o600, "combined PDF is not owner-only")

    if let qaOutput = ProcessInfo.processInfo.environment["PPR_SUPPLEMENTARY_QA_OUTPUT"] {
      let output = URL(fileURLWithPath: qaOutput)
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: combinedURL, to: output)
    }
  }

  private static func testUnsafeInputs() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let importer = PDFImporter(paths: paths)
    let symlink = support.appendingPathComponent("linked.pdf")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: representativePDF)
    let directory = support.appendingPathComponent("directory.pdf", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wrongExtension = support.appendingPathComponent("paper.txt")
    try FileManager.default.copyItem(at: representativePDF, to: wrongExtension)
    let badMagic = support.appendingPathComponent("not-really.pdf")
    try Data("not a pdf".utf8).write(to: badMagic)

    for (url, expected) in [
      (symlink, "symlink"), (directory, "directory"), (wrongExtension, "extension"),
      (badMagic, "magic"),
    ] {
      do {
        _ = try importer.prepare(url)
        throw Gate0DTestFailure(description: "\(expected) input was accepted")
      } catch is PDFImportError {}
    }
    do {
      _ = try importer.prepare(URL(string: "https://example.invalid/paper.pdf")!)
      throw Gate0DTestFailure(description: "remote URL was accepted")
    } catch PDFImportError.nonFileURL {}
  }

  private static func testOversize() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let importer = PDFImporter(paths: paths, policy: PDFImportPolicy(maximumByteCount: 16))
    do {
      _ = try importer.importPDF(from: representativePDF, title: "Too Large")
      throw Gate0DTestFailure(description: "oversize PDF was copied")
    } catch PDFImportError.sourceTooLarge {}
    let descendants =
      (try? FileManager.default.subpathsOfDirectory(atPath: paths.papersDirectory.path)) ?? []
    try expect(descendants.isEmpty, "oversize rejection left storage artifacts")
  }

  private static func testNoOverwrite() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let importer = PDFImporter(paths: paths)
    let id = UUID()
    let first = try importer.importPDF(from: representativePDF, title: "Immutable", paperID: id)
    let destination = try paths.url(forRelativePath: first.paper.sourceRelativePath)
    let before = try Data(contentsOf: destination)
    do {
      _ = try importer.importPDF(from: injectionPDF, title: "Immutable", paperID: id)
      throw Gate0DTestFailure(description: "existing source was overwritten")
    } catch ImmutableFileStoreError.destinationExists {}
    try expect(try Data(contentsOf: destination) == before, "prior stored bytes changed")
    let names = try FileManager.default.contentsOfDirectory(
      atPath: destination.deletingLastPathComponent().path)
    try expect(
      !names.contains(where: { $0.hasPrefix(".partial-import-") }), "partial import leaked")
  }

  private static func testImportIntentRecovery() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    let paperID = UUID()
    let pending = try DurablePDFImportCoordinator(paths: paths).begin(
      from: representativePDF, title: "Crash Before Store Commit", paperID: paperID,
      existingPapers: [])
    try expect((try store.load()).papers.isEmpty, "fixture unexpectedly committed paper")
    let finalSource = try paths.url(forRelativePath: pending.paper.sourceRelativePath)
    try expect(
      FileManager.default.fileExists(atPath: finalSource.path), "final source fixture missing")

    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    let recovered = try store.load().papers
    try expect(
      recovered.count == 1 && recovered[0].id == paperID, "orphan import was not recovered")
    try expect(
      recovered[0].sourceSHA256 == pending.paper.sourceSHA256,
      "recovered import fingerprint changed")
    try expect(
      recovered[0].automaticReviewRequiredAt == nil
        && recovered[0].automaticReviewCompletedAt == nil,
      "recovered import unexpectedly scheduled an automatic review")
    try expect(
      issues.contains(where: {
        if case .recoverablePartial(let path) = $0 {
          return path.contains(paperID.uuidString.lowercased())
        }
        return false
      }), "recovered import intent was not reported")
    try expect(
      !FileManager.default.fileExists(
        atPath: paths.importIntentsDirectory
          .appendingPathComponent("\(paperID.uuidString.lowercased()).json").path),
      "completed import intent was not removed")
  }

  private static func testTitleExtraction() throws {
    let extracted = try PDFTitleExtractor().extract(from: representativePDF)
    try expect(!extracted.title.isEmpty, "title extraction returned empty text")
    try expect(extracted.title.count <= 240, "title extraction was not bounded")
    if extracted.source == .temporaryFilename {
      try expect(extracted.requiresCorrection, "temporary title was presented as authoritative")
    }
  }

  private static func testRelativePathGuard() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    for unsafe in ["/tmp/paper.pdf", "../paper.pdf", "Papers/../paper.pdf", "Papers//paper.pdf"] {
      do {
        _ = try paths.url(forRelativePath: unsafe)
        throw Gate0DTestFailure(description: "unsafe stored path accepted: \(unsafe)")
      } catch is LibraryPathError {}
    }
    let safe = try paths.url(forRelativePath: "Papers/abc/source/paper.pdf")
    try expect(safe.path.hasPrefix(paths.root.path + "/"), "safe stored path escaped")
  }

  private static func testReadingStateRestoration() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let result = try PDFImporter(paths: paths).importPDF(
      from: representativePDF, title: "Reading State")
    var paper = result.paper
    paper.readingPageIndex = 2
    paper.readingScale = 1.75
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(DurableSnapshot(papers: [paper]))
    let reopened = try ModelContainerFactory.make(at: paths.storeURL)
    let restored = try reopened.load().papers[0]
    try expect(restored.readingPageIndex == 2, "page index did not survive reopen")
    try expect(restored.readingScale == 1.75, "scale did not survive reopen")
  }

  private static func testPDFKitOpen() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let result = try PDFImporter(paths: paths).importPDF(from: representativePDF, title: "Open")
    let stored = try paths.url(forRelativePath: result.paper.sourceRelativePath)
    let document = PDFDocument(url: stored)
    try expect(document != nil && document!.pageCount > 0, "PDFKit did not open stored source")
  }

  private static func testImportCommitRecovery() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let pending = try DurablePDFImportCoordinator(paths: paths).begin(
      from: representativePDF, title: "Crash Boundary", existingPapers: [])
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try expect(try store.load().papers.isEmpty, "test did not stop before model commit")

    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    let recovered = try store.load().papers
    try expect(recovered.count == 1, "valid orphan final source was not completed")
    try expect(recovered[0].id == pending.paper.id, "recovered paper identity changed")
    try expect(recovered[0].sourceSHA256 == pending.paper.sourceSHA256, "recovered hash changed")
    try expect(
      recovered[0].automaticReviewRequiredAt == nil,
      "relaunch recovery unexpectedly scheduled an automatic review")
    try expect(!issues.isEmpty, "crash recovery was not reported")
    try expect(try intentEntries(paths).isEmpty, "completed intent was not removed")

    let secondIssues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(try store.load().papers.count == 1, "repeated recovery duplicated the paper")
    try expect(secondIssues.isEmpty, "idempotent recovery reported stale work")
  }

  private static func testCommittedImportRecovery() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let pending = try DurablePDFImportCoordinator(paths: paths).begin(
      from: representativePDF, title: "Committed Boundary", existingPapers: [])
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(DurableSnapshot(papers: [pending.paper]))

    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(
      try store.load().papers == [pending.paper], "committed import was duplicated or changed")
    try expect(try intentEntries(paths).isEmpty, "post-commit intent was not cleared")
    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(
      try store.load().papers == [pending.paper], "second cleanup changed committed import")
  }

  private static func testMissingImportRecovery() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let pending = try DurablePDFImportCoordinator(paths: paths).begin(
      from: representativePDF, title: "Missing Boundary", existingPapers: [])
    let final = try paths.url(forRelativePath: pending.paper.sourceRelativePath)
    try FileManager.default.removeItem(at: final)
    let partial = final.deletingLastPathComponent().appendingPathComponent(".partial-import-crash")
    try Data("partial".utf8).write(to: partial)
    let partialIntent = paths.importIntentsDirectory.appendingPathComponent(
      ".partial-import-intent-test")
    try Data("partial-intent".utf8).write(to: partialIntent)
    let store = try ModelContainerFactory.make(at: paths.storeURL)

    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(try store.load().papers.isEmpty, "missing final source created a model record")
    try expect(
      FileManager.default.fileExists(atPath: paths.paper(pending.paper.id).path),
      "repair-pending paper directory was deleted")
    try expect(FileManager.default.fileExists(atPath: partial.path), "partial bytes were deleted")
    try expect(
      FileManager.default.fileExists(atPath: partialIntent.path), "partial intent was deleted")
    try expect(try intentEntries(paths).count == 2, "repair-pending intents were deleted")
    try expect(
      hasPendingImportIssue(issues, reason: "missing-source"),
      "missing source did not produce an explicit repair issue")
    try expect(
      hasPendingImportIssue(issues, reason: "partial-intent"),
      "partial intent did not produce an explicit repair issue")
    let secondIssues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(try store.load().papers.isEmpty, "repeated missing recovery created a paper")
    try expect(
      FileManager.default.fileExists(atPath: partial.path), "repeat recovery deleted bytes")
    try expect(
      FileManager.default.fileExists(atPath: partialIntent.path),
      "repeat recovery deleted the partial intent")
    try expect(
      hasPendingImportIssue(secondIssues, reason: "missing-source"),
      "repeat recovery lost the repair issue")
  }

  private static func testUnsafeFinalImportRecovery() throws {
    for useSymlink in [false, true] {
      let support = try temporarySupport()
      defer { try? FileManager.default.removeItem(at: support) }
      let paths = LibraryPaths(applicationSupport: support)
      try paths.createRootTopology()
      let pending = try DurablePDFImportCoordinator(paths: paths).begin(
        from: representativePDF, title: useSymlink ? "Symlink Boundary" : "Corrupt Boundary",
        existingPapers: [])
      let final = try paths.url(forRelativePath: pending.paper.sourceRelativePath)
      if useSymlink {
        try FileManager.default.removeItem(at: final)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: representativePDF)
      } else {
        try Data("%PDF-corrupt".utf8).write(to: final, options: .atomic)
      }
      let unsafeBytes = useSymlink ? nil : try Data(contentsOf: final)
      let original = try Data(contentsOf: representativePDF)
      let store = try ModelContainerFactory.make(at: paths.storeURL)
      let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
      try expect(try store.load().papers.isEmpty, "unsafe final source was committed")
      try expect(
        FileManager.default.fileExists(atPath: paths.paper(pending.paper.id).path),
        "unsafe repair-pending paper directory was deleted")
      try expect(
        useSymlink
          ? (try? FileManager.default.destinationOfSymbolicLink(atPath: final.path)) != nil
          : try Data(contentsOf: final) == unsafeBytes,
        "unsafe source state was not preserved")
      try expect(try Data(contentsOf: representativePDF) == original, "symlink target was changed")
      try expect(try intentEntries(paths).count == 1, "unsafe intent was deleted")
      try expect(
        hasPendingImportIssue(
          issues, reason: useSymlink ? "unsafe-source" : "source-mismatch"),
        "unsafe source did not produce an explicit repair issue")
      let secondIssues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
      try expect(
        hasPendingImportIssue(
          secondIssues, reason: useSymlink ? "unsafe-source" : "source-mismatch"),
        "repeat recovery lost the unsafe-source issue")
    }
  }

  private static func testCorruptIntentRecovery() throws {
    for useSymlink in [false, true] {
      let support = try temporarySupport()
      defer { try? FileManager.default.removeItem(at: support) }
      let paths = LibraryPaths(applicationSupport: support)
      try paths.createRootTopology()
      let pending = try DurablePDFImportCoordinator(paths: paths).begin(
        from: representativePDF, title: useSymlink ? "Symlink Intent" : "Corrupt Intent",
        existingPapers: [])
      let intent = paths.importIntentsDirectory.appendingPathComponent(
        "\(pending.paper.id.uuidString.lowercased()).json")
      let corruptIntent = Data("not-json".utf8)
      let outside = support.appendingPathComponent("outside-intent.json")
      if useSymlink {
        try corruptIntent.write(to: outside)
        try FileManager.default.removeItem(at: intent)
        try FileManager.default.createSymbolicLink(at: intent, withDestinationURL: outside)
      } else {
        try corruptIntent.write(to: intent, options: .atomic)
      }
      let final = try paths.url(forRelativePath: pending.paper.sourceRelativePath)
      let sourceBytes = try Data(contentsOf: final)
      let store = try ModelContainerFactory.make(at: paths.storeURL)

      let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
      try expect(try store.load().papers.isEmpty, "corrupt intent created a model record")
      try expect(
        FileManager.default.fileExists(atPath: paths.paper(pending.paper.id).path),
        "corrupt-intent paper directory was deleted")
      try expect(try Data(contentsOf: final) == sourceBytes, "corrupt intent deleted source bytes")
      try expect(
        useSymlink
          ? (try? FileManager.default.destinationOfSymbolicLink(atPath: intent.path)) != nil
          : try Data(contentsOf: intent) == corruptIntent,
        "corrupt intent was deleted or changed")
      if useSymlink {
        try expect(try Data(contentsOf: outside) == corruptIntent, "intent symlink target changed")
      }
      try expect(
        hasPendingImportIssue(issues, reason: "invalid-intent"),
        "corrupt intent did not produce an explicit repair issue")
      let secondIssues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
      try expect(try Data(contentsOf: final) == sourceBytes, "repeat recovery deleted source bytes")
      try expect(
        hasPendingImportIssue(secondIssues, reason: "invalid-intent"),
        "repeat recovery lost the corrupt-intent issue")
    }
  }

  private static func hasPendingImportIssue(
    _ issues: [LibraryRecoveryIssue], reason: String
  ) -> Bool {
    issues.contains { issue in
      guard case .importRecoveryPending(_, let actualReason) = issue else { return false }
      return actualReason == reason
    }
  }

  private static func intentEntries(_ paths: LibraryPaths) throws -> [String] {
    guard FileManager.default.fileExists(atPath: paths.importIntentsDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(atPath: paths.importIntentsDirectory.path)
  }

  private static func testUISourceContract() throws {
    let app = repositoryRoot.appendingPathComponent("Sources/PapertrailApp")
    let workspace = try String(
      contentsOf: app.appendingPathComponent("PaperWorkspaceViews.swift"), encoding: .utf8)
    let reader = try String(
      contentsOf: app.appendingPathComponent("PDFDocumentView.swift"), encoding: .utf8)
    let controller = try String(
      contentsOf: app.appendingPathComponent("PaperLibraryController.swift"), encoding: .utf8)
    let reviewController = try String(
      contentsOf: app.appendingPathComponent("ReviewGenerationController.swift"), encoding: .utf8)
    for required in [
      ".fileImporter", ".dropDestination", "ImportConfirmationView", "requiresCorrection",
      "Add Supplementary PDF…", "isPDFImporterPresented", "PDFSelectionPurpose",
    ] {
      try expect(workspace.contains(required), "import UI lacks \(required)")
    }
    for required in ["PDFView", "PDFViewPageChanged", "PDFViewScaleChanged", "go(to:"] {
      try expect(reader.contains(required), "PDF reader lacks \(required)")
    }
    for required in [
      "readingPageIndex", "readingScale", "context.save()", "store.transaction",
      "addSupplementaryPDF", "SupplementaryPDFMerger",
    ] {
      try expect(controller.contains(required), "authoritative persistence lacks \(required)")
    }
    for forbidden in [
      "startAutomaticReview", "resumeAutomaticReviews", "generateAutomaticallyIfNeeded",
      "automaticReviewRequests.reconcile",
    ] {
      try expect(
        !controller.contains(forbidden),
        "paper import or relaunch still contains automatic review path: \(forbidden)")
    }
    for forbidden in [
      "claimAutomaticRequestIfPresent", "automaticRequests.claim", "automaticRequests.complete",
      "automaticRequests.release",
    ] {
      try expect(
        !reviewController.contains(forbidden),
        "manual generation can still consume automatic request identity: \(forbidden)")
    }
    try expect(
      reviewController.contains("let identity = ReviewGenerationIdentity()"),
      "manual generation does not create an independent generation identity")
  }
}

extension URL {
  fileprivate var isSymbolicLink: Bool {
    (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}
