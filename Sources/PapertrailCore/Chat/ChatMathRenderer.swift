import Foundation
import JavaScriptCore

public enum ChatMathRendererError: Error, LocalizedError {
  case resourceMissing
  case resourceUnreadable
  case javaScriptContextUnavailable
  case katexInitializationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .resourceMissing:
      return "The bundled KaTeX renderer is missing."
    case .resourceUnreadable:
      return "The bundled KaTeX renderer could not be read."
    case .javaScriptContextUnavailable:
      return "The local math rendering context could not be created."
    case .katexInitializationFailed(let detail):
      return "The bundled KaTeX renderer could not be initialized: \(detail)"
    }
  }
}

/// Converts app-owned chat text to a self-contained HTML document containing MathML.
/// KaTeX runs locally during document construction; the resulting web view needs no scripts.
@MainActor
public final class ChatMathRenderer {
  public static let shared: Result<ChatMathRenderer, Error> = Result {
    try ChatMathRenderer()
  }

  private struct CacheKey: Hashable {
    let source: String
    let display: Bool
  }

  private static let maximumSourceBytes = 16 * 1024
  private static let maximumCacheEntries = 128

  private let context: JSContext
  private let renderToString: JSValue
  private var cache: [CacheKey: String] = [:]
  private var cacheOrder: [CacheKey] = []

  public init() throws {
    guard let scriptURL = Self.katexScriptURL() else {
      throw ChatMathRendererError.resourceMissing
    }
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
      throw ChatMathRendererError.resourceUnreadable
    }
    guard let context = JSContext() else {
      throw ChatMathRendererError.javaScriptContextUnavailable
    }

    context.exception = nil
    context.evaluateScript(script, withSourceURL: scriptURL)
    if let exception = context.exception {
      throw ChatMathRendererError.katexInitializationFailed(exception.toString())
    }
    guard let katex = context.objectForKeyedSubscript("katex"), !katex.isUndefined,
      let renderToString = katex.objectForKeyedSubscript("renderToString"),
      !renderToString.isUndefined
    else {
      throw ChatMathRendererError.katexInitializationFailed("renderToString is unavailable")
    }

