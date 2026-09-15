import Foundation
import PapertrailCore
import SwiftUI

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

@MainActor
final class PaperLibraryController: ObservableObject {
  @Published private(set) var papers: [PaperListItem] = []
  @Published var sortOrder = PaperSortOrder.load() {
    didSet {
      sortOrder.save()
      papers = PaperListSorter.sort(papers, by: sortOrder)
    }
  }
  @Published var notice: String?
  let activityLog = AppActivityLog()
  @Published var codexModel = CodexModelSelection.load() {
    didSet {
      codexModel.save()
      reviewControllers.removeAll()
      chatControllers.removeAll()
      notice = "New Codex operations will use \(codexModel.title) at \(codexEffort.title) effort."
      activityLog.append(level: .info, notice ?? "Codex model changed.")
    }
  }
  @Published var codexEffort = CodexReasoningEffort.load() {
    didSet {
      codexEffort.save()
      reviewControllers.removeAll()
      chatControllers.removeAll()
      notice = "New Codex operations will use \(codexModel.title) at \(codexEffort.title) effort."
      activityLog.append(level: .info, notice ?? "Codex effort changed.")
    }
  }
  let paths: LibraryPaths
  private let codexExecutableProvider = CodexExecutableProvider()
  private let chatRuntimeRegistry = PaperChatRuntimeRegistry()
  private var reviewControllers: [UUID: ReviewGenerationController] = [:]
  private var chatControllers: [UUID: PaperChatController] = [:]
  private var supplementaryMerges: Set<UUID> = []
  private var tagsByPaper: [UUID: [String]] = [:]
  private var latestUserChatByPaper: [UUID: Date] = [:]

  #if PPR_PORTABLE_SCHEMA
    private let store: DurableModelStore
    var durableStore: DurableModelStore { store }

    init(paths: LibraryPaths) {
      self.paths = paths
      self.store = DurableModelStore(storeURL: paths.storeURL)
      reload(refreshChatActivity: true)
      activityLog.append(level: .success, "Paper library opened with \(papers.count) paper(s).")
    }
  #else
    private let container: ModelContainer
    var modelContainer: ModelContainer { container }

    init(paths: LibraryPaths, container: ModelContainer) {
      self.paths = paths
      self.container = container
      reload(refreshChatActivity: true)
      activityLog.append(level: .success, "Paper library opened with \(papers.count) paper(s).")
    }
  #endif

  func prepareImport(from url: URL) throws -> PreparedPDFImport {
    activityLog.append(level: .info, "Preparing PDF import: \(url.lastPathComponent)")
    return try PDFImporter(paths: paths).prepare(url)
  }

  @discardableResult
  func importPDF(from url: URL, title: String) throws -> PaperListItem {
    activityLog.append(level: .info, "Import started: \(title)")
    let importCoordinator = DurablePDFImportCoordinator(paths: paths)
    var intentCleanupNotice: String?
    #if PPR_PORTABLE_SCHEMA
      let existingPapers = try store.read { $0.papers }
      let result = try importCoordinator.begin(
        from: url, title: title, existingPapers: existingPapers)
      try store.transaction { snapshot in
        guard !snapshot.papers.contains(where: { $0.id == result.paper.id }) else {
          throw CocoaError(.fileWriteFileExists)
        }
        snapshot.papers.append(result.paper)
      }
      do { try importCoordinator.complete(paperID: result.paper.id) } catch {
        intentCleanupNotice = " Import recovery cleanup remains pending."
      }
      reload()
    #else
      let context = ModelContext(container)
      let existing = try context.fetch(FetchDescriptor<Paper>())
      let result = try importCoordinator.begin(
        from: url, title: title, existingPapers: existing)
      context.insert(result.paper)
      try context.save()
      do { try importCoordinator.complete(paperID: result.paper.id) } catch {
        intentCleanupNotice = " Import recovery cleanup remains pending."
      }
      reload()
    #endif
    if !result.duplicatePaperIDs.isEmpty {
      notice =
        "Imported a separate lossless copy. Its bytes match \(result.duplicatePaperIDs.count) existing paper(s)."
    } else {
      notice = "Imported \(result.paper.canonicalTitle)."
    }
    if let intentCleanupNotice { notice = (notice ?? "Imported.") + intentCleanupNotice }
    activityLog.append(
      level: intentCleanupNotice == nil ? .success : .warning,
      notice ?? "PDF import completed.")
    guard let item = papers.first(where: { $0.id == result.paper.id }) else {
      throw CocoaError(.coderReadCorrupt)
    }
    return item
  }

