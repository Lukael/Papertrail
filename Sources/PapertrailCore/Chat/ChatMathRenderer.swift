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
    let body = ChatMathContent.segments(in: text).map { segment in
      switch segment {
      case .text(let value):
        return "<span class=\"text\">\(Self.escapeHTML(value))</span>"
      case .math(let source, let display):
        return render(source: source, display: display)
      }
    }.joined()

    return """
      <!doctype html>
      <html xmlns="http://www.w3.org/1999/xhtml">
      <head>
      <meta charset="utf-8">
      <meta name="color-scheme" content="light dark">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
      <style>
      :root { color-scheme: light dark; font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
      html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; }
      #content { overflow-wrap: anywhere; }
      .text { white-space: pre-wrap; }
      .math-inline { display: inline; white-space: normal; }
      .math-display { display: block; overflow-x: auto; overflow-y: hidden; padding: 0.2em 0; white-space: normal; }
      .math-unsupported { white-space: pre-wrap; text-decoration: underline dotted; text-decoration-color: #cc7a00; }
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
