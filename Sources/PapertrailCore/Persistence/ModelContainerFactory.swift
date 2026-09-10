#if !PPR_PORTABLE_SCHEMA
  import Foundation
  import SwiftData

  public enum ModelContainerFactory {
    public static func make(at storeURL: URL) throws -> ModelContainer {
      let schema = Schema(versionedSchema: PersonalPaperReviewSchemaV1.self)
      let configuration = ModelConfiguration(schema: schema, url: storeURL)
      return try ModelContainer(
        for: schema,
        migrationPlan: PersonalPaperReviewMigrationPlan.self,
        configurations: [configuration])
    }

    public static func makeInMemory() throws -> ModelContainer {
      let schema = Schema(versionedSchema: PersonalPaperReviewSchemaV1.self)
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      return try ModelContainer(
        for: schema,
        migrationPlan: PersonalPaperReviewMigrationPlan.self,
        configurations: [configuration])
    }
  }
#else
  import Darwin
  import Foundation

  public struct DurableModelStore: Sendable {
    public let storeURL: URL
    public init(storeURL: URL) { self.storeURL = storeURL }

    public func load() throws -> DurableSnapshot {
      try read { $0 }
    }

    public func save(_ snapshot: DurableSnapshot) throws {
      try coordinated { try saveUnlocked(snapshot) }
    }

    /// Reads one coherent snapshot while excluding writers in this and other processes.
    public func read<T>(_ body: (DurableSnapshot) throws -> T) throws -> T {
      try coordinated { try body(loadUnlocked()) }
    }

    /// Serializes the complete load-mutate-save cycle for every adapter sharing this store URL.
    @discardableResult
    public func transaction<T>(_ body: (inout DurableSnapshot) throws -> T) throws -> T {
      try coordinated {
        var snapshot = try loadUnlocked()
        let result = try body(&snapshot)
        try saveUnlocked(snapshot)
        return result
      }
    }

    private func loadUnlocked() throws -> DurableSnapshot {
      guard FileManager.default.fileExists(atPath: storeURL.path) else { return DurableSnapshot() }
      return try JSONDecoder().decode(DurableSnapshot.self, from: Data(contentsOf: storeURL))
    }

    private func saveUnlocked(_ snapshot: DurableSnapshot) throws {
      guard snapshot.schemaVersion == PersonalPaperReviewSchemaV1.versionIdentifier else {
        throw CocoaError(.coderReadCorrupt)
      }
      let data = try JSONEncoder().encode(snapshot)
      let parent = storeURL.deletingLastPathComponent()
      let temporary =
        parent
        .appendingPathComponent(".partial-store-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: parent.path)
      defer { try? FileManager.default.removeItem(at: temporary) }
      try data.write(to: temporary, options: [.withoutOverwriting])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      if FileManager.default.fileExists(atPath: storeURL.path) {
        _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: storeURL)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    private func coordinated<T>(_ body: () throws -> T) throws -> T {
      let processLock = DurableStoreLockRegistry.shared.lock(for: storeURL)
      processLock.lock()
      defer { processLock.unlock() }

      let parent = storeURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: parent.path)
      let lockURL = parent.appendingPathComponent(".\(storeURL.lastPathComponent).lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      }
      guard descriptor >= 0 else { throw Self.posixError() }
      defer { _ = Darwin.close(descriptor) }
      guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw Self.posixError()
      }
      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        throw Self.posixError()
      }
      defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
      return try body()
    }

    private static func posixError() -> POSIXError {
      POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private final class DurableStoreLockRegistry: @unchecked Sendable {
    static let shared = DurableStoreLockRegistry()
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for storeURL: URL) -> NSLock {
      let key = storeURL.standardizedFileURL.path
      registryLock.lock()
      defer { registryLock.unlock() }
      if let existing = locks[key] { return existing }
      let created = NSLock()
      locks[key] = created
      return created
    }
  }

  public enum ModelContainerFactory {
    public static func make(at storeURL: URL) throws -> DurableModelStore {
      DurableModelStore(storeURL: storeURL)
    }
  }
#endif
