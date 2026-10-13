import Foundation

public enum AgentInvocationError: Error, Equatable, CustomStringConvertible, LocalizedError {
  case executableMustBeAbsolute
  case executableNotRunnable
  case invalidSessionID
  case invalidModelIdentifier
  case invalidReasoningEffort
  case invalidSystemPrompt
  case unapprovedArguments([String])

  public var description: String {
    switch self {
    case .executableMustBeAbsolute: "The Claude Code executable path must be absolute."
    case .executableNotRunnable: "The Claude Code executable is not runnable."
    case .invalidSessionID: "The resume session ID is not a valid opaque identifier."
    case .invalidModelIdentifier: "The selected Claude model identifier is invalid."
    case .invalidReasoningEffort: "The selected Claude effort level is invalid."
    case .invalidSystemPrompt: "The app-owned system prompt is empty, oversized, or malformed."
    case .unapprovedArguments(let arguments):
      "Unapproved Claude Code arguments: \(arguments.joined(separator: " "))"
    }
  }

  public var errorDescription: String? { description }
}

public struct AgentReasoningEffort: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 32,
      rawValue.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
      })
    else { return nil }
    self.rawValue = rawValue
  }

  public static let automatic = Self(rawValue: "automatic")!
  public static let low = Self(rawValue: "low")!
  public static let medium = Self(rawValue: "medium")!
  public static let high = Self(rawValue: "high")!
  public static let xhigh = Self(rawValue: "xhigh")!
  public static let max = Self(rawValue: "max")!

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let effort = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid reasoning effort.")
    }
    self = effort
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var id: String { rawValue }
}

/// One headless `claude -p` turn. Papertrail never gives the model tools: every input is
/// supplied on standard input and every output is read from the stream-json events, so the
/// process has no file, shell, network, or MCP capability to misuse on untrusted paper text.
public struct AgentInvocation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// One-shot turn whose transcript Claude Code does not persist (review generation).
    case ephemeral
    /// First turn of a persisted conversation; Claude Code assigns the session ID.
    case new
    /// Continues a persisted conversation from the same working directory.
    case resume(sessionID: String)
  }

  public static let maximumSystemPromptBytes = 65_536

  /// Fixed isolation prefix. `--tools ""` removes every built-in tool, `--setting-sources ""`
  /// ignores user/project settings (hooks, plugins, permissions), and `--strict-mcp-config`
  /// without `--mcp-config` starts no MCP server. `dontAsk` denies anything not pre-approved.
  static let isolationArguments = [
    "-p", "--output-format", "stream-json", "--verbose",
    "--tools", "", "--strict-mcp-config", "--setting-sources", "",
    "--permission-mode", "dontAsk",
  ]

  public let executableURL: URL
  public let arguments: [String]
  public let standardInput: Data
  public let workingDirectory: URL

  public init(
    executableURL: URL,
    kind: Kind,
    systemPrompt: String,
    prompt: String,
    workingDirectory: URL,
    model: String? = nil,
    reasoningEffort: AgentReasoningEffort? = nil,
    fileManager: FileManager = .default
  ) throws {
    guard executableURL.path.hasPrefix("/") else {
      throw AgentInvocationError.executableMustBeAbsolute
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      fileManager.isExecutableFile(atPath: executableURL.path)
    else {
      throw AgentInvocationError.executableNotRunnable
    }
    guard Self.isValidSystemPrompt(systemPrompt) else {
      throw AgentInvocationError.invalidSystemPrompt
    }

    var arguments = Self.isolationArguments + ["--system-prompt", systemPrompt]
    if let model {
      guard Self.isValidModelIdentifier(model) else {
        throw AgentInvocationError.invalidModelIdentifier
      }
      arguments += ["--model", model]
    }
    if let reasoningEffort, reasoningEffort != .automatic {
      arguments += ["--effort", reasoningEffort.rawValue]
    }
    switch kind {
    case .ephemeral:
      arguments += ["--no-session-persistence"]
    case .new:
      break
    case .resume(let sessionID):
      guard Self.isValidOpaqueIdentifier(sessionID) else {
        throw AgentInvocationError.invalidSessionID
      }
      arguments += ["--resume", sessionID]
    }
    self.executableURL = executableURL.standardizedFileURL
    self.arguments = arguments
    standardInput = Data(prompt.utf8)
    self.workingDirectory = workingDirectory.standardizedFileURL
    try Self.validate(arguments: arguments)
  }

  public static func validate(arguments: [String]) throws {
    let forbidden = Set([
      "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
      "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
      "--add-dir", "--mcp-config", "--settings", "--plugin-dir", "--agents", "--agent",
      "--continue", "-c", "--fork-session", "--session-id", "--ide", "--chrome",
      "bypassPermissions", "acceptEdits", "auto",
    ])
    let forbiddenFound = arguments.filter { forbidden.contains($0) }
    guard forbiddenFound.isEmpty else {
      throw AgentInvocationError.unapprovedArguments(forbiddenFound)
    }
    guard arguments.starts(with: isolationArguments) else {
      throw AgentInvocationError.unapprovedArguments(arguments)
    }
    var cursor = isolationArguments.count
    guard cursor + 1 < arguments.count, arguments[cursor] == "--system-prompt",
      isValidSystemPrompt(arguments[cursor + 1])
    else { throw AgentInvocationError.invalidSystemPrompt }
    cursor += 2
    if cursor + 1 < arguments.count, arguments[cursor] == "--model" {
      guard isValidModelIdentifier(arguments[cursor + 1]) else {
        throw AgentInvocationError.invalidModelIdentifier
      }
      cursor += 2
    }
    if cursor + 1 < arguments.count, arguments[cursor] == "--effort" {
      guard let effort = AgentReasoningEffort(rawValue: arguments[cursor + 1]),
        effort != .automatic
      else { throw AgentInvocationError.invalidReasoningEffort }
      cursor += 2
    }
    let tail = Array(arguments.dropFirst(cursor))
    switch tail.count {
    case 0:
      return
    case 1 where tail[0] == "--no-session-persistence":
      return
    case 2 where tail[0] == "--resume" && isValidOpaqueIdentifier(tail[1]):
      return
    default:
      throw AgentInvocationError.unapprovedArguments(tail)
    }
  }

  static func isValidOpaqueIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("-") else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
    }
  }

  public static func isValidModelIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128, !value.hasPrefix("-") else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
    }
  }

  /// A leading `-` could be parsed as another option, so app-owned prompts must start with text.
  static func isValidSystemPrompt(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, first != "-",
      !CharacterSet.whitespacesAndNewlines.contains(first),
      value.utf8.count <= maximumSystemPromptBytes
    else { return false }
    return !value.unicodeScalars.contains { $0.value == 0 }
  }
}
