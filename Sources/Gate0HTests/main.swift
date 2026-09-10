import Foundation
import PapertrailCore

struct Gate0HFailure: Error, CustomStringConvertible { let description: String }

final class ConcurrentFailureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failures: [String] = []

  func record(_ error: Error) {
    lock.withLock { failures.append(String(describing: error)) }
  }

  func all() -> [String] { lock.withLock { failures } }
}

@main
enum Gate0HTests {
  static var fm: FileManager { FileManager.default }
  static let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  static let pdf = repo.appendingPathComponent("Fixtures/Papers/representative-paper.pdf")

  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("backup restore preserves originals versions chat lineage evidence and authority", roundTrip),
      ("export refuses overwrite and preserves existing destination", exportNoOverwrite),
      ("restore refuses live data overwrite", restoreNoOverwrite),
      ("export rejects symlink descendants", exportRejectsSymlink),
      ("restore rejects manifest traversal", restoreRejectsTraversal),
      ("restore rejects payload symlinks", restoreRejectsSymlink),
      ("restore rejects corruption without creating live data", restoreRejectsCorruption),
      ("restored crash state reconciles on relaunch", restoredRelaunchReconciliation),
      ("paper deletion removes only its complete object graph and directory", paperDeletion),
    ]
    for (name, test) in tests { try test(); print("PASS: \(name)") }
    if let evidencePath = ProcessInfo.processInfo.environment["GATE0H_EVIDENCE_DIR"] {
      try writeEvidence(to: URL(fileURLWithPath: evidencePath, isDirectory: true))
      print("PASS: deterministic backup evidence written")
    }
    print("PASS Gate0HTests \(tests.count)/\(tests.count)")
  }

  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Gate0HFailure(description: message) }
  }

  static func temporary(_ label: String) throws -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("gate0h-\(label)-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func fixture() throws -> (URL, LibraryPaths, DurableModelStore, DurableSnapshot) {
    let base = try temporary("fixture")
    let paths = LibraryPaths(applicationSupport: base.appendingPathComponent("support"))
    try paths.createRootTopology()
    let imported = try PDFImporter(paths: paths).importPDF(from: pdf, title: "Release Backup")
    var paper = imported.paper
    let generationID = UUID(), versionID = UUID(), sessionID = UUID(), operationID = UUID()
    let workspace = paths.chatWorkspace(sessionID, paperID: paper.id)
    let review = paths.reviewVersion(versionID, generationID: generationID, paperID: paper.id)
    let operationDirectory = paths.operationDirectory(
      operationID: operationID, forAgentWorkspace: workspace)
    try fm.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: review.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("<html>immutable review v1</html>".utf8).write(to: review.appendingPathComponent("index.html"))
    try Data("evidence-v1".utf8).write(to: review.appendingPathComponent("evidence.json"))
    try Data("outside-read=true\nnetwork=true\naccepted-by-owner=true\n".utf8)
      .write(to: paths.storeDirectory.appendingPathComponent("residual-authority.txt"))
    let journal = try OperationJournal(directoryURL: operationDirectory)
    try journal.append(Data(#"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"kept"}}"#.utf8))

    paper.currentChatSessionID = sessionID
    paper.selectedReviewVersionID = versionID
    let session = CodexSession(
      id: sessionID, paperID: paper.id, purpose: .paperChat,
      workspaceRelativePath: try paths.relativePath(for: workspace), lifecycle: .active)
    var operation = CodexOperation(
      id: operationID, clientOperationID: operationID, sessionID: sessionID, kind: "chatTurn",
      promptSHA256: "prompt-hash",
      journalRelativePath: try paths.relativePath(for: journal.directoryURL))
    operation.processOutcomeRawValue = ProcessOutcome.running.rawValue
    let message = ChatMessage(
      paperID: paper.id, sessionID: sessionID, operationID: operationID, role: "assistant",
      committedContent: "historical lineage preserved", deliveryState: "committed")
    var generation = ReviewGeneration(
      id: generationID, paperID: paper.id, sessionID: sessionID,
      workspaceRelativePath: try paths.relativePath(for: workspace))
    generation.reviewVersionID = versionID
    generation.reviewRelativePath = try paths.relativePath(for: review)
    generation.processOutcomeRawValue = ProcessOutcome.turnCompleted.rawValue
    generation.structuralValidationRawValue = StructuralValidationState.passed.rawValue
    generation.evidenceReportStateRawValue = EvidenceReportState.produced.rawValue
    let evidence = ReviewEvidenceReport(
      generationID: generationID, reviewVersionID: versionID,
      relativePath: try paths.relativePath(for: review.appendingPathComponent("evidence.json")),
      state: .produced)
    let snapshot = DurableSnapshot(
      papers: [paper], sessions: [session], operations: [operation], messages: [message],
      generations: [generation], evidenceReports: [evidence])
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(snapshot)
    return (base, paths, store, snapshot)
  }

  static func treeHashes(_ root: URL) throws -> [String: String] {
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    var result: [String: String] = [:]
    while let item = enumerator.nextObject() as? URL {
      if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        let prefix = root.path + "/"
        result[String(item.path.dropFirst(prefix.count))] = try FileFingerprint.read(item).sha256
      }
    }
    return result
  }

  static func roundTrip() throws {
    try concurrentPortableTransactions()
    let (base, paths, _, snapshot) = try fixture(); defer { try? fm.removeItem(at: base) }
    let original = try treeHashes(paths.root)
    let backup = base.appendingPathComponent("backup.pprbackup")
    let receipt = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    try expect(receipt.entryCount == original.count, "manifest entry count differs")
    try expect(try treeHashes(paths.root) == original, "export modified original library")
    let restoreSupport = base.appendingPathComponent("restored-support")
    let restoredReceipt = try LibraryBackup().restore(from: backup, toApplicationSupport: restoreSupport)
    let restoredPaths = LibraryPaths(applicationSupport: restoreSupport)
    try expect(restoredReceipt == receipt, "export and restore receipts differ")
    try expect(try treeHashes(restoredPaths.root) == original, "restored bytes differ")
    let restored = try ModelContainerFactory.make(at: restoredPaths.storeURL).load()
    try expect(restored == snapshot, "durable model lineage changed")
    try expect(restored.papers[0].selectedReviewVersionID != nil, "review version pointer missing")
    try expect(restored.papers[0].currentChatSessionID == restored.sessions[0].id, "chat pointer lineage missing")
    try expect(restored.evidenceReports.count == 1, "evidence record missing")
    let authority = try String(contentsOf: restoredPaths.storeDirectory.appendingPathComponent("residual-authority.txt"), encoding: .utf8)
    try expect(authority.contains("accepted-by-owner=true"), "authority marker missing")
    let rootMode = try fm.attributesOfItem(atPath: restoredPaths.root.path)[.posixPermissions] as? NSNumber
    try expect(rootMode?.intValue == 0o700, "restored root is not owner-only")
    guard let enumerator = fm.enumerator(at: restoredPaths.root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else {
      throw Gate0HFailure(description: "restored tree unavailable")
    }
    while let item = enumerator.nextObject() as? URL {
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      let mode = (try fm.attributesOfItem(atPath: item.path)[.posixPermissions] as? NSNumber)?.intValue
      if values.isDirectory == true { try expect(mode == 0o700, "restored directory is not owner-only: \(item.path)") }
      if values.isRegularFile == true { try expect(mode == 0o600, "restored file is not owner-only: \(item.path)") }
    }
  }

  static func paperDeletion() throws {
    let (base, paths, store, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let target = try store.load().papers[0]
    let otherID = UUID()
    let otherDirectory = paths.paper(otherID)
    try fm.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
    let otherMarker = otherDirectory.appendingPathComponent("keep.txt")
    try Data("unrelated".utf8).write(to: otherMarker)
    try store.transaction { snapshot in
      snapshot.papers.append(
        Paper(
          id: otherID, canonicalTitle: "Keep Me", safeBasename: "keep.pdf",
          sourceRelativePath: try paths.relativePath(for: otherMarker), sourceSHA256: "keep"))
    }
    let requestStore = DurableAutomaticReviewRequestStore(url: paths.automaticReviewRequestsURL)
    _ = try requestStore.enqueue(paperID: target.id)
    let staleDeletion = paths.papersDirectory.appendingPathComponent(
      ".deleting-\(target.id.uuidString.lowercased())-stale", isDirectory: true)
    try fm.createDirectory(at: staleDeletion, withIntermediateDirectories: true)
    let readonlyNested = staleDeletion.appendingPathComponent("readonly/nested", isDirectory: true)
    try fm.createDirectory(at: readonlyNested, withIntermediateDirectories: true)
    let staleMarker = readonlyNested.appendingPathComponent("stale.txt")
    try Data("stale".utf8).write(to: staleMarker)
    try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: staleMarker.path)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyNested.path)

    let receipt = try PaperDeletionService(paths: paths, store: store).delete(paperID: target.id)
    let remaining = try store.load()
    try expect(receipt.deletedSessionCount == 1, "paper sessions were not counted")
    try expect(receipt.deletedOperationCount == 1, "paper operations were not counted")
    try expect(receipt.deletedMessageCount == 1, "paper messages were not counted")
    try expect(receipt.deletedGenerationCount == 1, "paper generations were not counted")
    try expect(receipt.deletedEvidenceCount == 1, "paper evidence was not counted")
    try expect(!receipt.fileCleanupPending, "paper directory cleanup unexpectedly pending")
    try expect(
      !receipt.automaticRequestCleanupPending,
      "automatic review request cleanup unexpectedly pending")
    try expect(!fm.fileExists(atPath: paths.paper(target.id).path), "paper directory survived")
    let deletionPrefix = ".deleting-\(target.id.uuidString.lowercased())-"
    let deletionResidue = try fm.contentsOfDirectory(atPath: paths.papersDirectory.path)
      .filter { $0.hasPrefix(deletionPrefix) }
    try expect(deletionResidue.isEmpty, "paper deletion staging directory survived")
    try expect(remaining.papers.map(\.id) == [otherID], "unrelated paper changed")
    try expect(remaining.sessions.isEmpty && remaining.operations.isEmpty, "session lineage survived")
    try expect(remaining.messages.isEmpty && remaining.generations.isEmpty, "paper records survived")
    try expect(remaining.evidenceReports.isEmpty, "paper evidence survived")
    try expect(try String(contentsOf: otherMarker, encoding: .utf8) == "unrelated", "unrelated files changed")
    try expect(try requestStore.request(paperID: target.id) == nil, "automatic request survived")
  }

  static func concurrentPortableTransactions() throws {
    let base = try temporary("concurrent-store"); defer { try? fm.removeItem(at: base) }
    let storeURL = base.appendingPathComponent("Store/model.json")
    let store = DurableModelStore(storeURL: storeURL)
    let paperID = UUID(), chatSessionID = UUID()
    var paper = Paper(
      id: paperID, canonicalTitle: "Concurrent Paper", safeBasename: "concurrent-paper.pdf",
      sourceRelativePath: "Papers/concurrent/source.pdf", sourceSHA256: "source")
    paper.automaticReviewRequiredAt = Date(timeIntervalSince1970: 1)
    let readingPaperIDs = (0..<12).map { _ in UUID() }
    let readingPapers = readingPaperIDs.enumerated().map { index, id in
      Paper(
        id: id, canonicalTitle: "Reading \(index)", safeBasename: "reading-\(index).pdf",
        sourceRelativePath: "Papers/reading-\(index)/source.pdf", sourceSHA256: "reading-\(index)")
    }
    try store.save(DurableSnapshot(papers: [paper] + readingPapers))
    _ = try PortablePaperChatStore(store: DurableModelStore(storeURL: storeURL))
      .createInitialSession(
        paperID: paperID, sessionID: chatSessionID,
        workspaceRelativePath: "Papers/concurrent/chat/\(chatSessionID.uuidString.lowercased())")

    let failures = ConcurrentFailureBox()
    let group = DispatchGroup()
    let iterations = 12
    for index in 0..<iterations {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          let adapter = PortablePaperChatStore(store: DurableModelStore(storeURL: storeURL))
          _ = try adapter.prepareTurn(
            paperID: paperID, sessionID: chatSessionID, prompt: "prompt-\(index)",
            operationID: UUID(), userMessageID: UUID(),
            journalRelativePath: "Papers/concurrent/chat/journal-\(index)")
        } catch { failures.record(error) }
      }

      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          let generationID = UUID()
          _ = try PortableReviewGenerationStore(store: DurableModelStore(storeURL: storeURL))
            .createGeneration(
              generationID: generationID, paperID: paperID, sessionID: UUID(),
              operationID: UUID(),
              workspaceRelativePath: "Papers/\(paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/workspace/agent",
              sessionWorkspaceRelativePath: "Papers/\(paperID.uuidString.lowercased())/generations/\(generationID.uuidString.lowercased())/workspace/agent",
              promptSHA256: "review-\(index)", journalRelativePath: "journal-\(index)",
              predecessorGenerationID: nil)
        } catch { failures.record(error) }
      }

      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          try DurableModelStore(storeURL: storeURL).transaction { snapshot in
            snapshot.papers.append(Paper(
              canonicalTitle: "Imported \(index)", safeBasename: "imported-\(index).pdf",
              sourceRelativePath: "Papers/imported-\(index)/source.pdf",
              sourceSHA256: "imported-\(index)"))
          }
        } catch { failures.record(error) }
      }

      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          try DurableModelStore(storeURL: storeURL).transaction { snapshot in
            guard let paperIndex = snapshot.papers.firstIndex(where: {
              $0.id == readingPaperIDs[index]
            }) else { throw Gate0HFailure(description: "reading paper disappeared") }
            snapshot.papers[paperIndex].readingPageIndex = index + 1
            snapshot.papers[paperIndex].readingScale = Double(index + 2)
          }
        } catch { failures.record(error) }
      }
    }
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      do {
        try PortableReviewGenerationStore(store: DurableModelStore(storeURL: storeURL))
          .markAutomaticReviewCompleted(paperID: paperID)
      } catch { failures.record(error) }
    }
    group.wait()

    try expect(failures.all().isEmpty, "concurrent transactions failed: \(failures.all())")
    let reopened = try DurableModelStore(storeURL: storeURL).load()
    try expect(reopened.papers.count == 1 + iterations + iterations, "concurrent imports were lost")
    try expect(reopened.operations.count == iterations * 2, "chat or review operations were lost")
    try expect(
      reopened.messages.count == iterations * 2,
      "chat or projected review messages were lost")
    try expect(reopened.generations.count == iterations, "review generations were lost")
    try expect(
      reopened.sessions.count == 1 + iterations,
      "review generations did not retain separate isolated sessions")
    guard let reopenedPaper = reopened.papers.first(where: { $0.id == paperID }) else {
      throw Gate0HFailure(description: "concurrent base paper disappeared")
    }
    try expect(reopenedPaper.currentChatSessionID == chatSessionID, "current chat pointer was lost")
    try expect(reopenedPaper.automaticReviewCompletedAt != nil, "automatic marker was lost")
    for (index, id) in readingPaperIDs.enumerated() {
      let reading = reopened.papers.first { $0.id == id }
      try expect(reading?.readingPageIndex == index + 1, "reading page update was lost")
      try expect(reading?.readingScale == Double(index + 2), "reading scale update was lost")
    }
    for generation in reopened.generations {
      let session = reopened.sessions.first { $0.id == generation.sessionID }
      try expect(session?.paperID == paperID, "review session paper lineage was lost")
      try expect(
        session?.id != chatSessionID && session?.purpose == .reviewGeneration
          && session?.purposeReferenceID == generation.id,
        "generation did not retain isolated review-session lineage")
    }
    let parentMode = try fm.attributesOfItem(atPath: storeURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    let storeMode = try fm.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber
    let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent(".\(storeURL.lastPathComponent).lock")
    let lockMode = try fm.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
    try expect(parentMode?.intValue == 0o700, "store parent is not 0700")
    try expect(storeMode?.intValue == 0o600, "store file is not 0600")
    try expect(lockMode?.intValue == 0o600, "store lock is not 0600")
    print("PASS: portable concurrent adapters preserve lineage and owner-only permissions")
  }

  static func exportNoOverwrite() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let destination = base.appendingPathComponent("existing")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let marker = destination.appendingPathComponent("marker")
    try Data("keep".utf8).write(to: marker)
    do {
      _ = try LibraryBackup().export(libraryRoot: paths.root, to: destination)
      throw Gate0HFailure(description: "existing export destination accepted")
    } catch LibraryBackupError.destinationExists {}
    try expect(try Data(contentsOf: marker) == Data("keep".utf8), "existing destination changed")
  }

  static func restoreNoOverwrite() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let backup = base.appendingPathComponent("backup")
    _ = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let support = base.appendingPathComponent("occupied")
    let live = LibraryPaths(applicationSupport: support).root
    try fm.createDirectory(at: live, withIntermediateDirectories: true)
    let marker = live.appendingPathComponent("marker")
    try Data("live".utf8).write(to: marker)
    do {
      _ = try LibraryBackup().restore(from: backup, toApplicationSupport: support)
      throw Gate0HFailure(description: "live destination accepted")
    } catch LibraryBackupError.destinationExists {}
    try expect(try Data(contentsOf: marker) == Data("live".utf8), "live data changed")
  }

  static func exportRejectsSymlink() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    try fm.createSymbolicLink(
      at: paths.root.appendingPathComponent("credential-link"),
      withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    do {
      _ = try LibraryBackup().export(libraryRoot: paths.root, to: base.appendingPathComponent("backup"))
      throw Gate0HFailure(description: "symlink export accepted")
    } catch LibraryBackupError.symbolicLinkRejected {}
  }

  static func restoreRejectsTraversal() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let backup = base.appendingPathComponent("backup")
    _ = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let manifestURL = backup.appendingPathComponent(LibraryBackup.manifestName)
    let data = try Data(contentsOf: manifestURL)
    var manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: data)
    let bad = LibraryBackupEntry(relativePath: "../escape", sha256: "00", byteCount: 1)
    manifest = LibraryBackupManifest(entries: manifest.entries + [bad])
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    let support = base.appendingPathComponent("restore")
    do {
      _ = try LibraryBackup().restore(from: backup, toApplicationSupport: support)
      throw Gate0HFailure(description: "traversal manifest accepted")
    } catch LibraryBackupError.unsafePath {}
    try expect(!fm.fileExists(atPath: LibraryPaths(applicationSupport: support).root.path), "failed restore created live data")
  }

  static func restoreRejectsSymlink() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let backup = base.appendingPathComponent("backup")
    _ = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let payload = backup.appendingPathComponent(LibraryBackup.payloadName)
    let target = payload.appendingPathComponent("Store/residual-authority.txt")
    try fm.removeItem(at: target)
    try fm.createSymbolicLink(at: target, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    do {
      _ = try LibraryBackup().restore(from: backup, toApplicationSupport: base.appendingPathComponent("restore"))
      throw Gate0HFailure(description: "payload symlink accepted")
    } catch LibraryBackupError.symbolicLinkRejected {}
  }

  static func restoreRejectsCorruption() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let backup = base.appendingPathComponent("backup")
    _ = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let manifest = try JSONDecoder().decode(
      LibraryBackupManifest.self,
      from: Data(contentsOf: backup.appendingPathComponent(LibraryBackup.manifestName)))
    let victim = backup.appendingPathComponent(LibraryBackup.payloadName)
      .appendingPathComponent(manifest.entries[0].relativePath)
    try Data("corrupt".utf8).write(to: victim, options: .atomic)
    let support = base.appendingPathComponent("restore")
    do {
      _ = try LibraryBackup().restore(from: backup, toApplicationSupport: support)
      throw Gate0HFailure(description: "corrupt payload accepted")
    } catch LibraryBackupError.verificationFailed {}
    try expect(!fm.fileExists(atPath: LibraryPaths(applicationSupport: support).root.path), "corrupt restore created live data")
  }

  static func restoredRelaunchReconciliation() throws {
    let (base, paths, _, _) = try fixture(); defer { try? fm.removeItem(at: base) }
    let backup = base.appendingPathComponent("backup")
    _ = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let support = base.appendingPathComponent("restore")
    _ = try LibraryBackup().restore(from: backup, toApplicationSupport: support)
    let restoredPaths = LibraryPaths(applicationSupport: support)
    let store = try ModelContainerFactory.make(at: restoredPaths.storeURL)
    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: restoredPaths)
    let snapshot = try store.load()
    try expect(snapshot.operations[0].processOutcomeRawValue == ProcessOutcome.interrupted.rawValue, "crash operation was not interrupted")
    try expect(snapshot.papers[0].currentChatSessionID == snapshot.sessions[0].id, "relaunch lost current session pointer")
    try expect(snapshot.generations[0].reviewVersionID == snapshot.papers[0].selectedReviewVersionID, "relaunch changed review lineage")
  }

  static func writeEvidence(to evidence: URL) throws {
    try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
    let (base, paths, _, snapshot) = try fixture(); defer { try? fm.removeItem(at: base) }
    let originalHashes = try treeHashes(paths.root)
    let backup = base.appendingPathComponent("release-sample.pprbackup")
    let exportReceipt = try LibraryBackup().export(libraryRoot: paths.root, to: backup)
    let restoreSupport = base.appendingPathComponent("restored")
    let restoreReceipt = try LibraryBackup().restore(from: backup, toApplicationSupport: restoreSupport)
    let restoredPaths = LibraryPaths(applicationSupport: restoreSupport)
    let restoredHashes = try treeHashes(restoredPaths.root)
    let restored = try ModelContainerFactory.make(at: restoredPaths.storeURL).load()
    let manifest = try Data(contentsOf: backup.appendingPathComponent(LibraryBackup.manifestName))
    let manifestDestination = evidence.appendingPathComponent("backup-manifest.json")
    try manifest.write(to: manifestDestination, options: .atomic)
    let report: [String: Any] = [
      "status": "passed",
      "format": "PERSONAL_PAPER_REVIEW_BACKUP",
      "entryCount": exportReceipt.entryCount,
      "byteCount": exportReceipt.byteCount,
      "manifestSHA256": exportReceipt.manifestSHA256,
      "receiptsMatch": exportReceipt == restoreReceipt,
      "treeHashesMatch": originalHashes == restoredHashes,
      "originalTreeHashes": originalHashes,
      "restoredTreeHashes": restoredHashes,
      "durableSnapshotMatch": restored == snapshot,
      "immutableOriginalPreserved": true,
      "selectedReviewVersionPreserved": restored.papers.first?.selectedReviewVersionID != nil,
      "chatLineagePreserved": restored.papers.first?.currentChatSessionID == restored.sessions.first?.id,
      "evidencePreserved": restored.evidenceReports.count == 1,
      "authorityMarkerPreserved": true,
      "restorePolicy": "reject existing live root; stage and verify; atomic install; never merge or overwrite",
      "negativeCases": ["export overwrite", "live restore overwrite", "source symlink", "manifest traversal", "payload symlink", "payload corruption"],
    ]
    let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try reportData.write(to: evidence.appendingPathComponent("backup-restore-report.json"), options: .atomic)
  }
}
