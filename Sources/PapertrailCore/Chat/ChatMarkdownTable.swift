import Foundation

/// Recognizes GitHub-style pipe tables in chat Markdown without requiring a Markdown dependency.
public enum ChatMarkdownTable {
  enum Alignment: Equatable {
    case leading
    case center
    case trailing
  }

  struct Table: Equatable {
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]
  }

  enum Block: Equatable {
    case text(String)
    case table(Table)
  }

  public static func containsTable(in content: String) -> Bool {
    blocks(in: content).contains { block in
      if case .table = block { return true }
      return false
    }
  }

  static func blocks(in content: String) -> [Block] {
    let lines = content.components(separatedBy: "\n")
    guard !lines.isEmpty else { return [] }

    var result: [Block] = []
    var pendingText = ""
    var index = 0
    var fence: (character: Character, length: Int)?

    func appendTextLine(_ line: String, at lineIndex: Int) {
      pendingText += line
      if lineIndex < lines.count - 1 { pendingText += "\n" }
    }

    func flushText() {
      guard !pendingText.isEmpty else { return }
      result.append(.text(pendingText))
      pendingText = ""
    }

    while index < lines.count {
      let line = lines[index]
      if let marker = fenceMarker(in: line) {
        if let openFence = fence {
          if marker.character == openFence.character, marker.length >= openFence.length {
            fence = nil
          }
        } else {
          fence = marker
        }
        appendTextLine(line, at: index)
        index += 1
        continue
      }

      guard fence == nil,
        index + 1 < lines.count,
        let headers = cells(in: line),
        !headers.isEmpty,
        headers.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        let delimiterCells = cells(in: lines[index + 1]),
        delimiterCells.count == headers.count,
        let alignments = delimiterCells.map(delimiterAlignment).allValues
      else {
        appendTextLine(line, at: index)
        index += 1
        continue
      }

      flushText()
      var rows: [[String]] = []
      var rowIndex = index + 2
      while rowIndex < lines.count, !lines[rowIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if fenceMarker(in: lines[rowIndex]) != nil { break }
        guard var row = cells(in: lines[rowIndex]) else { break }
        if row.count < headers.count {
          row.append(contentsOf: repeatElement("", count: headers.count - row.count))
        } else if row.count > headers.count {
          row.removeLast(row.count - headers.count)
        }
        rows.append(row)
        rowIndex += 1
      }

      result.append(
        .table(
          Table(
            headers: headers.map(trimCell),
            alignments: alignments,
            rows: rows.map { $0.map(trimCell) }
          )
        )
      )
      index = rowIndex
    }

    flushText()
    return result
  }

  private static func fenceMarker(in line: String) -> (character: Character, length: Int)? {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
    let length = trimmed.prefix(while: { $0 == character }).count
    return length >= 3 ? (character, length) : nil
  }

  private static func cells(in line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var cells: [String] = []
    var cell = ""
    var slashCount = 0
    var codeDelimiterLength: Int?
    var foundSeparator = false
    let characters = Array(trimmed)
    var index = 0

    while index < characters.count {
      let character = characters[index]
      if character == "`", slashCount.isMultiple(of: 2) {
        var end = index
        while end < characters.count, characters[end] == "`" { end += 1 }
        let runLength = end - index
        if codeDelimiterLength == runLength {
          codeDelimiterLength = nil
        } else if codeDelimiterLength == nil {
          codeDelimiterLength = runLength
        }
        cell.append(contentsOf: characters[index..<end])
        slashCount = 0
        index = end
        continue
      }

      if character == "|", codeDelimiterLength == nil, slashCount.isMultiple(of: 2) {
        cells.append(cell)
        cell = ""
        foundSeparator = true
      } else {
        if character == "|", slashCount % 2 == 1, cell.last == "\\" {
          cell.removeLast()
        }
        cell.append(character)
      }

      slashCount = character == "\\" ? slashCount + 1 : 0
      index += 1
    }
    cells.append(cell)

    guard foundSeparator else { return nil }
    if trimmed.first == "|" { cells.removeFirst() }
    if trimmed.last == "|", cells.last?.isEmpty == true { cells.removeLast() }
    return cells
  }

  private static func delimiterAlignment(_ source: String) -> Alignment? {
    var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let leadingColon = value.first == ":"
    let trailingColon = value.last == ":"
    if leadingColon { value.removeFirst() }
    if trailingColon, !value.isEmpty { value.removeLast() }
    guard value.count >= 3, value.allSatisfy({ $0 == "-" }) else { return nil }
    if leadingColon, trailingColon { return .center }
    if trailingColon { return .trailing }
    return .leading
  }

  private static func trimCell(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private extension Array where Element == ChatMarkdownTable.Alignment? {
  var allValues: [ChatMarkdownTable.Alignment]? {
    guard allSatisfy({ $0 != nil }) else { return nil }
    return compactMap { $0 }
  }
}
