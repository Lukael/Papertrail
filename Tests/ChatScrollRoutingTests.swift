import AppKit

@MainActor private final class RecordingScrollView: NSScrollView {
  var events: [NSEvent] = []
  override func scrollWheel(with event: NSEvent) { events.append(event) }
}

@MainActor private final class NativeMessageView: NSView {
  var events: [NSEvent] = []
  override func scrollWheel(with event: NSEvent) { events.append(event) }
}

@MainActor private final class FlippedDocumentView: NSView {
  override var isFlipped: Bool { true }
}

@main struct ChatScrollRoutingTests {
  @MainActor static func main() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    window.contentView = root
    let transcript = RecordingScrollView(frame: root.bounds)
    root.addSubview(transcript)
    let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 500000))
    transcript.documentView = document
    let firstMessage = NativeMessageView()
    let secondMessage = NativeMessageView()
    document.addSubview(firstMessage)
    document.addSubview(secondMessage)
    let unrelated = NSView()
    root.addSubview(unrelated)
    let router = ChatScrollEventRouter.shared
    router.register(transcript)
    defer { router.unregister(transcript) }

    func wheel(x: Int32 = 0, y: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent {
      let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
        wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
      return NSEvent(cgEvent: cg)!
    }
    let mayBegin = wheel(phase: 128)
    let begin = wheel(phase: 1)
    let changed = wheel(y: -20, phase: 2)
    let lift = wheel(phase: 4)
    let momentumStart = wheel(momentum: 1)
    let momentumChange = wheel(y: -8, momentum: 2)
    let momentumEnd = wheel(momentum: 3)
    precondition(begin.phase == .began && lift.phase == .ended)
    precondition(momentumStart.momentumPhase == .began && momentumEnd.momentumPhase == .ended)
    // The content under the cursor changes after gesture onset. AppKit keeps the
    // original recipient, so the router must retain the original transcript too.
    for (event, hit) in [(mayBegin, firstMessage), (begin, firstMessage), (changed, firstMessage), (lift, secondMessage),
      (momentumStart, secondMessage), (momentumChange, unrelated), (momentumEnd, unrelated)] {
      precondition(router.routeScroll(event, startingAt: hit) == nil, "lost gesture phase")
    }
    precondition(transcript.contentView.bounds.origin.y == 28)
    let outsideStart = wheel(y: -10, phase: 1)
    precondition(router.routeScroll(outsideStart, startingAt: unrelated) === outsideStart)
    let outsideChanged = wheel(y: -8, phase: 2)
    precondition(router.routeScroll(outsideChanged, startingAt: firstMessage) === outsideChanged)
    precondition(transcript.contentView.bounds.origin.y == 28)

    // Pure horizontal gestures remain native even if their pointer later enters a
    // different message; zero-delta beginnings must not force vertical ownership.
    let beforeHorizontal = transcript.events.count
    _ = router.routeScroll(wheel(phase: 1), startingAt: firstMessage)
    let horizontal = wheel(x: 15, phase: 2)
    precondition(router.routeScroll(horizontal, startingAt: secondMessage) == nil)
    let horizontalTail = wheel(x: 8, momentum: 2)
    precondition(router.routeScroll(horizontalTail, startingAt: secondMessage) == nil)
    _ = router.routeScroll(wheel(momentum: 3), startingAt: secondMessage)

    precondition(transcript.events.count == beforeHorizontal)
    precondition(firstMessage.events.count == 4 && secondMessage.events.isEmpty)
    _ = router.routeScroll(begin, startingAt: firstMessage)
    _ = router.routeScroll(wheel(x: 1, phase: 2), startingAt: secondMessage)
    _ = router.routeScroll(changed, startingAt: secondMessage)
    _ = router.routeScroll(momentumEnd, startingAt: unrelated)
    precondition(transcript.contentView.bounds.origin.y == 48, "horizontal onset jitter must not lock a vertical swipe")
    precondition(firstMessage.events.count == 4, "provisional jitter must stay buffered")
    let positionBefore = transcript.contentView.bounds.origin.y
    for _ in 0..<1_000 {
      for (event, hit) in [(begin, firstMessage), (changed, secondMessage), (lift, secondMessage),
        (momentumStart, unrelated), (momentumChange, unrelated), (momentumEnd, unrelated)] {
        precondition(router.routeScroll(event, startingAt: hit) == nil)
      }
    }
    precondition(transcript.contentView.bounds.origin.y == positionBefore + 28_000)
    precondition(transcript.events.isEmpty, "trackpad must not start a second native tracking loop")
    _ = router.routeScroll(wheel(y: 1_000_000, phase: 1), startingAt: firstMessage)
    precondition(transcript.contentView.bounds.origin.y == 0, "upward gesture must clamp at top")
    _ = router.routeScroll(wheel(y: -1_000_000, phase: 2), startingAt: unrelated)
    let bottom = transcript.contentView.bounds.origin.y
    _ = router.routeScroll(momentumChange, startingAt: unrelated)
    precondition(transcript.contentView.bounds.origin.y == bottom, "momentum must clamp at bottom")
    _ = router.routeScroll(wheel(y: 20, phase: 1), startingAt: firstMessage)
    precondition(transcript.contentView.bounds.origin.y == bottom - 20, "reverse gesture must leave edge")
    _ = router.routeScroll(begin, startingAt: firstMessage)
    _ = router.routeScroll(changed, startingAt: firstMessage)
    router.unregister(transcript)
    precondition(router.routeScroll(momentumChange, startingAt: firstMessage) === momentumChange)
    print("PASS 1,000 complete trackpad gestures: zero-delta onset, finger lift, momentum across message boundaries, horizontal and detach isolation")
  }
}
