import Foundation
import PapertrailCore

struct Gate0CTestFailure: Error, CustomStringConvertible { let description: String }

private final class MissingApplicationSupportFileManager: FileManager {
  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    []
  }
}

@main
enum Gate0CTests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("Application Support topology", testTopology),
      ("legacy Papertrail library migration", testLibraryMigration),
      ("library migration conflict preservation", testLibraryMigrationConflict),
      ("immutable writes and version paths", testImmutableStorage),
      ("versioned durable schema round trip", testDurableSchema),
      ("single current-chat pointer", testCurrentPointer),
      ("invalid pointer fails closed", testInvalidPointer),
      ("legacy migration never guesses", testLegacyMigration),
      ("launch coordinator imports legacy V0", testCoordinatorLegacyImport),
      ("launch coordinator preserves pointer precedence", testCoordinatorLegacyPrecedence),
      ("invalid legacy V0 is recoverable", testInvalidLegacyImport),
      ("selected review record loss is detected", testMissingSelectedReviewRecord),
      ("launch recovery is non-destructive", testRecovery),
      ("paper workspace shell contract", testWorkspaceShell),
    ]
    for (name, test) in tests {
      try test()
      print("PASS: \(name)")
    }
    print("PASS: \(tests.count) Gate 0C test groups")
  }

  private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws
  {
    guard try condition() else { throw Gate0CTestFailure(description: message) }
  }

  private static func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func testTopology() throws {
    do {
      _ = try LibraryPaths.system(fileManager: MissingApplicationSupportFileManager())
      throw Gate0CTestFailure(description: "missing Application Support was silently replaced")
    } catch LibraryPathError.rootUnavailable {}

    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    try expect(paths.root.lastPathComponent == "Papertrail", "wrong library root")
    try expect(FileManager.default.fileExists(atPath: paths.storeDirectory.path), "Store missing")
    try expect(FileManager.default.fileExists(atPath: paths.papersDirectory.path), "Papers missing")
    let paper = UUID()
    let generation = UUID()
    let version = UUID()
    let session = UUID()
    try expect(
      paths.reviewVersion(version, generationID: generation, paperID: paper).path
        .contains(
          "/generations/\(generation.uuidString.lowercased())/review/\(version.uuidString.lowercased())"
        ),
      "review version topology drifted")
    try expect(
      paths.chatWorkspace(session, paperID: paper).path.hasSuffix("/workspace/agent"),
      "chat workspace topology drifted")
    let appSource = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/PapertrailApp/PapertrailApp.swift"),
      encoding: .utf8)
    try expect(
      !appSource.contains("fallbackSupport") && !appSource.contains("try? LibraryPaths.system"),
      "app startup still silently invents an Application Support path")
  }

  private static func testLibraryMigration() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let legacyRoot = support.appendingPathComponent("PersonalPaperReview", isDirectory: true)
    let legacyStore = legacyRoot.appendingPathComponent(
      "Store/PersonalPaperReview.store", isDirectory: false)
    try FileManager.default.createDirectory(
      at: legacyStore.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("legacy-library".utf8)
    try original.write(to: legacyStore)

    let outcome = try LibraryPaths.migrateLegacyLibraryIfNeeded(applicationSupport: support)
    let paths = LibraryPaths(applicationSupport: support)
    try expect(outcome == .migratedLegacyLibrary, "legacy library was not migrated")
    try expect(!FileManager.default.fileExists(atPath: legacyRoot.path), "legacy root remained")
    try expect(try Data(contentsOf: paths.storeURL) == original, "legacy store bytes changed")
    try expect(paths.root.lastPathComponent == "Papertrail", "migration used wrong destination")
  }

  private static func testLibraryMigrationConflict() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let legacyRoot = support.appendingPathComponent("PersonalPaperReview", isDirectory: true)
    let destinationRoot = support.appendingPathComponent("Papertrail", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let legacySentinel = legacyRoot.appendingPathComponent("legacy.txt")
    let destinationSentinel = destinationRoot.appendingPathComponent("current.txt")
    try Data("legacy".utf8).write(to: legacySentinel)
    try Data("current".utf8).write(to: destinationSentinel)

    let outcome = try LibraryPaths.migrateLegacyLibraryIfNeeded(applicationSupport: support)
    try expect(outcome == .destinationAlreadyExists, "destination conflict was not reported")
    try expect(
      FileManager.default.fileExists(atPath: legacySentinel.path),
      "legacy data was removed during a conflict")
    try expect(
      FileManager.default.fileExists(atPath: destinationSentinel.path),
      "destination data was overwritten during a conflict")
  }

  private static func testImmutableStorage() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let store = ImmutableFileStore(paths: paths)
    let paper = UUID()
    let generation = UUID()
    let first = paths.reviewVersion(UUID(), generationID: generation, paperID: paper)
      .appendingPathComponent("index.html")
    let second = paths.reviewVersion(UUID(), generationID: generation, paperID: paper)
      .appendingPathComponent("index.html")
    let data = Data("immutable review".utf8)
    let receipt = try store.write(data, to: first)
    try expect(receipt.sha256 == ImmutableFileStore.sha256(data), "hash mismatch")
    try expect(first.path != second.path, "versions collided")
    do {
      _ = try store.write(Data("overwrite".utf8), to: first)
      throw Gate0CTestFailure(description: "immutable destination was overwritten")
    } catch ImmutableFileStoreError.destinationExists {}
    try expect(try Data(contentsOf: first) == data, "prior bytes changed")
  }

  private static func testDurableSchema() throws {
    try expect(
      PersonalPaperReviewSchemaV1.versionIdentifier == StorageSchemaVersion(1, 0, 0),
      "schema version is not frozen")
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ModelContainerFactory.make(at: root.appendingPathComponent("Store/data.json"))
    let paperID = UUID()
    var paper = Paper(
      id: paperID, canonicalTitle: "Paper", safeBasename: "paper",
      sourceRelativePath: "Papers/p/source/paper.pdf", sourceSHA256: "abc")
    let session = CodexSession(
      paperID: paperID, purpose: .paperChat,
      workspaceRelativePath: "Papers/p/chat/sessions/s/workspace", lifecycle: .active)
    paper.currentChatSessionID = session.id
    try store.save(DurableSnapshot(papers: [paper], sessions: [session]))
    let restored = try store.load()
    let restoredPapers = restored.papers
    let restoredSessions = restored.sessions
    try expect(
      restoredPapers.count == 1 && restoredSessions.count == 1, "schema did not round-trip")
    try expect(
      restoredSessions[0].isCurrentChat(for: restoredPapers[0]), "derived current chat failed")
    let labels = Mirror(reflecting: restoredSessions[0]).children.compactMap(\.label)
    try expect(!labels.contains("isCurrentChat"), "a second current-chat flag was persisted")
    let swiftDataSource = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/PapertrailCore/Models/SchemaV1.swift"),
      encoding: .utf8)
    try expect(swiftDataSource.contains("@Model"), "full-Xcode SwiftData schema is absent")
    try expect(swiftDataSource.contains("VersionedSchema"), "SwiftData schema is not versioned")
    let packageSource = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Package.swift"), encoding: .utf8)
    try expect(
      packageSource.contains("selectedDeveloperDirectory.contains(\"CommandLineTools\")"),
      "production configuration does not prefer SwiftData")
    let coordinatorSource = try String(
      contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
          "Sources/PapertrailCore/Persistence/ApplicationLaunchCoordinator.swift"),
      encoding: .utf8)
    try expect(
      coordinatorSource.contains("LegacyCurrentChatImporter"),
      "SwiftData launch path lacks truthful V0 import")
  }

  private static func testCurrentPointer() throws {
    let paper = UUID()
    let current = UUID()
    let other = UUID()
    let generation = UUID()
    let sessions = [
      SessionSnapshot(id: current, paperID: paper, purpose: .paperChat),
      SessionSnapshot(id: other, paperID: paper, purpose: .paperChat),
      SessionSnapshot(id: generation, paperID: paper, purpose: .reviewGeneration),
    ]
    let result = LaunchReconciler().reconcileCurrentChat(
      paperID: paper, currentPointer: current, sessions: sessions)
    try expect(result.currentChatSessionID == current, "valid pointer changed")
    try expect(result.historicalSessionIDs == [other], "unpointed chat was not historical")
  }

  private static func testInvalidPointer() throws {
    let paper = UUID()
    let otherPaper = UUID()
    let crossPaper = UUID()
    let review = UUID()
    for sessions in [
      [SessionSnapshot(id: crossPaper, paperID: otherPaper, purpose: .paperChat)],
      [SessionSnapshot(id: review, paperID: paper, purpose: .reviewGeneration)],
      [],
    ] {
      let pointer = sessions.first?.id ?? UUID()
      let result = LaunchReconciler().reconcileCurrentChat(
        paperID: paper, currentPointer: pointer, sessions: sessions)
      try expect(result.currentChatSessionID == nil, "invalid pointer survived")
      try expect(result.repairState == .currentChatPointerInvalid, "repair state missing")
    }
  }

  private static func testLegacyMigration() throws {
    let paper = UUID()
    let one = UUID()
    let two = UUID()
    let sessions = [
      SessionSnapshot(id: one, paperID: paper, purpose: .paperChat),
      SessionSnapshot(id: two, paperID: paper, purpose: .paperChat),
    ]
    let reconciler = LaunchReconciler()
    let unique = reconciler.reconcileCurrentChat(
      paperID: paper, currentPointer: nil, sessions: sessions,
      legacyMigrationRequested: true, legacyCurrentSessionIDs: [one])
    try expect(
      unique.currentChatSessionID == one && unique.repairState == .none, "unique legacy flag failed"
    )
    for flags: Set<UUID> in [[], [one, two], [UUID()]] {
      let result = reconciler.reconcileCurrentChat(
        paperID: paper, currentPointer: nil, sessions: sessions,
        legacyMigrationRequested: true, legacyCurrentSessionIDs: flags)
      try expect(result.currentChatSessionID == nil, "legacy reconciliation guessed")
      try expect(result.repairState == .legacyCurrentChatAmbiguous, "legacy repair missing")
    }
  }

  private static func testCoordinatorLegacyImport() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let paperID = UUID()
    let selected = UUID()
    let historical = UUID()
    let sourceRelative = "Papers/\(paperID)/source/paper.pdf"
    try createStoredSource(relativePath: sourceRelative, paths: paths)
    let paper = Paper(
      id: paperID, canonicalTitle: "Legacy", safeBasename: "legacy",
      sourceRelativePath: sourceRelative, sourceSHA256: "hash")
    let selectedSession = CodexSession(
      id: selected, paperID: paperID, purpose: .paperChat,
      workspaceRelativePath: "chat/selected", lifecycle: .active)
    let historicalSession = CodexSession(
      id: historical, paperID: paperID, purpose: .paperChat,
      workspaceRelativePath: "chat/historical", lifecycle: .active)
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(
      DurableSnapshot(papers: [paper], sessions: [selectedSession, historicalSession]))
    try writeLegacy(
      LegacyCurrentChatDocumentV0(records: [
        LegacyCurrentChatRecordV0(
          paperID: paperID, sessionID: selected, isCurrentChat: true)
      ]), paths: paths)

    _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    let migrated = try store.load()
    try expect(migrated.papers[0].currentChatSessionID == selected, "actual V0 flag not imported")
    try expect(
      migrated.sessions.first(where: { $0.id == historical })?.lifecycle == .historical,
      "unpointed active chat was not persisted as historical")
    try expect(
      migrated.sessions.first(where: { $0.id == selected })?.lifecycle == .active,
      "authoritative current chat was incorrectly made historical")
  }

  private static func testCoordinatorLegacyPrecedence() throws {
    for mode in ["pointer-wins", "multiple", "zero"] {
      let support = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: support) }
      let paths = LibraryPaths(applicationSupport: support)
      try paths.createRootTopology()
      let paperID = UUID()
      let first = UUID()
      let second = UUID()
      let sourceRelative = "Papers/\(paperID)/source/paper.pdf"
      try createStoredSource(relativePath: sourceRelative, paths: paths)
      var paper = Paper(
        id: paperID, canonicalTitle: "Legacy", safeBasename: "legacy",
        sourceRelativePath: sourceRelative, sourceSHA256: "hash")
      if mode == "pointer-wins" { paper.currentChatSessionID = second }
      let sessions = [
        CodexSession(
          id: first, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: "chat/first", lifecycle: .active),
        CodexSession(
          id: second, paperID: paperID, purpose: .paperChat,
          workspaceRelativePath: "chat/second", lifecycle: .active),
      ]
      let flagged: [LegacyCurrentChatRecordV0]
      switch mode {
      case "pointer-wins":
        flagged = [.init(paperID: paperID, sessionID: first, isCurrentChat: true)]
      case "multiple":
        flagged = [
          .init(paperID: paperID, sessionID: first, isCurrentChat: true),
          .init(paperID: paperID, sessionID: second, isCurrentChat: true),
        ]
      default:
        flagged = []
      }
      let store = try ModelContainerFactory.make(at: paths.storeURL)
      try store.save(DurableSnapshot(papers: [paper], sessions: sessions))
      try writeLegacy(LegacyCurrentChatDocumentV0(records: flagged), paths: paths)
      _ = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
      let reconciled = try store.load()
      if mode == "pointer-wins" {
        try expect(reconciled.papers[0].currentChatSessionID == second, "legacy flag beat pointer")
        try expect(
          reconciled.sessions.first(where: { $0.id == first })?.lifecycle == .historical,
          "pointer precedence did not persist historical state")
      } else {
        try expect(reconciled.papers[0].currentChatSessionID == nil, "ambiguous V0 was guessed")
        try expect(
          reconciled.papers[0].repairState == .legacyCurrentChatAmbiguous,
          "ambiguous V0 repair state missing")
      }
    }
  }

  private static func testMissingSelectedReviewRecord() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let paperID = UUID()
    let selectedVersion = UUID()
    let sourceRelative = "Papers/\(paperID)/source/paper.pdf"
    try createStoredSource(relativePath: sourceRelative, paths: paths)
    var paper = Paper(
      id: paperID, canonicalTitle: "Review", safeBasename: "review",
      sourceRelativePath: sourceRelative, sourceSHA256: "hash")
    paper.selectedReviewVersionID = selectedVersion
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(DurableSnapshot(papers: [paper], generations: []))
    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(
      issues.contains(.missingSelectedReview(paperID: paperID, versionID: selectedVersion)),
      "selected version without generation/path was hidden")
    try expect(
      try store.load().papers[0].repairState == .selectedReviewMissing,
      "missing selected review repair was not persisted")
  }

  private static func testInvalidLegacyImport() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let paperID = UUID()
    let sourceRelative = "Papers/\(paperID)/source/paper.pdf"
    try createStoredSource(relativePath: sourceRelative, paths: paths)
    let paper = Paper(
      id: paperID, canonicalTitle: "Legacy", safeBasename: "legacy",
      sourceRelativePath: sourceRelative, sourceSHA256: "hash")
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    try store.save(DurableSnapshot(papers: [paper]))
    try Data("not-json".utf8).write(to: paths.legacyCurrentChatV0URL)
    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(
      issues.contains(where: {
        if case .legacyImportInvalid = $0 { return true }
        return false
      }), "invalid legacy data was not surfaced")
    try expect(
      try store.load().papers[0].currentChatSessionID == nil,
      "invalid legacy data invented a current chat")
    try expect(
      FileManager.default.fileExists(atPath: paths.legacyCurrentChatV0URL.path),
      "invalid legacy data was silently deleted")
  }

  private static func createStoredSource(relativePath: String, paths: LibraryPaths) throws {
    let source = paths.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("pdf".utf8).write(to: source)
  }

  private static func writeLegacy(_ document: LegacyCurrentChatDocumentV0, paths: LibraryPaths)
    throws
  {
    try JSONEncoder().encode(document).write(to: paths.legacyCurrentChatV0URL)
  }

  private static func testRecovery() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let paths = LibraryPaths(applicationSupport: support)
    try paths.createRootTopology()
    let partial = paths.root.appendingPathComponent(".partial-recoverable")
    try Data("staged".utf8).write(to: partial)
    let paperID = UUID()
    let version = UUID()
    let store = try ModelContainerFactory.make(at: paths.storeURL)
    var paper = Paper(
      id: paperID, canonicalTitle: "Missing", safeBasename: "missing",
      sourceRelativePath: "Papers/missing/source.pdf", sourceSHA256: "missing")
    paper.currentChatSessionID = UUID()
    paper.selectedReviewVersionID = version
    let generation = ReviewGeneration(
      paperID: paperID, sessionID: UUID(), workspaceRelativePath: "Papers/missing/workspace")
    var selectedGeneration = generation
    selectedGeneration.reviewVersionID = version
    selectedGeneration.reviewRelativePath = "Papers/missing/review"
    try store.save(DurableSnapshot(papers: [paper], generations: [selectedGeneration]))
    let issues = try ApplicationLaunchCoordinator.reconcile(store: store, paths: paths)
    try expect(
      issues.contains(.missingSource(paperID: paperID, relativePath: "Papers/missing/source.pdf")),
      "missing source hidden")
    try expect(
      issues.contains(.missingSelectedReview(paperID: paperID, versionID: version)),
      "missing review hidden")
    try expect(
      issues.contains(.recoverablePartial(relativePath: ".partial-recoverable")), "partial hidden")
    try expect(
      FileManager.default.fileExists(atPath: partial.path),
      "reconciliation auto-deleted recovery data")
    let repaired = try store.load().papers[0]
    try expect(repaired.currentChatSessionID == nil, "launch coordinator retained dangling pointer")
    try expect(repaired.repairState == .sourceMissing, "launch coordinator did not persist repair")
  }

  private static func testWorkspaceShell() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let source = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailApp/PaperWorkspaceViews.swift"),
      encoding: .utf8)
    for required in [
      "NavigationSplitView", "PDF reader", "Review reader", "Paper chat", "Private local storage",
      "launchRepairMessage",
    ] {
      try expect(source.contains(required), "workspace shell lacks \(required)")
    }
    try expect(!source.contains("API key"), "excluded cloud credential surface present")
    let appSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/PapertrailApp/PapertrailApp.swift"),
      encoding: .utf8)
    try expect(!appSource.contains("fatalError"), "library initialization still terminates the app")
    try expect(appSource.contains("needs repair"), "recoverable launch failure is not surfaced")
  }
}
