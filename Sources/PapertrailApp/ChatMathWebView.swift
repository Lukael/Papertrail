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
    container.removeScrollMonitor()
    let view = container.webView
    view.onWidthChanged = nil
    view.navigationDelegate = nil
    view.stopLoading()
  }

  final class MathContainerView: NSView {
    let webView: SizingWebView
    private static var scrollMonitor: Any?
    private static var monitoredViewCount = 0
    private static weak var forwardedTranscript: NSScrollView?
    private var isMonitoringScroll = false

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

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeScrollMonitor()
      guard window != nil else { return }
      isMonitoringScroll = true
      Self.monitoredViewCount += 1
      guard Self.scrollMonitor == nil else { return }
      // One monitor for all math messages. Hit-testing once per wheel event avoids
      // repeating a full window traversal for every message in a long transcript.
      Self.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        guard let window = event.window, let content = window.contentView else { return event }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        return Self.routeScroll(event, startingAt: hit)
      }
    }

    static func routeScroll(_ event: NSEvent, startingAt hit: NSView?) -> NSEvent? {
      var ancestor = hit
      while let view = ancestor {
        if let message = view as? MathContainerView {
          return message.forwardScroll(event)
        }
        ancestor = view.superview
      }
      return event
    }

    private func forwardScroll(_ event: NSEvent) -> NSEvent? {
      let vertical = event.scrollingDeltaY != 0
      let ending = event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0
        && Self.forwardedTranscript != nil
      // Purely horizontal gestures remain available to wide display equations.
      guard vertical || ending else {
        Self.forwardedTranscript = nil
        return event
      }
      var ancestor = superview
      while let view = ancestor {
        if let transcript = view as? NSScrollView {
          guard vertical || Self.forwardedTranscript === transcript else { return event }
          let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
          Self.forwardedTranscript = finished ? nil : transcript
          transcript.scrollWheel(with: event)
          return nil
        }
        ancestor = view.superview
      }
      return event
    }

    func removeScrollMonitor() {
      guard isMonitoringScroll else { return }
      isMonitoringScroll = false
      Self.monitoredViewCount -= 1
      if Self.monitoredViewCount == 0, let monitor = Self.scrollMonitor {
        NSEvent.removeMonitor(monitor)
        Self.scrollMonitor = nil
        Self.forwardedTranscript = nil
      }
    }
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
      let initialDocument = action.navigationType == .other
        && action.request.url?.absoluteString == "about:blank"
        && action.targetFrame?.isMainFrame == true
      decisionHandler(initialDocument ? .allow : .cancel)
    }
  }
}
