import Foundation

public enum AutomaticReviewRequestState: String, Codable, Sendable { case pending, claimed }

public struct AutomaticReviewRequestRecord: Codable, Equatable, Sendable {
  public let id: UUID
  public let paperID: UUID
  public var state: AutomaticReviewRequestState
  public var generationID: UUID?
  public var sessionID: UUID?
  public var operationID: UUID?
  public var versionID: UUID?
  public var attempts: Int
  public let createdAt: Date

  public init(id: UUID = UUID(), paperID: UUID, createdAt: Date = Date()) {
    self.id = id; self.paperID = paperID; self.state = .pending
    self.attempts = 0; self.createdAt = createdAt
  }

  public var identity: ReviewGenerationIdentity? {
    guard let generationID, let sessionID, let operationID, let versionID else { return nil }
    return ReviewGenerationIdentity(
      generationID: generationID, sessionID: sessionID,
      operationID: operationID, versionID: versionID)
  }
}

public enum AutomaticReviewRequestStoreError: Error, Equatable {
  case requestNotClaimed
  case claimMismatch
}

public final class DurableAutomaticReviewRequestStore: @unchecked Sendable {
  private struct State: Codable { var requests: [AutomaticReviewRequestRecord] = [] }
  private let url: URL
  private static let transactionLock = NSLock()

  public init(url: URL) { self.url = url }

  @discardableResult
  public func enqueue(paperID: UUID) throws -> AutomaticReviewRequestRecord {
    try transaction { state in
      if let existing = state.requests.first(where: { $0.paperID == paperID }) { return existing }
      let request = AutomaticReviewRequestRecord(paperID: paperID)
      state.requests.append(request)
      return request
    }
  }

  public func request(paperID: UUID) throws -> AutomaticReviewRequestRecord? {
    try transaction(write: false) { $0.requests.first(where: { $0.paperID == paperID }) }
  }

  @discardableResult
  public func reconcile(
    paperID: UUID, automaticReviewRequired: Bool
  ) throws -> AutomaticReviewRequestRecord? {
    try transaction { state in
      if automaticReviewRequired {
        if let existing = state.requests.first(where: { $0.paperID == paperID }) {
          return existing
        }
        let request = AutomaticReviewRequestRecord(paperID: paperID)
        state.requests.append(request)
        return request
      }
      state.requests.removeAll { $0.paperID == paperID }
      return nil
    }
  }

  public func claim(
    paperID: UUID, identity: ReviewGenerationIdentity = .init()
  ) throws -> AutomaticReviewRequestRecord? {
    try transaction { state in
      guard let index = state.requests.firstIndex(where: {
        $0.paperID == paperID && $0.state == .pending
      }) else { return nil }
      state.requests[index].state = .claimed
      state.requests[index].generationID = identity.generationID
      state.requests[index].sessionID = identity.sessionID
      state.requests[index].operationID = identity.operationID
      state.requests[index].versionID = identity.versionID
      state.requests[index].attempts += 1
      return state.requests[index]
    }
  }

  public func release(requestID: UUID, generationID: UUID) throws {
    try transaction { state in
      guard let index = state.requests.firstIndex(where: { $0.id == requestID }) else { return }
      guard state.requests[index].state == .claimed,
        state.requests[index].generationID == generationID
      else { throw AutomaticReviewRequestStoreError.claimMismatch }
      state.requests[index].state = .pending
      state.requests[index].generationID = nil; state.requests[index].sessionID = nil
      state.requests[index].operationID = nil; state.requests[index].versionID = nil
    }
  }

  public func complete(requestID: UUID, generationID: UUID) throws {
    try transaction { state in
      guard let index = state.requests.firstIndex(where: { $0.id == requestID }) else { return }
      guard state.requests[index].state == .claimed,
        state.requests[index].generationID == generationID
      else { throw AutomaticReviewRequestStoreError.claimMismatch }
      state.requests.remove(at: index)
    }
  }

  private func transaction<T>(
    write: Bool = true, _ body: (inout State) throws -> T
  ) throws -> T {
    try Self.transactionLock.withLock {
      var state: State
      if FileManager.default.fileExists(atPath: url.path) {
        state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
      } else { state = State() }
      let result = try body(&state)
      if write { try save(state) }
      return result
    }
  }

  private func save(_ state: State) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".partial-auto-review-\(UUID().uuidString.lowercased())")
    defer { try? fm.removeItem(at: temporary) }
    try JSONEncoder().encode(state).write(to: temporary, options: .withoutOverwriting)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: temporary)
    } else { try fm.moveItem(at: temporary, to: url) }
  }
}
