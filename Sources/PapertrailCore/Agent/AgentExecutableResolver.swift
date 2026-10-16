import Foundation

public struct AgentExecutableResolutionError: Error, LocalizedError, Sendable {
  public let inspectedCandidates: [AgentCapabilityReport]

  public init(inspectedCandidates: [AgentCapabilityReport]) {
    self.inspectedCandidates = inspectedCandidates
  }

  public var errorDescription: String? {
    if inspectedCandidates.contains(where: { $0.status == .loggedOut }) {
      return
        "Claude Code is installed but not logged in. Run `claude auth login` in Terminal, then try again."
    }
    let failures = inspectedCandidates.map {
      "\($0.executablePath) [\($0.status.rawValue)]: \($0.detail)"
    }.joined(separator: "; ")
    return "No installed Claude Code CLI passed the required capability check. \(failures)"
  }
}

public struct AgentExecutableResolver: Sendable {
  public init() {}

  public func resolve(
    preferredPath: String?, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    var candidates: [String] = []
    if let preferredPath, !preferredPath.isEmpty { candidates.append(preferredPath) }
    // Finder-launched apps get a minimal PATH, so the package-manager and native-installer
    // locations are probed explicitly before the inherited PATH entries.
    candidates.append("/opt/homebrew/bin/claude")
    if let home = environment["HOME"], home.hasPrefix("/") {
      candidates.append("\(home)/.local/bin/claude")
      candidates.append("\(home)/.claude/local/claude")
    }
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
    }
    candidates.append("/usr/local/bin/claude")

    var inspected = Set<URL>()
    var reports: [AgentCapabilityReport] = []
    let capabilityChecker = AgentCapabilityChecker()
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
      throw AgentExecutableResolutionError(inspectedCandidates: reports)
    }
    throw AgentInvocationError.executableNotRunnable
  }
}

/// Shares one capability probe across app features and keeps the blocking CLI checks away from
/// the main actor. Failed probes are not cached so a repaired, newly installed, or newly logged-in
/// CLI can be used by the next operation without relaunching Papertrail.
public actor AgentExecutableProvider {
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
      try AgentExecutableResolver().resolve(
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
