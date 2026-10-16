import CryptoKit
import Foundation

public enum AgentInputError: Error, Equatable, LocalizedError {
  case inlineInputTooLarge(bytes: Int, limit: Int)

  public var errorDescription: String? {
    switch self {
    case .inlineInputTooLarge(let bytes, let limit):
      "The paper text and context (\(bytes) bytes) exceed the \(limit)-byte limit that fits in one Claude conversation."
    }
  }
}

/// Builds the stdin payload for tool-less turns. Untrusted data is fenced by markers that embed
/// the SHA-256 of the fenced content: text cannot contain its own digest, so a paper or chat
/// message can never forge the closing marker and continue as app-authored instructions.
public enum AgentPromptEnvelope {
  /// Current models accept 1M tokens; 3 MiB of UTF-8 leaves room for the system prompt,
  /// conversation history, and the response.
  public static let maximumInlineInputBytes = 3 * 1_024 * 1_024

  public static func block(_ label: String, content: String) -> String {
    let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    return "<<\(label)_BEGIN \(digest)>>\n\(content)\n<<\(label)_END \(digest)>>"
  }

  public static func requireWithinLimit(_ parts: [String]) throws {
    let bytes = parts.reduce(0) { $0 + $1.utf8.count }
    guard bytes <= maximumInlineInputBytes else {
      throw AgentInputError.inlineInputTooLarge(bytes: bytes, limit: maximumInlineInputBytes)
    }
  }
}