  func reviewController(paperID: UUID) -> ReviewGenerationController {
    if let existing = reviewControllers[paperID] { return existing }
    #if PPR_PORTABLE_SCHEMA
      let controller = ReviewGenerationController(
        paperID: paperID, paths: paths, store: store, model: codexModel.commandLineValue,
        reasoningEffort: codexEffort,
        activityLog: activityLog, executableProvider: codexExecutableProvider)
    #else
      let controller = ReviewGenerationController(
        paperID: paperID, paths: paths, container: container, model: codexModel.commandLineValue,
        reasoningEffort: codexEffort,
        activityLog: activityLog, executableProvider: codexExecutableProvider)
    #endif
    reviewControllers[paperID] = controller
    return controller
  }

  func chatController(paperID: UUID) -> PaperChatController {
    if let existing = chatControllers[paperID] { return existing }
    #if PPR_PORTABLE_SCHEMA
      let controller = PaperChatController(
        paperID: paperID, paths: paths, store: store, runtimeRegistry: chatRuntimeRegistry,
        model: codexModel.commandLineValue, reasoningEffort: codexEffort,
        activityLog: activityLog, executableProvider: codexExecutableProvider)
    #else
      let controller = PaperChatController(
        paperID: paperID, paths: paths, container: container,
        runtimeRegistry: chatRuntimeRegistry, model: codexModel.commandLineValue,
        reasoningEffort: codexEffort, activityLog: activityLog,
        executableProvider: codexExecutableProvider)
    #endif
    controller.onUserMessage = { [weak self] date in
      self?.noteChatActivity(paperID: paperID, at: date)
    }
    chatControllers[paperID] = controller
    return controller
  }

  func sourceURL(for paper: PaperListItem) throws -> URL {
    try paths.url(forRelativePath: paper.sourceRelativePath)
  }

