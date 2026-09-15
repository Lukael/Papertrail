import AppKit
import SwiftUI
import PapertrailCore
import WebKit
// In-memory fixture: the production View is compiled by verify-chat-scroll.py.
// No library files, Codex sessions, or user messages are accessed.
struct ChatLiveAssistantState { var reasoning: String?; var response: String? }
@MainActor final class PaperChatController: ObservableObject {
  @Published var messages: [ChatMessageRecord] = []
  @Published var input = ""
  var isLoading = false
  var isRunning = false
  var isAvailable = true
  var liveAssistant: ChatLiveAssistantState?
  var liveRevision = 0
  func canRetry(_ m: ChatMessageRecord) -> Bool { false }
  func retry(_ m: ChatMessageRecord) {}
  func send() {}
  func cancel() {}
  func refreshContext() {}
}
@main @MainActor struct ChatScrollRenderingTests {
  static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--rail-layout") {
      verifyRailLayout()
      return
    }
    let controller = PaperChatController()
    let count = Int(CommandLine.arguments.dropFirst().first ?? "60")!
    let isMath = CommandLine.arguments.contains("--math")
    let isHistoryProbe = CommandLine.arguments.contains("--history-probe")
    let plain = (isMath ? "$x^2+y^2$\n" : "") + String(
      repeating: "일반 텍스트 문장입니다. This is a plain response with no mathematics. ",
      count: isHistoryProbe ? 2 : 50)
    controller.messages = (0..<count).map { i in
      ChatMessageRecord(id: UUID(), paperID: UUID(), sessionID: UUID(), operationID: nil,
        role: i % 2 == 0 ? "user" : "assistant", content: i % 2 == 0 ? "Question \(i)" : plain,
        draft: nil, deliveryState: "committed", createdAt: Date())
    }
    let initialLayoutStarted = CFAbsoluteTimeGetCurrent()
    let hosting = NSHostingView(rootView: PaperChatView(controller: controller))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 760),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Papertrail isolated scroll rendering probe"
    window.contentView = hosting
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let initialLayoutMilliseconds = (CFAbsoluteTimeGetCurrent() - initialLayoutStarted) * 1000
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    func find(_ v: NSView) -> NSScrollView? {
      if let s = v as? NSScrollView { return s }
      for child in v.subviews { if let result = find(child) { return result } }
      return nil
    }
    func countWebViews(_ view: NSView) -> Int {
      (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + countWebViews($1) }
    }
    guard let scroll = find(hosting), let doc = scroll.documentView else { fatalError("No transcript scroll view") }
    let webViewCount = countWebViews(hosting)
    if CommandLine.arguments.contains("--bounded-history") {
      precondition(count == 400, "bounded history probe must exercise 400 messages")
      precondition(webViewCount <= 20, "long history created more than 20 math WebViews")
    }
    if CommandLine.arguments.contains("--all-history") {
      precondition(webViewCount == count / 2, "baseline did not create every assistant math WebView")
    }
    let router = ChatScrollEventRouter.shared
    func event(_ phase: Int64, _ momentum: Int64, _ y: Int32) -> NSEvent {
      let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
        wheel1: y, wheel2: 0, wheel3: 0)!
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
      return NSEvent(cgEvent: cg)!
    }
    var times: [Double] = []
    func send(_ value: NSEvent, hit: NSView) {
      let begin = CFAbsoluteTimeGetCurrent()
      precondition(router.routeScroll(value, startingAt: hit) == nil, "transcript did not retain trackpad gesture")
      hosting.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      times.append((CFAbsoluteTimeGetCurrent()-begin)*1000)
      RunLoop.current.run(until: Date().addingTimeInterval(0.008))
    }
    let initial = scroll.contentView.bounds.origin.y
    send(event(1,0,0), hit: doc)
    for _ in 0..<30 { send(event(2,0,-12), hit: doc) }
    send(event(4,0,0), hit: hosting)
    let fingerEnd = scroll.contentView.bounds.origin.y
    send(event(0,1,0), hit: hosting)
    for _ in 0..<60 { send(event(0,2,-8), hit: hosting) }
    send(event(0,3,0), hit: hosting)
    let finalPosition = scroll.contentView.bounds.origin.y
    precondition(fingerEnd > initial && finalPosition > fingerEnd + 100, "momentum did not continue after finger lift")
    let sorted = times.sorted()
    let result: [String: Any] = ["messages":count,"events":times.count,
      "initial_layout_ms":initialLayoutMilliseconds,"math_webviews":webViewCount,
      "processing_p95_ms":sorted[Int(Double(sorted.count)*0.95)],"processing_max_ms":sorted.last!,
      "initialY":initial,"fingerEndY":fingerEnd,"momentumEndY":finalPosition,
      "documentHeight":doc.frame.height,"status":"passed"]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    window.orderOut(nil)
  }

  static func verifyRailLayout() {
    for count in [1, 30, 200] {
      for width in [300.0, 650.0] {
        let questions = (0..<count).map { i in
          ChatMessageRecord(id: UUID(), paperID: UUID(), sessionID: UUID(), operationID: nil,
            role: "user", content: "Question \(i)", draft: nil,
            deliveryState: "committed", createdAt: Date())
        }
        var measured = CGSize.zero
        let rail = ChatQuestionRail(questions: questions, activeQuestionID: questions.last?.id,
          onSelect: { _ in })
          .background(GeometryReader { geometry in
            Color.clear.onAppear { measured = geometry.size }
              .onChange(of: geometry.size) { measured = geometry.size }
          })
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        let hosting = NSHostingView(rootView: rail)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let expectedHeight = min(CGFloat(count * 14 + 8), 320) + 78
        precondition(abs(measured.width - 46) < 1,
          "Question rail covers transcript: width \(measured.width), expected 46")
        precondition(abs(measured.height - expectedHeight) < 1,
          "Question rail stretches vertically: height \(measured.height), expected \(expectedHeight)")
        window.orderOut(nil)
      }
    }
    print("PASS: question rail remains 46pt wide with content-sized height in 6 native layouts")
  }

}
