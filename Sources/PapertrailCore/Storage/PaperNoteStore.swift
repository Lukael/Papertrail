import CoreGraphics
import Darwin
import Foundation

/// A highlight in the PDF, optionally with a comment, or a chat answer kept as a note.
public struct PaperNote: Codable, Equatable, Identifiable, Sendable {
  public enum Source: String, Codable, Sendable { case pdf, chat }

  public let id: UUID
  public let source: Source
  /// 1-based PDF page of a highlight; nil for chat notes.
  public let pageNumber: Int?
  /// Highlighted line rectangles in PDF page space.
  public let rects: [CGRect]
  /// The highlighted passage, or the saved chat answer.
  public let text: String
  public var comment: String
  public let messageID: UUID?
  public let createdAt: Date

  public init(
    id: UUID = UUID(), source: Source, pageNumber: Int? = nil, rects: [CGRect] = [],
    text: String, comment: String = "", messageID: UUID? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.pageNumber = pageNumber
    self.rects = rects
    self.text = text
    self.comment = comment
    self.messageID = messageID
    self.createdAt = createdAt
  }
}

public enum PaperNoteStoreError: Error, Equatable, LocalizedError, Sendable {
  case unsafeNoteFile(UUID)
  case invalidSchemaVersion(Int)
  case tooManyNotes(maximum: Int)
  case noteTooLarge(maximumBytes: Int)

  public var errorDescription: String? {
    switch self {
    case .unsafeNoteFile: "The paper note file is not a regular file."
    case .invalidSchemaVersion(let version):
      "The paper note file uses unsupported schema version \(version)."
    case .tooManyNotes(let maximum): "A paper can have at most \(maximum) notes."
    case .noteTooLarge(let maximumBytes):
      "A note can hold at most \(maximumBytes / 1024) KB of text."
    }
  }
}

/// Stores highlights and notes beside each paper, like `PaperTagStore`, so they are deleted
/// with the paper and never touch the model schema.
public struct PaperNoteStore: Sendable {
  public static let maximumNoteCount = 5_000
  public static let maximumNoteBytes = 256 * 1024

  public let paths: LibraryPaths

  public init(paths: LibraryPaths) {
    self.paths = paths
  }

  /// Returns an empty list when the paper has no notes yet.
  public func load(paperID: UUID) throws -> [PaperNote] {
    let fileURL = try noteFileURL(paperID: paperID)
    var status = stat()
    guard lstat(fileURL.path, &status) == 0 else {
      if errno == ENOENT { return [] }
      throw CocoaError(.fileReadUnknown)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw PaperNoteStoreError.unsafeNoteFile(paperID)
    }
    let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
    guard payload.schemaVersion == 1 else {
      throw PaperNoteStoreError.invalidSchemaVersion(payload.schemaVersion)
    }
    return payload.notes
  }

  /// Validates before replacing the file; the atomic write replaces a planted symlink rather
  /// than following it.
  public func save(_ notes: [PaperNote], paperID: UUID) throws {
    // A file that cannot be read was never loaded, so replacing it would drop its notes.
    _ = try load(paperID: paperID)
    guard notes.count <= Self.maximumNoteCount else {
      throw PaperNoteStoreError.tooManyNotes(maximum: Self.maximumNoteCount)
    }
    for note in notes where note.text.utf8.count + note.comment.utf8.count > Self.maximumNoteBytes {
      throw PaperNoteStoreError.noteTooLarge(maximumBytes: Self.maximumNoteBytes)
    }
    let fileURL = try noteFileURL(paperID: paperID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(Payload(schemaVersion: 1, notes: notes)).write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private struct Payload: Codable {
    let schemaVersion: Int
    let notes: [PaperNote]
  }

  private func noteFileURL(paperID: UUID) throws -> URL {
    try paths.url(forRelativePath: "Papers/\(paperID.uuidString.lowercased())/notes.json")
  }
}
