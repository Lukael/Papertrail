import AppKit
import SwiftUI
import WebKit

/// Displays app-produced text and MathML. No page scripts or remote resources are permitted.
struct ChatMathWebView: NSViewRepresentable {
  let html: String
  let sourceText: String
  let onHeightChanged: (CGFloat) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onHeightChanged: onHeightChanged) }

  func makeNSView(context: Context) -> MathContainerView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = SizingWebView(frame: .zero, configuration: configuration)
    view.sourceText = sourceText
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = context.coordinator
    view.onWidthChanged = { [weak coordinator = context.coordinator, weak view] in
      guard let view else { return }
      coordinator?.measure(view)
    }
    return MathContainerView(webView: view)
  }

  func updateNSView(_ container: MathContainerView, context: Context) {
    let view = container.webView
    view.sourceText = sourceText
    context.coordinator.onHeightChanged = onHeightChanged
    guard context.coordinator.html != html else { return }
    context.coordinator.html = html
    context.coordinator.loaded = false
    view.loadHTMLString(html, baseURL: nil)
  }

  static func dismantleNSView(_ container: MathContainerView, coordinator: Coordinator) {
    let view = container.webView
    view.onWidthChanged = nil
    view.navigationDelegate = nil
    view.stopLoading()
  }

  final class MathContainerView: NSView {
    let webView: SizingWebView

    init(webView: SizingWebView) {
      self.webView = webView
      super.init(frame: .zero)
      webView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(webView)
      NSLayoutConstraint.activate([
        webView.leadingAnchor.constraint(equalTo: leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        webView.topAnchor.constraint(equalTo: topAnchor),
        webView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    required init?(coder: NSCoder) { nil }
  }

  final class SizingWebView: WKWebView {
    var onWidthChanged: (() -> Void)?
    var sourceText = ""

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
      super.willOpenMenu(menu, with: event)
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      let copySource = NSMenuItem(
        title: "Copy message source", action: #selector(copyMessageSource), keyEquivalent: "")
      copySource.target = self
      menu.addItem(copySource)
    }

    @objc private func copyMessageSource() {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(sourceText, forType: .string)
    }

    override func setFrameSize(_ newSize: NSSize) {
      let changed = abs(frame.width - newSize.width) > 0.5
      super.setFrameSize(newSize)
      if changed { onWidthChanged?() }
    }
  }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
    var html = ""
    var loaded = false
    var onHeightChanged: (CGFloat) -> Void

    init(onHeightChanged: @escaping (CGFloat) -> Void) {
      self.onHeightChanged = onHeightChanged
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      measure(webView)
    }

    func measure(_ webView: WKWebView) {
      guard loaded, webView.bounds.width > 0 else { return }
      let currentHTML = html
      // App-owned DOM measurement; page JavaScript remains disabled.
      webView.evaluateJavaScript("Math.ceil(document.getElementById('content').getBoundingClientRect().height)") {
        [weak self] result, _ in
        guard let self, self.html == currentHTML,
          let number = result as? NSNumber, number.doubleValue.isFinite
        else { return }
        self.onHeightChanged(max(24, CGFloat(number.doubleValue) + 2))
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      if action.navigationType == .linkActivated,
        let url = action.request.url,
        let scheme = url.scheme?.lowercased(),
        ["https", "http", "mailto"].contains(scheme)
      {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      let initialDocument = action.navigationType == .other
        && action.request.url?.absoluteString == "about:blank"
        && action.targetFrame?.isMainFrame == true
      decisionHandler(initialDocument ? .allow : .cancel)
    }
  }
}
