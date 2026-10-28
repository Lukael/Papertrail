import CoreGraphics
import Foundation

#if canImport(PapertrailCore)
  import PapertrailCore
#endif

@main struct PaperNoteStoreTests {
  static func main() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "papertrail-note-store-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? fileManager.removeItem(at: testRoot) }
    let paths = LibraryPaths(
      applicationSupport: testRoot.appendingPathComponent("ApplicationSupport", isDirectory: true))
    try paths.createRootTopology()
    let store = PaperNoteStore(paths: paths)
    let paper = UUID()
    let missing = try store.load(paperID: paper)
    precondition(missing.isEmpty, "a missing note file must read as empty")

    try fileManager.createDirectory(at: paths.paper(paper), withIntermediateDirectories: true)
    let notes = [
      PaperNote(
        source: .pdf, pageNumber: 3, rects: [CGRect(x: 72, y: 600, width: 300, height: 14)],
        text: "followed by bundle adjustment", comment: "왜 BA가 필요한가?"),
      PaperNote(source: .chat, text: "답변 **본문**", messageID: UUID()),
    ]
    try store.save(notes, paperID: paper)
    let reloaded = try PaperNoteStore(paths: paths).load(paperID: paper)
    precondition(reloaded == notes, "notes did not round-trip")

    let oversized = PaperNote(
      source: .chat, text: String(repeating: "가", count: PaperNoteStore.maximumNoteBytes))
    do {
      try store.save(notes + [oversized], paperID: paper)
      preconditionFailure("an oversized note was saved")
    } catch PaperNoteStoreError.noteTooLarge {}
    let afterRejection = try store.load(paperID: paper)
    precondition(afterRejection == notes, "a rejected save replaced the notes")

    let noteFile = paths.paper(paper).appendingPathComponent("notes.json")
    // The app shows no notes when the file is unreadable; the next save must not wipe it.
    let unreadable = Data("{ not json".utf8)
    try unreadable.write(to: noteFile)
    precondition((try? store.save([notes[0]], paperID: paper)) == nil, "an unreadable note file was replaced")
    let afterBlockedSave = try Data(contentsOf: noteFile)
    precondition(afterBlockedSave == unreadable, "an unreadable note file was changed")

    try fileManager.removeItem(at: noteFile)
    try fileManager.createSymbolicLink(at: noteFile, withDestinationURL: testRoot)
    precondition((try? store.load(paperID: paper)) == nil, "a symlinked note file was read")
    print("PASS paper note store: round trip, size limit, unreadable-file protection, symlink refusal")
  }
}
