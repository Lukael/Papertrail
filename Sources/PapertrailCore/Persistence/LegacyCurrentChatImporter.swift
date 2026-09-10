import Foundation

public struct LegacyCurrentChatRecordV0: Codable, Equatable, Sendable {
  public let paperID: UUID
  public let sessionID: UUID
  public let isCurrentChat: Bool

  public init(paperID: UUID, sessionID: UUID, isCurrentChat: Bool) {
    self.paperID = paperID
    self.sessionID = sessionID
    self.isCurrentChat = isCurrentChat
  }
}

public struct LegacyCurrentChatDocumentV0: Codable, Equatable, Sendable {
  public let format: String
  public let records: [LegacyCurrentChatRecordV0]

  public init(records: [LegacyCurrentChatRecordV0]) {
    self.format = "LEGACY_CURRENT_CHAT_V0"
    self.records = records
  }

  public func flaggedSessionIDs(for paperID: UUID) -> Set<UUID> {
    Set(records.lazy.filter { $0.paperID == paperID && $0.isCurrentChat }.map(\.sessionID))
  }
}

public enum LegacyCurrentChatLoad: Equatable, Sendable {
  case absent
  case loaded(LegacyCurrentChatDocumentV0)
  case invalid(relativePath: String, reason: String)
}

public struct LegacyCurrentChatImporter: Sendable {
  public let maximumBytes: Int

  public init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }

  public func load(paths: LibraryPaths, fileManager: FileManager = .default)
    -> LegacyCurrentChatLoad
  {
    let url = paths.legacyCurrentChatV0URL
    guard fileManager.fileExists(atPath: url.path) else { return .absent }
    do {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        return .invalid(
          relativePath: "Store/legacy-current-chat-v0.json",
          reason: "legacy import must be a regular non-symbolic-link file")
      }
      guard let size = values.fileSize, size <= maximumBytes else {
        return .invalid(
          relativePath: "Store/legacy-current-chat-v0.json",
          reason: "legacy import exceeds the bounded size")
      }
      let document = try JSONDecoder().decode(
        LegacyCurrentChatDocumentV0.self, from: Data(contentsOf: url))
      guard document.format == "LEGACY_CURRENT_CHAT_V0" else {
        return .invalid(
          relativePath: "Store/legacy-current-chat-v0.json", reason: "unknown legacy format")
      }
      return .loaded(document)
    } catch {
      return .invalid(
        relativePath: "Store/legacy-current-chat-v0.json",
        reason: "legacy import is not valid V0 JSON: \(error.localizedDescription)")
    }
  }
}
