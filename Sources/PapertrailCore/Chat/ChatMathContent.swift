import Foundation

/// Splits chat Markdown into plain-text and LaTeX spans without changing the source text.
public enum ChatMathContent {
  private static let maximumMathSpanByteCount = 65_536

  public enum Segment: Equatable, Sendable {
    case text(String)
    case math(source: String, display: Bool)
  }

  public static func segments(in content: String) -> [Segment] {
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty else { return [] }

    var escaped = [Bool](repeating: false, count: bytes.count)
    var precedingSlashCount = 0
    for position in bytes.indices {
      escaped[position] = precedingSlashCount % 2 == 1
      if bytes[position] == 0x5C {
        precedingSlashCount += 1
      } else {
        precedingSlashCount = 0
      }
    }

    var result: [Segment] = []
    var textStart = 0
    var index = 0

    func string(_ range: Range<Int>) -> String {
      String(decoding: bytes[range], as: UTF8.self)
    }

    func appendText(_ range: Range<Int>) {
      guard !range.isEmpty else { return }
      let value = string(range)
      if case .text(let existing)? = result.last {
        result[result.count - 1] = .text(existing + value)
      } else {
        result.append(.text(value))
      }
    }

    func backtickRun(at position: Int) -> Int {
      var end = position
      while end < bytes.count, bytes[end] == 0x60 { end += 1 }
      return end - position
    }

    func endOfCodeSpan(start: Int, runLength: Int, searchEnd: Int) -> Int? {
      var cursor = start + runLength
      while cursor < searchEnd {
        if bytes[cursor] == 0x60, !escaped[cursor] {
          let candidateLength = backtickRun(at: cursor)
          if candidateLength == runLength { return cursor + runLength }
          cursor += candidateLength
        } else {
          cursor += 1
        }
      }
      return nil
    }

    func validDollarOpening(at position: Int, length: Int) -> Bool {
      let contentStart = position + length
      guard contentStart < bytes.count else { return false }
      if length == 1, bytes[contentStart].isASCIISpace { return false }
      return true
    }

    func dollarClose(start: Int, delimiterLength: Int) -> Int? {
      var cursor = start + delimiterLength
      let searchEnd = min(bytes.count, start + Self.maximumMathSpanByteCount)
      while cursor + delimiterLength <= searchEnd {
        if bytes[cursor] == 0x0A || bytes[cursor] == 0x0D, delimiterLength == 1 { return nil }
        if bytes[cursor] == 0x60, !escaped[cursor] { return nil }
        guard bytes[cursor] == 0x24 else {
          cursor += 1
          continue
        }
        let runLength = bytes[cursor...].prefix(while: { $0 == 0x24 }).count
        guard runLength == delimiterLength, !escaped[cursor] else {
          cursor += max(runLength, 1)
          continue
        }
        if delimiterLength == 1 {
          guard cursor > start + 1, !bytes[cursor - 1].isASCIISpace else { return nil }
          if cursor + 1 < bytes.count, bytes[cursor + 1].isASCIIDigit { return nil }
        }
        return cursor
      }
      return nil
    }

    func slashClose(start: Int, closingByte: UInt8) -> Int? {
      var cursor = start + 2
      let searchEnd = min(bytes.count, start + Self.maximumMathSpanByteCount)
      while cursor + 1 < searchEnd {
        if bytes[cursor] == 0x60, !escaped[cursor] { return nil }
        if bytes[cursor] == 0x5C, bytes[cursor + 1] == closingByte, !escaped[cursor] {
          return cursor
        }
        cursor += 1
      }
      return nil
    }

    while index < bytes.count {
      if bytes[index] == 0x60, !escaped[index] {
        let runLength = backtickRun(at: index)
        guard let codeEnd = endOfCodeSpan(start: index, runLength: runLength, searchEnd: bytes.count) else {
          index = bytes.count
          break
        }
        index = codeEnd
        continue
      }

      if bytes[index] == 0x24, !escaped[index] {
        let delimiterLength = index + 1 < bytes.count && bytes[index + 1] == 0x24 ? 2 : 1
        if validDollarOpening(at: index, length: delimiterLength),
           let close = dollarClose(start: index, delimiterLength: delimiterLength)
        {
          appendText(textStart..<index)
          let sourceStart = index + delimiterLength
          result.append(.math(source: string(sourceStart..<close), display: delimiterLength == 2))
          index = close + delimiterLength
          textStart = index
          continue
        }
        index += delimiterLength
        continue
      }

      if bytes[index] == 0x5C, !escaped[index], index + 1 < bytes.count {
        let opener = bytes[index + 1]
        if opener == 0x28 || opener == 0x5B {
          let closingByte: UInt8 = opener == 0x28 ? 0x29 : 0x5D
          if let close = slashClose(start: index, closingByte: closingByte) {
            appendText(textStart..<index)
            result.append(.math(source: string((index + 2)..<close), display: opener == 0x5B))
            index = close + 2
            textStart = index
            continue
          }
          index += 2
          continue
        }
      }

      index += 1
    }

    appendText(textStart..<bytes.count)
    return result
  }
}

private extension UInt8 {
  var isASCIISpace: Bool {
    self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
  }

  var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }
}
