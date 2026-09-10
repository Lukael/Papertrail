import Foundation

public struct FileFingerprint: Equatable, Sendable {
  public let sha256: String
  public let byteCount: Int

  public static func read(_ url: URL, maximumByteCount: Int64 = .max) throws -> FileFingerprint {
    let result = try ImmutableFileStore.sha256(fileAt: url, maximumByteCount: maximumByteCount)
    return FileFingerprint(sha256: result.sha256, byteCount: result.byteCount)
  }
}
