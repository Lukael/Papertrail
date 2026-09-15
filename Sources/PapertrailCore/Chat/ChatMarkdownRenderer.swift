import Foundation

/// Converts chat Markdown to a small, safe HTML subset.
///
/// Foundation owns Markdown parsing. This type only maps the parsed presentation
/// intents to app-owned markup, so raw HTML and unsafe link destinations never
/// become active web content.
public enum ChatMarkdownRenderer {
  typealias MathRenderer = (_ source: String, _ display: Bool) -> String

  private enum BlockKind {
    case paragraph
    case heading(Int)
    case code
    case thematicBreak
  }

  private enum ListKind {
    case ordered
    case unordered
  }

  private struct ListLevel {
    let kind: ListKind
    let listIdentity: Int
    let itemIdentity: Int
    let ordinal: Int
  }

  private struct Block {
    let kind: BlockKind
    let quoteDepth: Int
    let lists: [ListLevel]
    var html: String
  }

  private struct MathPlaceholder {
    let token: String
    let html: String
  }

  /// Returns true only when Markdown parsing finds formatting that needs HTML.
  /// Plain messages keep their lightweight native `Text` presentation.
  public static func requiresHTML(in source: String) -> Bool {
    if ChatMarkdownTable.containsTable(in: source) { return true }
    guard let attributed = parsed(source, syntax: .full) else { return false }
    for run in attributed.runs {
      if run.inlinePresentationIntent != nil || run.link != nil || run.imageURL != nil {
        return true
      }
      guard let presentation = run.presentationIntent else { continue }
      for component in presentation.components {
        switch component.kind {
        case .header, .orderedList, .unorderedList, .listItem, .blockQuote, .codeBlock,
          .thematicBreak:
          return true
        default:
          continue
        }
      }
    }

    // Backslash escapes intentionally remove Markdown punctuation without
    // attaching a presentation intent to the resulting character.
    return source.range(of: #"\\[\\`*_{}\[\]()#+\-.!>|~]"#, options: .regularExpression) != nil
  }

  static func htmlFragment(for source: String, renderMath: MathRenderer) -> String {
    let prepared = replaceMath(in: source, renderMath: renderMath)
    guard let attributed = parsed(prepared.source, syntax: .full) else {
      return restoreMath(
        in: escapeHTML(source).replacingOccurrences(of: "\n", with: "<br>"),
        placeholders: prepared.placeholders)
    }

    var blocks: [Block] = []
    var activeIdentity: Int?
    for run in attributed.runs {
      let description = describe(run.presentationIntent)
      if blocks.isEmpty || activeIdentity != description.identity {
        blocks.append(
          Block(
            kind: description.kind,
            quoteDepth: description.quoteDepth,
            lists: description.lists,
            html: ""
          )
        )
        activeIdentity = description.identity
      }

      let value = String(attributed[run.range].characters)
      if case .thematicBreak = description.kind { continue }
      if case .code = description.kind {
        blocks[blocks.count - 1].html += escapeHTML(value)
      } else {
        blocks[blocks.count - 1].html += renderInline(
          value,
          intent: run.inlinePresentationIntent,
          link: run.link,
          imageURL: run.imageURL
        )
      }
    }

    let html = render(blocks: blocks)
    return restoreMath(in: html, placeholders: prepared.placeholders)
  }

  static func inlineHTML(for source: String, renderMath: MathRenderer) -> String {
    let prepared = replaceMath(in: source, renderMath: renderMath)
    guard let attributed = parsed(prepared.source, syntax: .inlineOnlyPreservingWhitespace) else {
      return escapeHTML(source)
    }
    let html = attributed.runs.map { run in
      renderInline(
        String(attributed[run.range].characters),
        intent: run.inlinePresentationIntent,
        link: run.link,
        imageURL: run.imageURL
      )
    }.joined()
    return restoreMath(in: html, placeholders: prepared.placeholders)
  }

  private static func parsed(
    _ source: String,
    syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
  ) -> AttributedString? {
    try? AttributedString(
      markdown: source,
      options: .init(
        interpretedSyntax: syntax,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    )
  }

  private static func describe(_ intent: PresentationIntent?) -> (
    identity: Int?, kind: BlockKind, quoteDepth: Int, lists: [ListLevel]
  ) {
    guard let intent else { return (nil, .paragraph, 0, []) }
    let components = Array(intent.components)
    let leaf = components.first
    let kind: BlockKind
    switch leaf?.kind {
    case .header(let level): kind = .heading(level)
    case .codeBlock: kind = .code
    case .thematicBreak: kind = .thematicBreak
    default: kind = .paragraph
    }

    var quoteDepth = 0
    var pendingListItem: (identity: Int, ordinal: Int)?
    var innerToOuterLists: [ListLevel] = []
    for component in components {
      switch component.kind {
      case .blockQuote:
        quoteDepth += 1
      case .listItem(let ordinal):
        pendingListItem = (component.identity, ordinal)
      case .orderedList:
        if let item = pendingListItem {
          innerToOuterLists.append(
            ListLevel(
              kind: .ordered,
              listIdentity: component.identity,
              itemIdentity: item.identity,
              ordinal: item.ordinal
            )
          )
        }
        pendingListItem = nil
      case .unorderedList:
        if let item = pendingListItem {
          innerToOuterLists.append(
            ListLevel(
              kind: .unordered,
              listIdentity: component.identity,
              itemIdentity: item.identity,
              ordinal: item.ordinal
            )
          )
        }
        pendingListItem = nil
      default:
        continue
      }
    }
    return (leaf?.identity, kind, quoteDepth, innerToOuterLists.reversed())
  }

  private static func render(blocks: [Block]) -> String {
    var html = ""
    var openLists: [ListLevel] = []
    var openQuoteDepth = 0

    func listTag(_ kind: ListKind) -> String {
      switch kind {
      case .ordered: return "ol"
      case .unordered: return "ul"
      }
    }

    func openList(_ level: ListLevel) -> String {
      switch level.kind {
      case .ordered: return "<ol start=\"\(level.ordinal)\">"
      case .unordered: return "<ul>"
      }
    }

    func openItem(_ level: ListLevel) -> String {
      switch level.kind {
      case .ordered: return "<li value=\"\(level.ordinal)\">"
      case .unordered: return "<li>"
      }
    }

    func closeAllLists() {
      for level in openLists.reversed() {
        html += "</li></\(listTag(level.kind))>"
      }
      openLists.removeAll(keepingCapacity: true)
    }

    func changeQuoteDepth(to depth: Int) {
      if openQuoteDepth > depth {
        for _ in depth..<openQuoteDepth { html += "</blockquote>" }
      } else if openQuoteDepth < depth {
        for _ in openQuoteDepth..<depth { html += "<blockquote>" }
      }
      openQuoteDepth = depth
    }

    for block in blocks {
      if block.quoteDepth != openQuoteDepth {
        closeAllLists()
        changeQuoteDepth(to: block.quoteDepth)
      }

      guard !block.lists.isEmpty else {
        closeAllLists()
        html += renderBareBlock(block)
        continue
      }

      var divergence = 0
      while divergence < openLists.count, divergence < block.lists.count {
        let old = openLists[divergence]
        let new = block.lists[divergence]
        guard old.listIdentity == new.listIdentity, old.itemIdentity == new.itemIdentity else {
          break
        }
        divergence += 1
      }

      var retainedListAtDivergence = false
      if divergence < openLists.count {
        for depth in stride(from: openLists.count - 1, through: divergence + 1, by: -1) {
          let old = openLists[depth]
          html += "</li></\(listTag(old.kind))>"
        }
        if divergence < block.lists.count,
          openLists[divergence].listIdentity == block.lists[divergence].listIdentity
        {
          html += "</li>"
          retainedListAtDivergence = true
        } else {
          let old = openLists[divergence]
          html += "</li></\(listTag(old.kind))>"
        }
        openLists.removeSubrange(divergence...)
      }

      if divergence < block.lists.count {
        for depth in divergence..<block.lists.count {
          let level = block.lists[depth]
          if depth == divergence, retainedListAtDivergence {
            html += openItem(level)
          } else {
            html += openList(level) + openItem(level)
          }
          if depth < openLists.count {
            openLists[depth] = level
          } else {
            openLists.append(level)
          }
        }
      }
      html += renderBareBlock(block)
    }

    closeAllLists()
    changeQuoteDepth(to: 0)
    return html
  }

  private static func renderBareBlock(_ block: Block) -> String {
    let content: String
    switch block.kind {
    case .heading(let level):
      let safeLevel = min(max(level, 1), 6)
      content = "<h\(safeLevel)>\(block.html)</h\(safeLevel)>"
    case .paragraph:
      content = "<p>\(block.html)</p>"
    case .code:
      content = "<pre><code>\(block.html)</code></pre>"
    case .thematicBreak:
      content = "<hr>"
    }

    return content
  }

  private static func renderInline(
    _ source: String,
    intent: InlinePresentationIntent?,
    link: URL?,
    imageURL: URL?
  ) -> String {
    var html = escapeHTML(source).replacingOccurrences(of: "\n", with: "<br>")
    if imageURL != nil {
      html = "<span class=\"image-alt\">\(html)</span>"
    }
    if let intent {
      if intent.contains(.code) { html = "<code>\(html)</code>" }
      if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
      if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
      if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
    }
    if let link, isAllowed(link: link) {
      html = "<a href=\"\(escapeHTML(link.absoluteString))\">\(html)</a>"
    }
    return html
  }

  private static func isAllowed(link: URL) -> Bool {
    guard let scheme = link.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto"
  }

  private static func replaceMath(
    in source: String,
    renderMath: MathRenderer
  ) -> (source: String, placeholders: [MathPlaceholder]) {
    var replaced = ""
    var placeholders: [MathPlaceholder] = []
    var prefix = "\u{F0000}PTMATH-\(UUID().uuidString)-"
    while source.contains(prefix) { prefix += "X" }
    for segment in ChatMathContent.segments(in: source) {
      switch segment {
      case .text(let text):
        replaced += text
      case .math(let math, let display):
        let token = "\(prefix)\(placeholders.count)\u{F0001}"
        placeholders.append(MathPlaceholder(token: token, html: renderMath(math, display)))
        replaced += token
      }
    }
    return (replaced, placeholders)
  }

  private static func restoreMath(in html: String, placeholders: [MathPlaceholder]) -> String {
    placeholders.reduce(html) { result, placeholder in
      result.replacingOccurrences(of: placeholder.token, with: placeholder.html)
    }
  }

  private static func escapeHTML(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.utf8.count)
    for character in value {
      switch character {
      case "&": escaped += "&amp;"
      case "<": escaped += "&lt;"
      case ">": escaped += "&gt;"
      case "\"": escaped += "&quot;"
      case "'": escaped += "&#39;"
      default: escaped.append(character)
      }
    }
    return escaped
  }
}