    self.context = context
    self.renderToString = renderToString
  }

  private static func katexScriptURL() -> URL? {
    if Bundle.main.bundleURL.pathExtension == "app" {
      guard let resources = Bundle.main.resourceURL,
        let resourceBundle = Bundle(
          url: resources.appendingPathComponent("Papertrail_PapertrailCore.bundle", isDirectory: true)
        )
      else { return nil }
      return resourceBundle.url(
        forResource: "katex.min",
        withExtension: "js",
        subdirectory: "KaTeX"
      )
    }

    return Bundle.module.url(
      forResource: "katex.min",
      withExtension: "js",
      subdirectory: "KaTeX"
    )
  }

  public func html(for text: String) -> String {
    let body = ChatMarkdownTable.blocks(in: text).map { block in
      switch block {
      case .text(let value):
        return ChatMarkdownRenderer.htmlFragment(for: value) { source, display in
          self.render(source: source, display: display)
        }
      case .table(let table):
        return render(table: table)
      }
    }.joined()

    return document(body: body)
  }

  private func render(table: ChatMarkdownTable.Table) -> String {
    func cell(_ value: String, header: Bool, alignment: ChatMarkdownTable.Alignment) -> String {
      let tag = header ? "th" : "td"
      let cssAlignment: String
      switch alignment {
      case .leading: cssAlignment = "left"
      case .center: cssAlignment = "center"
      case .trailing: cssAlignment = "right"
      }
      return "<\(tag) style=\"text-align:\(cssAlignment)\">\(renderTableCell(value))</\(tag)>"
    }

    let header = zip(table.headers, table.alignments).map {
      cell($0.0, header: true, alignment: $0.1)
    }.joined()
    let rows = table.rows.map { row in
      let columns = zip(row, table.alignments).map {
        cell($0.0, header: false, alignment: $0.1)
      }.joined()
      return "<tr>\(columns)</tr>"
    }.joined()
    return "<div class=\"table-scroll\"><table><thead><tr>\(header)</tr></thead><tbody>\(rows)</tbody></table></div>"
  }

  private func renderTableCell(_ value: String) -> String {
    ChatMarkdownRenderer.inlineHTML(for: value) { source, display in
      self.render(source: source, display: display)
    }
  }

  private func document(body: String) -> String {

    return """
      <!doctype html>
      <html xmlns="http://www.w3.org/1999/xhtml">
      <head>
      <meta charset="utf-8">
      <meta name="color-scheme" content="light dark">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
      <style>
      :root { color-scheme: light dark; font: 13px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
      /* Keep the document viewport fixed; #content retains its natural height for native sizing. */
      html, body { height: 100%; margin: 0; padding: 0; background: transparent; color: CanvasText; overflow: clip; }
      #content { display: flow-root; overflow-wrap: anywhere; }
      .text { white-space: pre-wrap; }
      p { margin: 0.8em 0; }
      h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 0.65em 0 0.3em; }
      h1 { font-size: 1.55em; } h2 { font-size: 1.4em; } h3 { font-size: 1.25em; }
      h4 { font-size: 1.12em; } h5 { font-size: 1em; } h6 { font-size: 0.92em; }
      ul, ol { margin: 0.35em 0; padding-left: 1.75em; }
      li > p { margin: 0.15em 0; }
      blockquote { margin: 0.45em 0; padding: 0.05em 0.75em; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); color: color-mix(in srgb, CanvasText 78%, transparent); }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; background: color-mix(in srgb, CanvasText 8%, transparent); border-radius: 4px; padding: 0.08em 0.25em; }
      pre { max-width: 100%; overflow-x: auto; overflow-y: hidden; margin: 0.5em 0; padding: 0.65em 0.75em; background: color-mix(in srgb, CanvasText 8%, transparent); border-radius: 6px; white-space: pre; }
      pre { line-height: 1.4; }
      pre code { background: transparent; padding: 0; }
      a { color: LinkText; text-decoration: underline; }
      .image-alt { font-style: italic; }
      hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 22%, transparent); margin: 0.75em 0; }
      .math-inline { display: inline; white-space: normal; }
      .math-display { display: block; overflow-x: auto; overflow-y: hidden; padding: 0.2em 0; white-space: normal; }
      .math-unsupported { white-space: pre-wrap; text-decoration: underline dotted; text-decoration-color: #cc7a00; }
      .table-scroll { width: 100%; overflow-x: auto; overflow-y: hidden; margin: 0.35em 0; }
      table { line-height: 1.4; border-collapse: collapse; min-width: 100%; width: max-content; }
      th, td { border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); min-width: 5em; max-width: 24em; padding: 0.4em 0.55em; vertical-align: top; white-space: normal; }
      th { background: color-mix(in srgb, CanvasText 7%, transparent); font-weight: 600; }
      math { font-size: 1.05em; }
      </style>
      </head>
      <body><div id="content">\(body)</div></body>
      </html>
      """
  }

  private func render(source: String, display: Bool) -> String {
    let key = CacheKey(source: source, display: display)
    if let cached = cache[key] { return cached }

    guard source.utf8.count <= Self.maximumSourceBytes else {
      return unsupported(source: source, display: display)
    }

    // Source is passed as a JS value. It is never interpolated into evaluated JavaScript.
    let options: [String: Any] = [
      "displayMode": display,
      "output": "mathml",
      "trust": false,
      "throwOnError": true,
      "maxExpand": 1_000,
      "maxSize": 20,
    ]
    context.exception = nil
    guard let result = renderToString.call(withArguments: [source, options]),
      context.exception == nil,
      !result.isUndefined,
      let markup = result.toString(),
      markup.contains("<math")
    else {
      context.exception = nil
      return unsupported(source: source, display: display)
    }

    let cssClass = display ? "math-display" : "math-inline"
    let fragment = "<span class=\"\(cssClass)\">\(markup)</span>"
    insert(fragment, for: key)
    return fragment
  }

  private func insert(_ fragment: String, for key: CacheKey) {
    guard cache[key] == nil else { return }
    if cacheOrder.count == Self.maximumCacheEntries, let oldest = cacheOrder.first {
      cache.removeValue(forKey: oldest)
      cacheOrder.removeFirst()
    }
    cache[key] = fragment
    cacheOrder.append(key)
  }

  private func unsupported(source: String, display: Bool) -> String {
    let delimiter = display ? "$$" : "$"
    let original = delimiter + source + delimiter
    return "<span class=\"math-unsupported\" title=\"Unsupported LaTeX expression\">\(Self.escapeHTML(original))</span>"
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
