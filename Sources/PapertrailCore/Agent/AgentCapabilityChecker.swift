import Darwin
@preconcurrency import Foundation

public struct AgentCapabilityReport: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case usable, missing, incompatible, loggedOut, invocationFailed
  }
  public let status: Status
  public let executablePath: String
  public let versionOutput: String
  public let capabilityEvidence: [String]
  public let detail: String
}

public struct AgentCapabilityChecker: Sendable {
  public static let requiredVersion = (major: 2, minor: 1)
  /// Every option `AgentInvocation` emits must appear in `claude --help`.
  public static let requiredHelpTokens = [
    "--print", "--output-format", "stream-json", "--verbose", "--tools", "--strict-mcp-config",
    "--setting-sources", "--permission-mode", "dontAsk", "--system-prompt", "--model",
    "--effort", "--include-partial-messages", "--resume", "--no-session-persistence",
  ]

  public init() {}

  public func check(executableURL: URL) -> AgentCapabilityReport {
    guard executableURL.path.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      return .init(
        status: .missing, executablePath: executableURL.path, versionOutput: "",
        capabilityEvidence: [], detail: "Absolute executable is missing or not executable.")
    }
    do {
      let version = try run(executableURL, arguments: ["--version"])
      let versionText = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard version.status == 0, !version.timedOut else {
        return .init(
          status: .invocationFailed, executablePath: executableURL.path,
          versionOutput: versionText, capabilityEvidence: [],
          detail:
            "claude --version did not complete cleanly (exit=\(version.status), timedOut=\(version.timedOut), bytes=\(version.output.utf8.count))."
        )
      }
      let help = try runHelp(executableURL)
      let found = Self.requiredHelpTokens.filter { help.output.contains($0) }
      let missing = Self.requiredHelpTokens.filter { !help.output.contains($0) }
      if help.status != 0 || help.timedOut
        || (!missing.isEmpty && !Self.looksLikeCompleteHelp(help.output))
      {
        return .init(
          status: .invocationFailed, executablePath: executableURL.path,
          versionOutput: versionText, capabilityEvidence: found,
          detail:
            "Capability help probe did not return a complete result; this is an invocation failure, not proof of an incompatible CLI. \(Self.probeDetail("--help", help, missing: missing))."
        )
      }
      guard missing.isEmpty, Self.meetsVersionFloor(version.output),
        version.output.contains("Claude Code")
      else {
        return .init(
          status: .incompatible, executablePath: executableURL.path,
          versionOutput: versionText, capabilityEvidence: found,
          detail:
            "Installed CLI does not meet the Claude Code capability floor \(Self.requiredVersion.major).\(Self.requiredVersion.minor). \(Self.probeDetail("--help", help, missing: missing)); versionFloorMet=\(Self.meetsVersionFloor(version.output))."
        )
      }
      if try authenticationStatus(executableURL) == false {
        return .init(
          status: .loggedOut, executablePath: executableURL.path,
          versionOutput: versionText, capabilityEvidence: found,
          detail: "Claude Code is installed but not logged in. Run `claude auth login` in Terminal.")
      }
      return .init(
        status: .usable, executablePath: executableURL.path,
        versionOutput: versionText, capabilityEvidence: found,
        detail:
          "Capability surface is compatible. Papertrail runs headless turns with no tools, no MCP servers, and no user or project settings; inputs arrive on stdin and outputs are read from stream-json events."
      )
    } catch {
      return .init(
        status: .invocationFailed, executablePath: executableURL.path, versionOutput: "",
        capabilityEvidence: [], detail: String(describing: error))
    }
  }

  /// `claude auth status` prints JSON with a `loggedIn` flag. An unreadable answer returns nil so
  /// that the real operation, not the probe, decides authentication.
  private func authenticationStatus(_ executableURL: URL) throws -> Bool? {
    let result = try run(executableURL, arguments: ["auth", "status"])
    guard !result.timedOut, let start = result.output.firstIndex(of: "{"),
      let end = result.output.lastIndex(of: "}"),
      let object = try? JSONSerialization.jsonObject(
        with: Data(result.output[start...end].utf8)) as? [String: Any]
    else { return nil }
    return object["loggedIn"] as? Bool
  }

  public static func classifyOperationFailure(diagnostics: [String], stderr: String)
    -> AgentCapabilityReport.Status
  {
    let lower = (diagnostics + [stderr]).joined(separator: "\n").lowercased()
    if lower.contains("not logged in") || lower.contains("failed to authenticate")
      || lower.contains("oauth") || lower.contains("/login") || lower.contains("auth login")
      || lower.contains("invalid api key") || lower.contains("authentication")
    {
      return .loggedOut
    }
    return .invocationFailed
  }

  private static func meetsVersionFloor(_ output: String) -> Bool {
    let parts = output.split(whereSeparator: { !$0.isNumber && $0 != "." })
    guard let token = parts.first(where: { $0.contains(".") }) else { return false }
    let numbers = token.split(separator: ".").compactMap { Int($0) }
    guard numbers.count >= 2 else { return false }
    return numbers[0] > requiredVersion.major
      || (numbers[0] == requiredVersion.major && numbers[1] >= requiredVersion.minor)
  }

  private static func exposesOption(_ option: String, in help: String) -> Bool {
    help.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("-") else { return false }
      return trimmed.split(whereSeparator: \Character.isWhitespace).contains { token in
        token.trimmingCharacters(in: CharacterSet(charactersIn: ",")) == option
      }
    }
  }

  private static func looksLikeCompleteHelp(_ output: String) -> Bool {
    output.contains("Usage:") && output.contains("Options:")
      && exposesOption("--help", in: output)
  }

  private static func probeDetail(
    _ command: String, _ result: CommandResult, missing: [String]
  ) -> String {
    let missingDescription = missing.isEmpty ? "none" : missing.joined(separator: ",")
    return
      "\(command){exit=\(result.status),timedOut=\(result.timedOut),attempts=\(result.attempts),bytes=\(result.output.utf8.count),missing=\(missingDescription)}"
  }

  private func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    process.environment = Self.minimalEnvironment()
    try process.run()
    let output = CapabilityDataBox()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      var bounded = Data()
      while true {
        guard let chunk = try? pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty
        else { break }
        if bounded.count < 1_048_576 {
          bounded.append(chunk.prefix(1_048_576 - bounded.count))
        }
      }
      output.set(bounded)
      readers.leave()
    }

    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      let terminationDeadline = Date().addingTimeInterval(0.5)
      while process.isRunning, Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    readers.wait()
    return CommandResult(
      status: process.terminationStatus, output: String(decoding: output.get(), as: UTF8.self),
      timedOut: timedOut, attempts: 1)
  }

  private func runHelp(_ executableURL: URL) throws -> CommandResult {
    var best: CommandResult?
    for attempt in 1...3 {
      var result = try run(executableURL, arguments: ["--help"])
      result.attempts = attempt
      if result.status == 0, !result.timedOut,
        Self.requiredHelpTokens.allSatisfy({ result.output.contains($0) })
      {
        return result
      }
      if best == nil || Self.probeRank(result) > Self.probeRank(best!) {
        best = result
      }
      if attempt < 3 { Thread.sleep(forTimeInterval: TimeInterval(attempt) * 0.1) }
    }
    return best!
  }

  private static func probeRank(_ result: CommandResult) -> Int {
    let found = requiredHelpTokens.filter { result.output.contains($0) }.count
    return found * 10_000 + (looksLikeCompleteHelp(result.output) ? 1_000 : 0)
      + (result.status == 0 ? 100 : 0) + (result.timedOut ? 0 : 10)
      + min(result.output.utf8.count, 9)
  }

  /// Child processes never inherit the app environment: API keys, proxies, and `CLAUDE_*`
  /// overrides stay out, and Claude Code's updater and nonessential traffic are disabled.
  public static func minimalEnvironment(
    source: [String: String] = ProcessInfo.processInfo.environment
  )
    -> [String: String]
  {
    let allowed = [
      "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR",
      "TERM",
    ]
    var result = allowed.reduce(into: [String: String]()) { partial, key in
      partial[key] = source[key]
    }
    result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    result["NO_COLOR"] = "1"
    result["DISABLE_AUTOUPDATER"] = "1"
    result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    return result
  }
}

private struct CommandResult {
  let status: Int32
  let output: String
  let timedOut: Bool
  var attempts: Int
}

private final class CapabilityDataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func set(_ value: Data) { lock.withLock { data = value } }
  func get() -> Data { lock.withLock { data } }
}
