import Foundation

#if canImport(PapertrailCore)
  import PapertrailCore
#endif

@main struct PaperTagStoreTests {
  static func main() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "papertrail-tag-store-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? fileManager.removeItem(at: testRoot) }

    let applicationSupport = testRoot.appendingPathComponent("ApplicationSupport", isDirectory: true)
    let paths = LibraryPaths(applicationSupport: applicationSupport)
    try paths.createRootTopology()
    let store = PaperTagStore(paths: paths)
    let firstPaper = UUID()
    let secondPaper = UUID()

    let initiallyMissing = try store.load(paperID: firstPaper)
    precondition(initiallyMissing.isEmpty)
    try createPaper(firstPaper, paths: paths, fileManager: fileManager)
    try createPaper(secondPaper, paths: paths, fileManager: fileManager)

    let saved = try store.save(
      ["  Machine Learning  ", "", "machine learning", "검증", "  \n "],
      paperID: firstPaper)
    precondition(saved == ["Machine Learning", "검증"])
    let reloaded = try PaperTagStore(paths: paths).load(paperID: firstPaper)
    precondition(reloaded == saved)
    let isolated = try store.load(paperID: secondPaper)
    precondition(isolated.isEmpty)

    let removed = try store.save([], paperID: firstPaper)
    precondition(removed.isEmpty)
    let reloadedRemoval = try store.load(paperID: firstPaper)
    precondition(reloadedRemoval.isEmpty)

    let maximumLengthTag = String(repeating: "가", count: 64)
    let maximumLengthSaved = try store.save([maximumLengthTag], paperID: firstPaper)
    precondition(maximumLengthSaved == [maximumLengthTag])
    let previousContents = try Data(contentsOf: paths.paper(firstPaper).appendingPathComponent("tags.json"))

    do {
      _ = try store.save([String(repeating: "가", count: 65)], paperID: firstPaper)
      preconditionFailure("A tag longer than 64 characters must be rejected")
    } catch let error as PaperTagStoreError {
      guard case .tagTooLong(_, maximumCharacters: 64) = error else { throw error }
    }
    let contentsAfterRejectedTag = try Data(
      contentsOf: paths.paper(firstPaper).appendingPathComponent("tags.json"))
    precondition(contentsAfterRejectedTag == previousContents)

    let maximumTags = (0..<32).map { "tag-\($0)" }
    let maximumTagsSaved = try store.save(maximumTags, paperID: firstPaper)
    precondition(maximumTagsSaved == maximumTags)
    do {
      _ = try store.save((0..<33).map { "tag-\($0)" }, paperID: firstPaper)
      preconditionFailure("More than 32 normalized tags must be rejected")
    } catch let error as PaperTagStoreError {
      guard case .tooManyTags(actual: 33, maximum: 32) = error else { throw error }
    }
    let tagsAfterRejectedCount = try store.load(paperID: firstPaper)
    precondition(tagsAfterRejectedCount == maximumTags)

    let deletedPaper = UUID()
    do {
      _ = try store.save(["orphan"], paperID: deletedPaper)
      preconditionFailure("Saving must not recreate a deleted paper directory")
    } catch let error as PaperTagStoreError {
      precondition(error == .paperDirectoryMissing(deletedPaper))
    }
    precondition(!fileManager.fileExists(atPath: paths.paper(deletedPaper).path))

    let external = testRoot.appendingPathComponent("external-tags.json")
    try Data("outside".utf8).write(to: external)
    let linkedTags = paths.paper(secondPaper).appendingPathComponent("tags.json")
    try fileManager.createSymbolicLink(at: linkedTags, withDestinationURL: external)
    do {
      _ = try store.load(paperID: secondPaper)
      preconditionFailure("A symbolic-link tag sidecar must be rejected")
    } catch let error as LibraryPathError {
      guard case .unsafeComponent = error else { throw error }
    }
    do {
      _ = try store.save(["safe"], paperID: secondPaper)
      preconditionFailure("Saving must not replace a symbolic-link tag sidecar")
    } catch let error as LibraryPathError {
      guard case .unsafeComponent = error else { throw error }
    }
    let externalContents = try String(contentsOf: external, encoding: .utf8)
    precondition(externalContents == "outside")

    print(
      "PASS PaperTagStore: persistence, paper isolation, normalization, removal, limits, missing-paper and symbolic-link safety")
  }

  private static func createPaper(
    _ paperID: UUID, paths: LibraryPaths, fileManager: FileManager
  ) throws {
    try fileManager.createDirectory(
      at: paths.paper(paperID), withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }
}
