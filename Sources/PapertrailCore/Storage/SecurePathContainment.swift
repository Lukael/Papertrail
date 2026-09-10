import Foundation

public enum SecurePathContainmentError: Error, Equatable {
  case pathDoesNotExist(String)
  case symbolicLinkComponent(String)
  case outsideRoot(path: String, root: String)
}

public enum SecurePathContainment {
  public static func requireExisting(_ candidate: URL, inside root: URL) throws -> URL {
    let fm = FileManager.default
    let absoluteRoot = root.standardizedFileURL
    let absoluteCandidate = candidate.standardizedFileURL
    try rejectSymlinkComponents(from: absoluteRoot, through: absoluteCandidate, fileManager: fm)
    guard fm.fileExists(atPath: absoluteRoot.path) else {
      throw SecurePathContainmentError.pathDoesNotExist(absoluteRoot.path)
    }
    guard fm.fileExists(atPath: absoluteCandidate.path) else {
      throw SecurePathContainmentError.pathDoesNotExist(absoluteCandidate.path)
    }
    let canonicalRoot = absoluteRoot.resolvingSymlinksInPath().standardizedFileURL
    let canonicalCandidate = absoluteCandidate.resolvingSymlinksInPath().standardizedFileURL
    let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    guard canonicalCandidate.path == canonicalRoot.path || canonicalCandidate.path.hasPrefix(prefix) else {
      throw SecurePathContainmentError.outsideRoot(
        path: canonicalCandidate.path, root: canonicalRoot.path)
    }
    return canonicalCandidate
  }

  public static func rejectSymlinkComponents(
    from root: URL, through candidate: URL, fileManager: FileManager = .default
  ) throws {
    // Preserve the caller's lexical root spelling here. Foundation canonicalizes an existing
    // `/private/tmp/...` root to `/tmp/...`, but leaves a not-yet-created descendant spelled as
    // `/private/tmp/...`; standardizing the two independently therefore creates a false escape.
    let rootPath = root.path
    let candidatePath = candidate.path
    let lexicalPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard candidatePath == rootPath || candidatePath.hasPrefix(lexicalPrefix) else {
      throw SecurePathContainmentError.outsideRoot(path: candidatePath, root: rootPath)
    }
    var cursor = root
    if fileManager.fileExists(atPath: cursor.path),
      try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    {
      throw SecurePathContainmentError.symbolicLinkComponent(cursor.path)
    }
    let rootComponents = root.pathComponents
    let candidateComponents = candidate.pathComponents
    for component in candidateComponents.dropFirst(rootComponents.count) {
      cursor.appendPathComponent(component)
      if fileManager.fileExists(atPath: cursor.path) {
        let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
          throw SecurePathContainmentError.symbolicLinkComponent(cursor.path)
        }
      }
    }
  }
}
