import AppKit
import Foundation
import PapertrailCore
import WebKit

private final class NavigationProbe: NSObject, WKNavigationDelegate {
  var finished = false
  var error: Error?

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finished = true
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    self.error = error
    finished = true
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    self.error = error
    finished = true
  }
}

private struct ScrollMetrics: Decodable {
  let rootOverflowY: String
  let bodyOverflowY: String
  let rootScrollTop: Double
  let rootClientHeight: Double
  let rootScrollHeight: Double
  let contentHeight: Double
  let windowInnerHeight: Double
  let displayScrollLeft: Double
  let displayClientWidth: Double
  let displayScrollWidth: Double
}

@MainActor
func testWebKitScrollIsolation() throws {
  _ = NSApplication.shared

  let lines = (1...80).map { "Long chat line \($0)" }.joined(separator: "\n")
  let wideTerms = (1...80).map { "x_{\($0)}" }.joined(separator: "+")
  let message = "\(lines)\n$$\(wideTerms)$$"
  let renderer = try ChatMathRenderer()
  let html = renderer.html(for: message)
  let metrics = try scrollMetrics(for: html)

  guard metrics.contentHeight > metrics.windowInnerHeight else {
    throw TestFailure(description: "fixture did not create tall chat content: \(metrics)")
  }
  guard metrics.rootOverflowY == "clip", metrics.bodyOverflowY == "clip" else {
    throw TestFailure(
      description: "chat document must clip root vertical overflow, got html=\(metrics.rootOverflowY), body=\(metrics.bodyOverflowY)"
    )
  }
  guard metrics.rootScrollTop == 0 else {
    throw TestFailure(description: "chat document scrolled internally to \(metrics.rootScrollTop)")
  }
  guard metrics.displayScrollWidth > metrics.displayClientWidth,
    metrics.displayScrollLeft > 0
  else {
    throw TestFailure(description: "display math lost horizontal scrolling: \(metrics)")
  }

  let previousHTML = html
    .replacingOccurrences(of: "height: 100%; ", with: "")
    .replacingOccurrences(of: " overflow: clip;", with: "")
  let previousMetrics = try scrollMetrics(for: previousHTML)
  guard previousMetrics.rootScrollHeight > previousMetrics.rootClientHeight,
    previousMetrics.rootScrollTop > 0
  else {
    throw TestFailure(description: "negative control did not reproduce root document scrolling: \(previousMetrics)")
  }

  print("PASS WebKit root vertical scroll disabled and display math horizontal scroll preserved")

  let header = "|" + (1...12).map { "Column \($0)" }.joined(separator: "|") + "|"
  let separator = "|" + Array(repeating: "---", count: 12).joined(separator: "|") + "|"
  let row = "|" + Array(repeating: "Measurement value", count: 12).joined(separator: "|") + "|"
  let table = ([header, separator] + Array(repeating: row, count: 30)).joined(separator: "\n")
  let tableMetrics = try scrollMetrics(for: renderer.html(for: table))
  guard tableMetrics.displayScrollWidth > tableMetrics.displayClientWidth,
    tableMetrics.displayScrollLeft > 0,
    tableMetrics.rootScrollTop == 0,
    tableMetrics.rootOverflowY == "clip",
    tableMetrics.contentHeight > tableMetrics.windowInnerHeight
  else {
    throw TestFailure(description: "wide/tall Markdown table broke scroll isolation: \(tableMetrics)")
  }
  print("PASS WebKit Markdown table horizontal scrolling and full content height")

  let code = String(repeating: "value += 1; ", count: 80)
  let markdown = "### Heading\n\n> Quote\n\n- First\n- Second\n\n```swift\n\(code)\n```"
  let codeMetrics = try scrollMetrics(for: renderer.html(for: markdown))
  guard codeMetrics.displayScrollWidth > codeMetrics.displayClientWidth,
    codeMetrics.displayScrollLeft > 0,
    codeMetrics.rootScrollTop == 0,
    codeMetrics.contentHeight > codeMetrics.windowInnerHeight
  else {
    throw TestFailure(description: "Markdown code block broke scroll isolation: \(codeMetrics)")
  }
  print("PASS WebKit formatted Markdown and horizontal code scrolling")
}

@MainActor
private func scrollMetrics(for html: String) throws -> ScrollMetrics {
  let configuration = WKWebViewConfiguration()
  configuration.websiteDataStore = .nonPersistent()
  configuration.defaultWebpagePreferences.allowsContentJavaScript = false
  let webView = WKWebView(
    frame: NSRect(x: 0, y: 0, width: 320, height: 80),
    configuration: configuration
  )
  let navigationProbe = NavigationProbe()
  webView.navigationDelegate = navigationProbe
  webView.loadHTMLString(html, baseURL: nil)

  let loadDeadline = Date().addingTimeInterval(5)
  while !navigationProbe.finished, Date() < loadDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  if let error = navigationProbe.error {
    throw TestFailure(description: "WebKit navigation failed: \(error.localizedDescription)")
  }
  guard navigationProbe.finished else {
    throw TestFailure(description: "WebKit navigation timed out")
  }

  let script = """
    (() => {
      const root = document.scrollingElement;
      const display = document.querySelector('.table-scroll, .math-display, pre');
      root.scrollTop = 60;
      display.scrollLeft = 60;
      return JSON.stringify({
        rootOverflowY: getComputedStyle(document.documentElement).overflowY,
        bodyOverflowY: getComputedStyle(document.body).overflowY,
        rootScrollTop: root.scrollTop,
        rootClientHeight: root.clientHeight,
        rootScrollHeight: root.scrollHeight,
        contentHeight: document.getElementById('content').getBoundingClientRect().height,
        windowInnerHeight: window.innerHeight,
        displayScrollLeft: display.scrollLeft,
        displayClientWidth: display.clientWidth,
        displayScrollWidth: display.scrollWidth
      });
    })()
    """
  let result = try evaluate(script, in: webView)
  guard let encodedMetrics = result as? String,
    let data = encodedMetrics.data(using: .utf8)
  else {
    throw TestFailure(description: "WebKit returned unexpected scroll metrics: \(String(describing: result))")
  }
  let metrics = try JSONDecoder().decode(ScrollMetrics.self, from: data)
  return metrics
}

@MainActor
private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
  var completed = false
  var result: Any?
  var evaluationError: Error?
  webView.evaluateJavaScript(script) { value, error in
    result = value
    evaluationError = error
    completed = true
  }

  let evaluationDeadline = Date().addingTimeInterval(5)
  while !completed, Date() < evaluationDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  if let evaluationError {
    throw TestFailure(description: "WebKit evaluation failed: \(evaluationError.localizedDescription)")
  }
  guard completed else {
    throw TestFailure(description: "WebKit evaluation timed out")
  }
  return result
}
