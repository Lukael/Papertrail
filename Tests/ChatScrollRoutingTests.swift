import AppKit
import WebKit

@MainActor
private final class RecordingScrollView: NSScrollView {
  var events = 0
  var totalY: CGFloat = 0
  override func scrollWheel(with event: NSEvent) {
    events += 1
    totalY += event.scrollingDeltaY
  }
}

@main
struct ChatScrollRoutingTests {
  @MainActor static func main() {
    _ = NSApplication.shared
    let transcript = RecordingScrollView()
    let document = NSView()
    transcript.documentView = document
    let configuration = WKWebViewConfiguration()
    let webView = ChatMathWebView.SizingWebView(frame: .zero, configuration: configuration)
    let message = ChatMathWebView.MathContainerView(webView: webView)
    document.addSubview(message)
    let webContent = NSView()
    webView.addSubview(webContent)

    func wheel(x: Int32, y: Int32) -> NSEvent {
      NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!)!
    }
    let up = wheel(x: 0, y: 10)
    let down = wheel(x: 0, y: -10)
    let diagonal = wheel(x: 20, y: 1)
    let horizontal = wheel(x: 20, y: 0)
    let end = wheel(x: 0, y: 0)
    let start = ContinuousClock.now
    for _ in 0..<5_000 {
      precondition(ChatMathWebView.MathContainerView.routeScroll(up, startingAt: webContent) == nil)
      precondition(ChatMathWebView.MathContainerView.routeScroll(down, startingAt: webContent) == nil)
    }
    precondition(transcript.events == 10_000 && transcript.totalY == 0)
    precondition(ChatMathWebView.MathContainerView.routeScroll(diagonal, startingAt: webContent) == nil)
    let secondWebView = ChatMathWebView.SizingWebView(frame: .zero, configuration: configuration)
    let secondMessage = ChatMathWebView.MathContainerView(webView: secondWebView)
    document.addSubview(secondMessage)
    // A gesture can finish over another message after the transcript moves.
    precondition(ChatMathWebView.MathContainerView.routeScroll(end, startingAt: secondWebView) == nil)
    precondition(transcript.events == 10_002)
    precondition(ChatMathWebView.MathContainerView.routeScroll(horizontal, startingAt: webContent) === horizontal)
    precondition(ChatMathWebView.MathContainerView.routeScroll(up, startingAt: document) === up)
    precondition(ChatMathWebView.MathContainerView.routeScroll(up, startingAt: nil) === up)
    message.removeFromSuperview()
    precondition(ChatMathWebView.MathContainerView.routeScroll(up, startingAt: webContent) === up)
    precondition(transcript.events == 10_002)
    print("PASS 10,000 alternating wheel events, diagonal/end routing, horizontal and unrelated-view isolation (\(start.duration(to: .now)))")
  }
}
