import Foundation

public enum LibraryPathError: Error, Equatable, LocalizedError, CustomStringConvertible {
  case unsafeComponent(String)
  case rootUnavailable

  public var description: String {
    switch self {
    case .unsafeComponent(let path):
      "The path is outside the Papertrail library or crosses a symbolic link: \(path)"
    case .rootUnavailable:
      "The user Application Support directory is unavailable."
    }
  }

  public var errorDescription: String? { description }
}

public enum LibraryMigrationOutcome: Equatable, Sendable {
  case noLegacyLibrary
  case migratedLegacyLibrary
  case destinationAlreadyExists
}

public struct LibraryPaths: Sendable {
  public let root: URL

  public init(applicationSupport: URL) {
    self.root = applicationSupport.appendingPathComponent("Papertrail", isDirectory: true)
  }

  public static func system(fileManager: FileManager = .default) throws -> LibraryPaths {
    guard
      let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { throw LibraryPathError.rootUnavailable }
    _ = try migrateLegacyLibraryIfNeeded(applicationSupport: support, fileManager: fileManager)
    return LibraryPaths(applicationSupport: support)
  }

  /// Moves the pre-Papertrail library only when the destination does not exist.
  /// A destination conflict always leaves the legacy library untouched.
  @discardableResult
  public static func migrateLegacyLibraryIfNeeded(
    applicationSupport: URL, fileManager: FileManager = .default
  ) throws -> LibraryMigrationOutcome {
    let legacyRoot = applicationSupport.appendingPathComponent(
      "PersonalPaperReview", isDirectory: true)
    let destinationRoot = applicationSupport.appendingPathComponent("Papertrail", isDirectory: true)

    guard fileManager.fileExists(atPath: legacyRoot.path) else {
      return .noLegacyLibrary
    }
    guard !fileManager.fileExists(atPath: destinationRoot.path) else {
      return .destinationAlreadyExists
    }

    do {
      try fileManager.moveItem(at: legacyRoot, to: destinationRoot)
      return .migratedLegacyLibrary
    } catch {
      // Another process may have created the destination between the checks. FileManager's move
      // does not overwrite it, so report the conflict while retaining the legacy source.
      if fileManager.fileExists(atPath: destinationRoot.path)
        && fileManager.fileExists(atPath: legacyRoot.path)
      {
        return .destinationAlreadyExists
      }
      throw error
    }
  }

  public var storeDirectory: URL { root.appendingPathComponent("Store", isDirectory: true) }
  public var storeURL: URL {
    #if !PPR_PORTABLE_SCHEMA
      // Keep the production SwiftData database distinct from the portable JSON test store.
      // Sharing one filename lets a test build leave JSON where SQLite is expected.
      return storeDirectory.appendingPathComponent("Papertrail.sqlite")
    #else
    let papertrailStore = storeDirectory.appendingPathComponent("Papertrail.store")
    let legacyStore = storeDirectory.appendingPathComponent("PersonalPaperReview.store")
    if FileManager.default.fileExists(atPath: legacyStore.path)
      && !FileManager.default.fileExists(atPath: papertrailStore.path)
    {
      return legacyStore
    }
    return papertrailStore
    #endif
  }
  public var automaticReviewRequestsURL: URL {
    storeDirectory.appendingPathComponent("automatic-review-requests.json")
  }
  public var importIntentsDirectory: URL {
    storeDirectory.appendingPathComponent("ImportIntents", isDirectory: true)
  }
  public var legacyCurrentChatV0URL: URL {
    storeDirectory.appendingPathComponent("legacy-current-chat-v0.json")
  }
  public var papersDirectory: URL { root.appendingPathComponent("Papers", isDirectory: true) }

  public func paper(_ id: UUID) -> URL {
    papersDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  public func sourceDirectory(paperID: UUID) -> URL {
    paper(paperID).appendingPathComponent("source", isDirectory: true)
  }

  public func generation(_ id: UUID, paperID: UUID) -> URL {
    paper(paperID).appendingPathComponent("generations", isDirectory: true)
      .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  public func generationWorkspace(_ id: UUID, paperID: UUID) -> URL {
    generation(id, paperID: paperID).appendingPathComponent("workspace", isDirectory: true)
      .appendingPathComponent("agent", isDirectory: true)
  }

  public func reviewVersion(_ versionID: UUID, generationID: UUID, paperID: UUID) -> URL {
    generation(generationID, paperID: paperID).appendingPathComponent("review", isDirectory: true)
      .appendingPathComponent(versionID.uuidString.lowercased(), isDirectory: true)
  }

  public func chatWorkspace(_ sessionID: UUID, paperID: UUID) -> URL {
    paper(paperID).appendingPathComponent("chat", isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("workspace", isDirectory: true)
      .appendingPathComponent("agent", isDirectory: true)
  }

  public func operationDirectory(operationID: UUID, forAgentWorkspace workspace: URL) -> URL {
    workspace.deletingLastPathComponent()
      .appendingPathComponent("operations", isDirectory: true)
      .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
  }

  public func createRootTopology(fileManager: FileManager = .default) throws {
    for directory in [root, storeDirectory, papersDirectory] {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
  }

  public func relativePath(for url: URL) throws -> String {
    guard root.isFileURL, url.isFileURL else {
      throw LibraryPathError.unsafeComponent(url.path)
    }
    let canonicalRoot = Self.canonicalizedIncludingMissingDescendants(root)
    let canonicalURL = Self.canonicalizedIncludingMissingDescendants(url)
    let prefix = canonicalRoot.path + "/"
    guard canonicalURL.path.hasPrefix(prefix) else {
      throw LibraryPathError.unsafeComponent(url.path)
    }
    return String(canonicalURL.path.dropFirst(prefix.count))
  }

  /// Resolves every existing ancestor before reattaching a missing suffix. Foundation otherwise
  /// resolves `/tmp` differently depending on whether the leaf exists, which breaks both secure
  /// containment checks and crash-safe writes to not-yet-created destinations.
  private static func canonicalizedIncludingMissingDescendants(
    _ url: URL, fileManager: FileManager = .default
  ) -> URL {
    var ancestor = url.standardizedFileURL
    var missingComponents: [String] = []
    while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
      missingComponents.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    var canonical = ancestor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
      canonical.appendPathComponent(component)
    }
    return canonical.standardizedFileURL
  }

  public func url(forRelativePath relativePath: String) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
      throw LibraryPathError.unsafeComponent(relativePath)
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw LibraryPathError.unsafeComponent(relativePath)
    }
    let candidate = components.reduce(root) { partial, component in
      partial.appendingPathComponent(String(component), isDirectory: false)
    }
    _ = try self.relativePath(for: candidate)
    return candidate
  }
}
