import Darwin
@preconcurrency import Foundation

public struct CodexCapabilityReport: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case usable, missing, incompatible, loggedOut, invocationFailed
  }
  public let status: Status
  public let executablePath: String
  public let versionOutput: String
  public let capabilityEvidence: [String]
  public let detail: String
}

public struct CodexCapabilityChecker: Sendable {
  public static let requiredVersion = (major: 0, minor: 149)

  public init() {}

  public func check(executableURL: URL) -> CodexCapabilityReport {
    guard executableURL.path.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      return .init(
        status: .missing, executablePath: executableURL.path, versionOutput: "",
        capabilityEvidence: [], detail: "Absolute executable is missing or not executable.")
    }
    do {
      let version = try run(executableURL, arguments: ["--version"])
      guard version.status == 0, !version.timedOut else {
        return .init(
          status: .invocationFailed, executablePath: executableURL.path,
          versionOutput: version.output, capabilityEvidence: [],
          detail:
            "codex --version did not complete cleanly (exit=\(version.status), timedOut=\(version.timedOut), bytes=\(version.output.utf8.count))."
        )
      }
      let required = [
        "--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "resume",
        "instructions are read from stdin",
      ]
      let resumeRequired = ["--json", "--skip-git-repo-check", "If `-` is used, read from stdin"]
      let help = try runHelp(
        executableURL, arguments: ["exec", "--help"], required: required)
      let resumeHelp = try runHelp(
        executableURL, arguments: ["exec", "resume", "--help"], required: resumeRequired)
      let found = required.filter { help.output.contains($0) }
      let resumeFound = resumeRequired.filter { resumeHelp.output.contains($0) }
      let evidence = found + resumeFound
      let helpMissing = required.filter { !help.output.contains($0) }
      let resumeMissing = resumeRequired.filter { !resumeHelp.output.contains($0) }
      let helpInvocationFailed =
        help.status != 0 || help.timedOut
        || (!helpMissing.isEmpty && !Self.looksLikeCompleteHelp(help.output))
      let resumeInvocationFailed =
        resumeHelp.status != 0 || resumeHelp.timedOut
        || (!resumeMissing.isEmpty && !Self.looksLikeCompleteHelp(resumeHelp.output))
      if helpInvocationFailed || resumeInvocationFailed {
        return .init(
          status: .invocationFailed, executablePath: executableURL.path,
          versionOutput: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
          capabilityEvidence: evidence,
          detail:
            "Capability help probe did not return a complete result; this is an invocation failure, not proof of an incompatible CLI. \(Self.probeDetail("exec --help", help, missing: helpMissing)); \(Self.probeDetail("exec resume --help", resumeHelp, missing: resumeMissing))."
        )
      }
      guard helpMissing.isEmpty, resumeMissing.isEmpty,
        !Self.exposesOption("--sandbox", in: resumeHelp.output),
        Self.meetsVersionFloor(version.output)
      else {
        return .init(
          status: .incompatible, executablePath: executableURL.path,
          versionOutput: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
          capabilityEvidence: evidence,
          detail:
            "Installed CLI does not meet the frozen Gate 0A capability floor. \(Self.probeDetail("exec --help", help, missing: helpMissing)); \(Self.probeDetail("exec resume --help", resumeHelp, missing: resumeMissing)); resumeExposesSandbox=\(Self.exposesOption("--sandbox", in: resumeHelp.output)); versionFloorMet=\(Self.meetsVersionFloor(version.output))."
        )
      }
      return .init(
        status: .usable, executablePath: executableURL.path,
        versionOutput: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
        capabilityEvidence: evidence,
        detail:
          "Capability surface is compatible. Resume does not expose --sandbox, so Papertrail supplies only the fixed workspace-write mode and the exact current workspace through validated config overrides. Authentication is determined only by a real CLI operation; no auth file is read by the app."
      )
    } catch {
      return .init(
        status: .invocationFailed, executablePath: executableURL.path, versionOutput: "",
        capabilityEvidence: [], detail: String(describing: error))
    }
  }

  public static func classifyOperationFailure(stderr: String) -> CodexCapabilityReport.Status {
    let lower = stderr.lowercased()
    if lower.contains("not logged in") || lower.contains("login required")
      || lower.contains("authentication required") || lower.contains("unauthorized")
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

  private func runHelp(
    _ executableURL: URL, arguments: [String], required: [String]
  ) throws -> CommandResult {
    var best: CommandResult?
    for attempt in 1...3 {
      var result = try run(executableURL, arguments: arguments)
      result.attempts = attempt
      if result.status == 0, !result.timedOut,
        required.allSatisfy({ result.output.contains($0) })
      {
        return result
      }
      if best == nil
        || Self.probeRank(result, required: required) > Self.probeRank(best!, required: required)
      {
        best = result
      }
      if attempt < 3 { Thread.sleep(forTimeInterval: TimeInterval(attempt) * 0.1) }
    }
    return best!
  }

  private static func probeRank(_ result: CommandResult, required: [String]) -> Int {
    let found = required.filter { result.output.contains($0) }.count
    return found * 10_000 + (looksLikeCompleteHelp(result.output) ? 1_000 : 0)
      + (result.status == 0 ? 100 : 0) + (result.timedOut ? 0 : 10)
      + min(result.output.utf8.count, 9)
  }

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
