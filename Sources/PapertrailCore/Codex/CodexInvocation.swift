import Foundation

public enum CodexInvocationError: Error, Equatable, CustomStringConvertible, LocalizedError {
  case executableMustBeAbsolute
  case executableNotRunnable
  case invalidThreadID
  case invalidModelIdentifier
  case invalidReasoningEffort
  case unapprovedArguments([String])

  public var description: String {
    switch self {
    case .executableMustBeAbsolute: "The Codex executable path must be absolute."
    case .executableNotRunnable: "The Codex executable is not runnable."
    case .invalidThreadID: "The resume thread ID is not a valid opaque identifier."
    case .invalidModelIdentifier: "The selected Codex model identifier is invalid."
    case .invalidReasoningEffort: "The selected Codex reasoning effort is invalid."
    case .unapprovedArguments(let arguments):
      "Unapproved Codex arguments: \(arguments.joined(separator: " "))"
    }
  }

  public var errorDescription: String? { description }
}

public enum CodexReasoningEffort: String, CaseIterable, Identifiable, Sendable {
  case low
  case medium
  case high
  case xhigh

  public var id: String { rawValue }

  fileprivate var configurationValue: String {
    #"model_reasoning_effort="\#(rawValue)""#
  }
}

public struct CodexInvocation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case new
    case resume(threadID: String)
  }

  public let executableURL: URL
  public let arguments: [String]
  public let standardInput: Data
  public let workingDirectory: URL

  public init(
    executableURL: URL,
    kind: Kind,
    prompt: String,
    workingDirectory: URL,
    model: String? = nil,
    reasoningEffort: CodexReasoningEffort? = nil,
    ignoreUserConfiguration: Bool = false,
    fileManager: FileManager = .default
  ) throws {
    guard executableURL.path.hasPrefix("/") else {
      throw CodexInvocationError.executableMustBeAbsolute
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      fileManager.isExecutableFile(atPath: executableURL.path)
    else {
      throw CodexInvocationError.executableNotRunnable
    }

    let modelArguments: [String]
    if let model {
      guard Self.isValidModelIdentifier(model) else {
        throw CodexInvocationError.invalidModelIdentifier
      }
      modelArguments = ["--model", model]
    } else {
      modelArguments = []
    }
    let effortArguments = reasoningEffort.map { ["--config", $0.configurationValue] } ?? []
    let isolationArguments = ignoreUserConfiguration ? ["--ignore-user-config"] : []
    let resumeWorkspaceArguments: [String]
    switch kind {
    case .new:
      resumeWorkspaceArguments = []
    case .resume:
      resumeWorkspaceArguments = [
        "--config", #"sandbox_mode="workspace-write""#,
        "--config", Self.workspaceWriteConfiguration(for: workingDirectory)
      ]
    }
    let fixedTail = ["--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "-"]
    switch kind {
    case .new:
      arguments = ["exec"] + modelArguments + effortArguments + isolationArguments + fixedTail
    case .resume(let threadID):
      guard Self.isValidOpaqueIdentifier(threadID) else {
        throw CodexInvocationError.invalidThreadID
      }
      // codex-cli 0.149.1 resume has its own option surface and rejects
      // `--sandbox`; the resumed session retains the original turn policy.
      arguments = ["exec", "resume"] + modelArguments + effortArguments + resumeWorkspaceArguments
        + isolationArguments
        + ["--json", "--skip-git-repo-check", threadID, "-"]
    }
    self.executableURL = executableURL.standardizedFileURL
    standardInput = Data(prompt.utf8)
    self.workingDirectory = workingDirectory.standardizedFileURL
    try Self.validate(arguments: arguments, workingDirectory: self.workingDirectory)
  }

  public static func validate(arguments: [String]) throws {
    try validate(arguments: arguments, workingDirectory: nil)
  }

  static func validate(arguments: [String], workingDirectory: URL?) throws {
    let forbidden = Set([
      "--dangerously-bypass-approvals-and-sandbox",
      "--dangerously-bypass-hook-trust",
      "--approve-for-me",
      "--add-dir",
      "--enable",
      "--disable",
      "app-server",
      "mcp-server",
      "remote-control",
    ])
    let forbiddenFound = arguments.filter { forbidden.contains($0) }
    guard forbiddenFound.isEmpty else {
      throw CodexInvocationError.unapprovedArguments(forbiddenFound)
    }

    var cursor = 0
    guard arguments.count >= 6, arguments[cursor] == "exec" else {
      throw CodexInvocationError.unapprovedArguments(arguments)
    }
    cursor += 1
    let isResume = cursor < arguments.count && arguments[cursor] == "resume"
    if isResume { cursor += 1 }
    if cursor + 1 < arguments.count && arguments[cursor] == "--model" {
      guard isValidModelIdentifier(arguments[cursor + 1]) else {
        throw CodexInvocationError.invalidModelIdentifier
      }
      cursor += 2
    }
    if cursor + 1 < arguments.count && arguments[cursor] == "--config" {
      if CodexReasoningEffort.allCases.contains(where: {
        $0.configurationValue == arguments[cursor + 1]
      }) {
        cursor += 2
      } else if arguments[cursor + 1].hasPrefix("model_reasoning_effort") {
        throw CodexInvocationError.invalidReasoningEffort
      }
    }
    if isResume, cursor + 1 < arguments.count, arguments[cursor] == "--config" {
      guard arguments[cursor + 1] == #"sandbox_mode="workspace-write""#
      else { throw CodexInvocationError.unapprovedArguments(arguments) }
      cursor += 2
    }
    if isResume, cursor + 1 < arguments.count, arguments[cursor] == "--config" {
      guard let workingDirectory,
        arguments[cursor + 1] == workspaceWriteConfiguration(for: workingDirectory)
      else { throw CodexInvocationError.unapprovedArguments(arguments) }
      cursor += 2
    }
    if cursor < arguments.count && arguments[cursor] == "--ignore-user-config" {
      cursor += 1
    }
    let expectedTail = isResume
      ? ["--json", "--skip-git-repo-check"]
      : ["--json", "--sandbox", "workspace-write", "--skip-git-repo-check"]
    guard arguments.dropFirst(cursor).starts(with: expectedTail) else {
      throw CodexInvocationError.unapprovedArguments(arguments)
    }
    cursor += expectedTail.count
    if isResume {
      guard cursor + 1 < arguments.count, isValidOpaqueIdentifier(arguments[cursor]),
        arguments[cursor + 1] == "-", cursor + 2 == arguments.count
      else { throw CodexInvocationError.unapprovedArguments(arguments) }
      return
    }
    guard cursor < arguments.count, arguments[cursor] == "-", cursor + 1 == arguments.count
    else { throw CodexInvocationError.unapprovedArguments(arguments) }
  }

  private static func isValidOpaqueIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
    }
  }

  public static func isValidModelIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
    }
  }

  private static func workspaceWriteConfiguration(for workingDirectory: URL) -> String {
    let path = workingDirectory.standardizedFileURL.path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return #"sandbox_workspace_write.writable_roots=["\#(path)"]"#
  }
}
