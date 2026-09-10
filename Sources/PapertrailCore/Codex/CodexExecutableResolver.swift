import Foundation

public struct CodexExecutableResolutionError: Error, LocalizedError, Sendable {
  public let inspectedCandidates: [CodexCapabilityReport]

  public init(inspectedCandidates: [CodexCapabilityReport]) {
    self.inspectedCandidates = inspectedCandidates
  }

  public var errorDescription: String? {
    let failures = inspectedCandidates.map {
      "\($0.executablePath) [\($0.status.rawValue)]: \($0.detail)"
    }.joined(separator: "; ")
    return "No installed Codex CLI passed the required capability check. \(failures)"
  }
}

public struct CodexExecutableResolver: Sendable {
  public init() {}

  public func resolve(
    preferredPath: String?, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    var candidates: [String] = []
    if let preferredPath, !preferredPath.isEmpty { candidates.append(preferredPath) }
    // Prefer the independently updated package-manager CLI. Finder-launched apps still fall
    // back to the bundled ChatGPT runtime when no compatible package-manager CLI is present.
    candidates.append("/opt/homebrew/bin/codex")
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
    }
    candidates.append(contentsOf: [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/usr/local/bin/codex",
    ])

    var inspected = Set<URL>()
    var reports: [CodexCapabilityReport] = []
    let capabilityChecker = CodexCapabilityChecker()
    for candidate in candidates {
      let url = URL(fileURLWithPath: candidate).standardizedFileURL
      guard inspected.insert(url).inserted, url.path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: url.path)
      else {
        continue
      }
      let report = capabilityChecker.check(executableURL: url)
      guard report.status == .usable else {
        reports.append(report)
        continue
      }
      return url
    }
    if !reports.isEmpty {
      throw CodexExecutableResolutionError(inspectedCandidates: reports)
    }
    throw CodexInvocationError.executableNotRunnable
  }
}

/// Shares one capability probe across app features and keeps the blocking CLI checks away from
/// the main actor. Failed probes are not cached so a repaired or newly installed CLI can be used
/// by the next operation without relaunching Papertrail.
public actor CodexExecutableProvider {
  private let preferredPath: String?
  private let environment: [String: String]
  private var resolutionTask: Task<URL, Error>?

  public init(
    preferredPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.preferredPath = preferredPath
    self.environment = environment
  }

  public func executableURL() async throws -> URL {
    if let resolutionTask { return try await resolutionTask.value }
    let preferredPath = preferredPath
    let environment = environment
    let task = Task.detached(priority: .userInitiated) {
      try CodexExecutableResolver().resolve(
        preferredPath: preferredPath, environment: environment)
    }
    resolutionTask = task
    do {
      return try await task.value
    } catch {
      resolutionTask = nil
      throw error
    }
  }

  public func invalidate() {
    resolutionTask?.cancel()
    resolutionTask = nil
  }
}
