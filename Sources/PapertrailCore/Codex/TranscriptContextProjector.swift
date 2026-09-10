import CryptoKit
import Foundation

public struct TranscriptMessage: Equatable, Sendable {
  public enum Role: String, Sendable { case user, assistant, system, tool, error }
  public let id: String
  public let role: Role
  public let content: String
  public let createdAt: Date
  public let committed: Bool
  public let deleted: Bool

  public init(
    id: String, role: Role, content: String, createdAt: Date, committed: Bool = true,
    deleted: Bool = false
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
    self.committed = committed
    self.deleted = deleted
  }
}

public struct TranscriptContextProjector: Sendable {
  public static let defaultBudget = 32_768

  public init() {}

  public func project(
    predecessorSessionID: String, messages: [TranscriptMessage], budgetBytes: Int = defaultBudget
  ) -> Data {
    let eligible =
      messages
      .filter { $0.committed && !$0.deleted && ($0.role == .user || $0.role == .assistant) }
      .sorted { lhs, rhs in
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
      }
    let serialized = eligible.map { messageLine($0) }
    let header = "TRANSCRIPT_CONTEXT_V1\n"
    let metadata =
      "{\"predecessor_session_id\":\"\(escape(predecessorSessionID))\",\"budget_bytes\":\(budgetBytes),\"normalization\":\"NFC_LF\",\"selection\":\"newest_whole_message_suffix\"}\n"

    if let newest = eligible.last, let newestLine = serialized.last {
      let normalized = normalize(newest.content)
      let contentBytes = normalized.utf8.count
      let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let fittingOmission =
        "{\"type\":\"omission\",\"count\":\(eligible.count - 1),\"newest_omitted\":false}\n"
      let omission =
        "{\"type\":\"omission\",\"count\":\(eligible.count),\"newest_omitted\":true,\"newest_id\":\"\(escape(newest.id))\",\"newest_utf8_bytes\":\(contentBytes),\"newest_sha256\":\"\(hash)\"}\n"
      if Data((header + metadata + fittingOmission + newestLine + "\n").utf8).count
        > budgetBytes
      {
        return Data((header + metadata + omission).utf8)
      }
    }

    var selected: [String] = []
    for line in serialized.reversed() {
      let proposedCount = selected.count + 1
      let omitted = eligible.count - proposedCount
      let omission = "{\"type\":\"omission\",\"count\":\(omitted),\"newest_omitted\":false}\n"
      let body = ([line] + selected).joined(separator: "\n")
      if Data((header + metadata + omission + body + "\n").utf8).count <= budgetBytes {
        selected.insert(line, at: 0)
      } else {
        break
      }
    }
    let omission =
      "{\"type\":\"omission\",\"count\":\(eligible.count - selected.count),\"newest_omitted\":false}\n"
    return Data(
      (header + metadata + omission
        + (selected.isEmpty ? "" : selected.joined(separator: "\n") + "\n")).utf8)
  }

  private func messageLine(_ message: TranscriptMessage) -> String {
    "{\"id\":\"\(escape(message.id))\",\"role\":\"\(message.role.rawValue)\",\"content\":\"\(escape(normalize(message.content)))\"}"
  }

  private func normalize(_ value: String) -> String {
    let lf = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    let scalars = lf.unicodeScalars.filter { scalar in
      scalar.value == 0x09 || scalar.value == 0x0A || scalar.value >= 0x20
    }
    return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
  }

  private func escape(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0A: result += "\\n"
      case 0x0C: result += "\\f"
      case 0x0D: result += "\\r"
      case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