  @discardableResult
  func addSupplementaryPDF(to item: PaperListItem, from url: URL) async throws -> PaperListItem {
    guard !supplementaryMerges.contains(item.id) else {
      throw PaperLibraryOperationError.activeOperation
    }
    let hadActiveOperation = reviewControllers[item.id]?.isRunning == true
      || chatControllers[item.id]?.isRunning == true
    supplementaryMerges.insert(item.id)
    defer { supplementaryMerges.remove(item.id) }
    activityLog.append(
      level: .info, "Adding supplementary PDF to \(item.title): \(url.lastPathComponent)")
    let merger = SupplementaryPDFMerger(paths: paths)
    let receipt = try await Task.detached(priority: .userInitiated) {
      try merger.merge(
        paperID: item.id, currentSourceRelativePath: item.sourceRelativePath,
        expectedSourceSHA256: item.sourceSHA256, supplementaryURL: url)
    }.value
    do {
      #if PPR_PORTABLE_SCHEMA
        try store.transaction { snapshot in
          guard let index = snapshot.papers.firstIndex(where: { $0.id == item.id }) else {
            throw PaperLibraryOperationError.paperNotFound
          }
          guard snapshot.papers[index].sourceSHA256 == item.sourceSHA256,
            snapshot.papers[index].sourceRelativePath == item.sourceRelativePath
          else { throw SupplementaryPDFMergeError.currentSourceChanged }
          snapshot.papers[index].sourceRelativePath = receipt.sourceRelativePath
          snapshot.papers[index].sourceSHA256 = receipt.sourceSHA256
          snapshot.papers[index].updatedAt = Date()
        }
      #else
        let context = ModelContext(container)
        guard
          let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
            $0.id == item.id
          })
        else { throw PaperLibraryOperationError.paperNotFound }
        guard paper.sourceSHA256 == item.sourceSHA256,
          paper.sourceRelativePath == item.sourceRelativePath
        else { throw SupplementaryPDFMergeError.currentSourceChanged }
        paper.sourceRelativePath = receipt.sourceRelativePath
        paper.sourceSHA256 = receipt.sourceSHA256
        paper.updatedAt = Date()
        try context.save()
      #endif
    } catch {
      merger.removeCreatedFiles(from: receipt)
      throw error
    }
    reload()
    notice =
      "Added \(receipt.supplementaryPageCount) supplementary page(s). The combined \(receipt.combinedPageCount)-page PDF will be used for new reviews and chats."
      + (hadActiveOperation
        ? " An operation that was already running will finish with its previously staged paper text."
        : "")
    activityLog.append(level: .success, notice ?? "Supplementary PDF added.")
    guard let updated = papers.first(where: { $0.id == item.id }) else {
      throw PaperLibraryOperationError.paperNotFound
    }
    return updated
  }

  func renamePaper(paperID: UUID, title: String) {
    guard let title = FilenameSanitizer.displayTitle(title) else { return }
    do {
      #if PPR_PORTABLE_SCHEMA
        try store.transaction { snapshot in
          guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
            throw CocoaError(.fileNoSuchFile)
          }
          snapshot.papers[index].canonicalTitle = title
          snapshot.papers[index].updatedAt = Date()
        }
      #else
        let context = ModelContext(container)
        guard let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
          $0.id == paperID
        }) else { throw CocoaError(.fileNoSuchFile) }
        paper.canonicalTitle = title
        paper.updatedAt = Date()
        try context.save()
      #endif
      reload()
      activityLog.append(level: .success, "Paper renamed to \(title).")
    } catch {
      notice = "The paper name could not be saved: \(error.localizedDescription)"
      activityLog.append(level: .error, notice ?? "Paper rename failed.")
    }
  }

  func updateReadingState(paperID: UUID, pageIndex: Int, scale: Double) {
    let safePage = max(0, pageIndex)
    let safeScale = scale.isFinite ? min(max(scale, 0.1), 16) : 1
    do {
      #if PPR_PORTABLE_SCHEMA
        try store.transaction { snapshot in
          guard let index = snapshot.papers.firstIndex(where: { $0.id == paperID }) else {
            return
          }
          snapshot.papers[index].readingPageIndex = safePage
          snapshot.papers[index].readingScale = safeScale
          snapshot.papers[index].updatedAt = Date()
        }
      #else
        let context = ModelContext(container)
        guard
          let paper = try context.fetch(FetchDescriptor<Paper>()).first(where: {
            $0.id == paperID
          })
        else { return }
        paper.readingPageIndex = safePage
        paper.readingScale = safeScale
        paper.updatedAt = Date()
        try context.save()
      #endif
      reload()
    } catch {
      notice = "Reading position could not be saved: \(error.localizedDescription)"
      activityLog.append(level: .error, notice ?? "Reading position save failed.")
    }
  }

  func setTags(_ tags: [String], paperID: UUID) throws {
    guard let index = papers.firstIndex(where: { $0.id == paperID }) else {
      throw PaperLibraryOperationError.paperNotFound
    }
    let saved = try PaperTagStore(paths: paths).save(tags, paperID: paperID)
    tagsByPaper[paperID] = saved
    papers[index].tags = saved
  }

  func noteChatActivity(paperID: UUID, at date: Date = Date()) {
    guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
    latestUserChatByPaper[paperID] = max(latestUserChatByPaper[paperID] ?? .distantPast, date)
    papers[index] = papers[index].notingChatActivity(at: date)
    if sortOrder == .recentChat {
      papers = PaperListSorter.sort(papers, by: sortOrder)
    }
  }

  func deletePaper(paperID: UUID) async -> Bool {
    activityLog.append(level: .warning, "Paper deletion requested: \(paperID.uuidString)")
    let reviewController = reviewControllers[paperID]
    let chatController = chatControllers[paperID]
    reviewController?.cancel()
    chatController?.cancel()

    // A running child owns files inside the paper directory. Wait until its controller has
    // observed termination before moving and deleting that exact directory.
    for _ in 0..<100 where reviewController?.isRunning == true || chatController?.isRunning == true {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard reviewController?.isRunning != true, chatController?.isRunning != true else {
      notice = "Deletion is waiting for the active Codex operation to stop. Try again in a moment."
      activityLog.append(level: .warning, notice ?? "Paper deletion is waiting.")
      return false
    }

    do {
      #if PPR_PORTABLE_SCHEMA
        let receipt = try PaperDeletionService(paths: paths, store: store).delete(paperID: paperID)
      #else
        let receipt = try PaperDeletionService(paths: paths, container: container).delete(
          paperID: paperID)
      #endif
      reviewControllers[paperID] = nil
      chatControllers[paperID] = nil
      tagsByPaper[paperID] = nil
      reload()
      guard !receipt.fileCleanupPending else {
        notice =
          "The paper record was deleted, but its Papertrail storage directory could not be fully removed. Check the activity log before retrying cleanup."
        activityLog.append(level: .error, notice ?? "Paper directory cleanup failed.")
        return false
      }
      notice = receipt.automaticRequestCleanupPending
        ? "The paper directory and files were deleted. An automatic-review marker still needs cleanup."
        : "The paper directory and all stored PDF, review, chat, and journal files were deleted."
      activityLog.append(
        level: receipt.automaticRequestCleanupPending ? .warning : .success,
        notice ?? "Paper deletion completed.")
      return true
    } catch {
      reload()
      notice = "The paper could not be deleted safely: \(error.localizedDescription)"
      activityLog.append(level: .error, notice ?? "Paper deletion failed.")
      return false
    }
  }

  private func reload(refreshChatActivity: Bool = false) {
    do {
      #if PPR_PORTABLE_SCHEMA
        let records = try store.read { snapshot in
          if refreshChatActivity {
            var latest: [UUID: Date] = [:]
            for message in snapshot.messages where message.roleRawValue == "user" {
              latest[message.paperID] = max(
                latest[message.paperID] ?? .distantPast, message.createdAt)
            }
            latestUserChatByPaper = latest
          }
          return snapshot.papers
        }
      #else
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<Paper>())
        if refreshChatActivity {
          var messageDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roleRawValue == "user" },
            sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .reverse)])
          messageDescriptor.propertiesToFetch = [\ChatMessage.paperID, \ChatMessage.createdAt]
          let userMessages = try context.fetch(messageDescriptor)
          var latest: [UUID: Date] = [:]
          for message in userMessages where latest[message.paperID] == nil {
            latest[message.paperID] = message.createdAt
          }
          latestUserChatByPaper = latest
        }
      #endif
      // Cache small sidecars so PDF reading-state updates do not reread tag files.
      for record in records where tagsByPaper[record.id] == nil {
        do {
          tagsByPaper[record.id] = try PaperTagStore(paths: paths).load(paperID: record.id)
        } catch {
          notice = "Tags could not be loaded: \(error.localizedDescription)"
          activityLog.append(level: .error, notice ?? "Tag load failed.")
        }
      }
      papers = records.map {
        PaperListItem(
          id: $0.id, title: $0.canonicalTitle, sourceRelativePath: $0.sourceRelativePath,
          sourceSHA256: $0.sourceSHA256, pageIndex: $0.readingPageIndex,
          scale: $0.readingScale, createdAt: $0.createdAt,
          lastChatAt: latestUserChatByPaper[$0.id], tags: tagsByPaper[$0.id] ?? [])
      }
      papers = PaperListSorter.sort(papers, by: sortOrder)
    } catch {
      notice = "The paper library could not be loaded: \(error.localizedDescription)"
      activityLog.append(level: .error, notice ?? "Paper library load failed.")
    }
  }

  func record(
    level: AppActivityLogLevel = .info,
    source: AppActivityLogSource = .app,
    _ message: String
  ) {
    activityLog.append(source: source, level: level, message)
  }

}

enum PaperLibraryOperationError: Error, LocalizedError {
  case activeOperation
  case paperNotFound

  var errorDescription: String? {
    switch self {
    case .activeOperation:
      "A supplementary PDF is already being merged into this paper."
    case .paperNotFound:
      "The selected paper is no longer in the library."
    }
  }
}
