import AppKit
import SwiftUI

/// Keeps one chat transcript as the destination for the full lifetime of a
/// trackpad gesture, including the momentum events that follow finger lift.
@MainActor
final class ChatScrollEventRouter {
  static let shared = ChatScrollEventRouter()

  private final class WeakScrollView {
    weak var value: NSScrollView?
    var registrationCount = 1

    init(_ value: NSScrollView) {
      self.value = value
    }
  }

  private enum GestureDirection {
    case provisional
    case vertical
    case horizontal
  }

  private var registeredScrollViews: [WeakScrollView] = []
  private weak var pinnedScrollView: NSScrollView?
  private weak var pendingResponder: NSView?
  private weak var nativeGestureResponder: NSView?
  private var pendingEvents: [NSEvent] = []
  private var pendingHorizontalDelta: CGFloat = 0
  private var gestureDirection: GestureDirection?
  private var gestureSequenceObserved = false
  private var awaitingBeganAfterMayBegin = false
  private var monitor: Any?

  private init() {}

  func register(_ scrollView: NSScrollView) {
    compactRegistrations()
    if let registration = registeredScrollViews.first(where: { $0.value === scrollView }) {
      registration.registrationCount += 1
      return
    }
    registeredScrollViews.append(WeakScrollView(scrollView))
    installMonitorIfNeeded()
  }

  func unregister(_ scrollView: NSScrollView) {
    if let registration = registeredScrollViews.first(where: { $0.value === scrollView }) {
      registration.registrationCount -= 1
      if registration.registrationCount <= 0 {
        registeredScrollViews.removeAll { $0.value == nil || $0.value === scrollView }
        if pinnedScrollView === scrollView {
          resetGesture()
        }
      }
    } else {
      registeredScrollViews.removeAll { $0.value == nil }
    }
    removeMonitorIfUnused()
  }

  /// Returns `nil` when the event was consumed or buffered for an owned gesture.
  /// Kept internal so the gesture sequence can be covered without installing a
  /// process-wide test monitor.
  func routeScroll(_ event: NSEvent, startingAt hitView: NSView?) -> NSEvent? {
    compactRegistrations()

    let mayBegin = event.phase.contains(.mayBegin)
    let began = event.phase.contains(.began)
    if mayBegin {
      resetGesture()
      gestureSequenceObserved = true
      pinnedScrollView = registeredTranscript(containing: hitView)
      gestureDirection = pinnedScrollView == nil ? nil : .provisional
      pendingResponder = hitView
      awaitingBeganAfterMayBegin = !began
    } else if began, awaitingBeganAfterMayBegin {
      awaitingBeganAfterMayBegin = false
    } else if began {
      resetGesture()
      gestureSequenceObserved = true
      pinnedScrollView = registeredTranscript(containing: hitView)
      gestureDirection = pinnedScrollView == nil ? nil : .provisional
      pendingResponder = hitView
    } else if let pinnedScrollView, let eventWindow = event.window,
      pinnedScrollView.window !== eventWindow
    {
      resetGesture()
      return event
    }

    if event.phase.contains(.cancelled) {
      let result: NSEvent?
      if gestureDirection == .provisional {
        result = nil
      } else if gestureDirection == .horizontal, let nativeGestureResponder {
        nativeGestureResponder.scrollWheel(with: event)
        result = nil
      } else {
        result = forwardTranscriptEventIfNeeded(event)
      }
      resetGesture()
      return result
    }

    if event.phase.isEmpty, event.momentumPhase.isEmpty {
      // Traditional mouse-wheel events are independent. Routing them without
      // pinning prevents stale state from affecting a later trackpad gesture.
      resetGesture()
      guard event.scrollingDeltaY != 0,
        let transcript = registeredTranscript(containing: hitView)
      else { return event }
      transcript.scrollWheel(with: event)
      return nil
    }

    if !gestureSequenceObserved {
      gestureSequenceObserved = true
      pinnedScrollView = registeredTranscript(containing: hitView)
      gestureDirection = pinnedScrollView == nil ? nil : .provisional
      pendingResponder = hitView
    }

    if gestureDirection == .provisional {
      pendingHorizontalDelta += event.scrollingDeltaX
      let finishes = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
      if event.scrollingDeltaY != 0 {
        gestureDirection = .vertical
        forwardPendingEventsToTranscript()
      } else if abs(pendingHorizontalDelta) >= 4 || finishes {
        // Ignore a tiny horizontal onset until direction is clear. Otherwise
        // a one-pixel finger wobble can lock a vertical swipe to a math view.
        gestureDirection = .horizontal
        nativeGestureResponder = pendingResponder
        replayPendingEventsToOriginalResponder()
      } else {
        pendingEvents.append(event)
        if event.momentumPhase.contains(.ended) {
          resetGesture()
        }
        return nil
      }
    }

    let result: NSEvent?
    if gestureDirection == .horizontal, let nativeGestureResponder {
      nativeGestureResponder.scrollWheel(with: event)
      result = nil
    } else {
      result = forwardTranscriptEventIfNeeded(event)
    }
    if event.momentumPhase.contains(.ended) {
      resetGesture()
    }
    // `phase == .ended` deliberately retains the target. AppKit sends momentum
    // as a following sequence, often after the pointer has crossed a message.
    return result
  }

  private func forwardTranscriptEventIfNeeded(_ event: NSEvent) -> NSEvent? {
    guard gestureDirection != .horizontal, let transcript = pinnedScrollView else {
      return event
    }
    applyTrackpadDelta(event, to: transcript)
    return nil
  }

  private func applyTrackpadDelta(_ event: NSEvent, to transcript: NSScrollView) {
    guard event.scrollingDeltaY != 0 else { return }
    // scrollWheel(with:) starts AppKit's own concurrent gesture monitor. This
    // router already owns the stream, including OS-generated momentum deltas;
    // apply those deltas once instead of starting a second tracking loop.
    let clip = transcript.contentView
    var bounds = clip.bounds
    let direction: CGFloat = transcript.documentView?.isFlipped == true ? -1 : 1
    bounds.origin.y += direction * event.scrollingDeltaY
    let constrained = clip.constrainBoundsRect(bounds)
    clip.scroll(to: constrained.origin)
    transcript.reflectScrolledClipView(clip)
  }

  private func forwardPendingEventsToTranscript() {
    guard let transcript = pinnedScrollView else {
      pendingEvents.removeAll(keepingCapacity: true)
      return
    }
    for event in pendingEvents {
      applyTrackpadDelta(event, to: transcript)
    }
    pendingEvents.removeAll(keepingCapacity: true)
    pendingResponder = nil
  }

  private func replayPendingEventsToOriginalResponder() {
    guard let responder = pendingResponder else {
      pendingEvents.removeAll(keepingCapacity: true)
      return
    }
    for event in pendingEvents {
      responder.scrollWheel(with: event)
    }
    pendingEvents.removeAll(keepingCapacity: true)
    pendingResponder = nil
  }

  private func registeredTranscript(containing view: NSView?) -> NSScrollView? {
    var ancestor = view
    while let current = ancestor {
      if let scrollView = current as? NSScrollView,
        registeredScrollViews.contains(where: { $0.value === scrollView })
      {
        return scrollView
      }
      ancestor = current.superview
    }
    return nil
  }

  private func compactRegistrations() {
    registeredScrollViews.removeAll { $0.value == nil }
    removeMonitorIfUnused()
  }

  private func installMonitorIfNeeded() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      let startsGesture = event.phase.contains(.mayBegin) || event.phase.contains(.began)
      let oneShotWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
      let needsHitTest = startsGesture || oneShotWheel || !self.gestureSequenceObserved
      let hitView = needsHitTest
        ? event.window?.contentView.flatMap { contentView in
          contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        }
        : nil
      return self.routeScroll(event, startingAt: hitView)
    }
  }

  private func removeMonitorIfUnused() {
    guard registeredScrollViews.isEmpty, let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
    resetGesture()
  }

  private func resetGesture() {
    pinnedScrollView = nil
    pendingResponder = nil
    nativeGestureResponder = nil
    pendingEvents.removeAll(keepingCapacity: true)
    pendingHorizontalDelta = 0
    gestureDirection = nil
    gestureSequenceObserved = false
    awaitingBeganAfterMayBegin = false
  }
}

/// A non-interactive SwiftUI background that registers only the enclosing chat
/// transcript. PDF and review scroll views never enter the router registry.
struct ChatScrollBoundaryView: NSViewRepresentable {
  func makeNSView(context: Context) -> BoundaryView {
    BoundaryView()
  }

  func updateNSView(_ view: BoundaryView, context: Context) {
    view.refreshRegistration()
  }

  static func dismantleNSView(_ view: BoundaryView, coordinator: Void) {
    view.detach()
  }

  @MainActor final class BoundaryView: NSView {
    private weak var registeredScrollView: NSScrollView?
    /// True while the reader is at the end: loading, streaming and math layout then keep the
    /// transcript there instead of leaving it wherever the first, shorter layout put it.
    private var followsEnd = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      scheduleRegistrationRefresh()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        detach()
      } else {
        scheduleRegistrationRefresh()
      }
    }

    func refreshRegistration() {
      guard window != nil else {
        detach()
        return
      }
      var ancestor = superview
      var transcript: NSScrollView?
      while let current = ancestor {
        if let scrollView = current as? NSScrollView {
          transcript = scrollView
          break
        }
        ancestor = current.superview
      }
      guard transcript !== registeredScrollView else { return }
      detach()
      if let transcript {
        ChatScrollEventRouter.shared.register(transcript)
        registeredScrollView = transcript
        followEnd(of: transcript)
      }
    }

    func detach() {
      guard let registeredScrollView else { return }
      ChatScrollEventRouter.shared.unregister(registeredScrollView)
      NotificationCenter.default.removeObserver(self)
      self.registeredScrollView = nil
    }

    /// A transcript opens at its latest message.
    private func followEnd(of scrollView: NSScrollView) {
      guard let document = scrollView.documentView else { return }
      scrollView.contentView.postsBoundsChangedNotifications = true
      document.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(readerScrolled), name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView)
      NotificationCenter.default.addObserver(
        self, selector: #selector(contentResized), name: NSView.frameDidChangeNotification,
        object: document)
      followsEnd = true
      scrollToEnd()
    }

    private var endOrigin: NSPoint? {
      guard let clip = registeredScrollView?.contentView, let document = clip.documentView
      else { return nil }
      var end = clip.bounds
      end.origin.y = document.frame.maxY
      return clip.constrainBoundsRect(end).origin
    }

    @objc private func readerScrolled() {
      guard let clip = registeredScrollView?.contentView, let end = endOrigin else { return }
      followsEnd = end.y - clip.bounds.origin.y <= 24
    }

    @objc private func contentResized() {
      if followsEnd { scrollToEnd() }
    }

    private func scrollToEnd() {
      guard let scrollView = registeredScrollView, let end = endOrigin else { return }
      scrollView.contentView.scroll(to: end)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scheduleRegistrationRefresh() {
      DispatchQueue.main.async { [weak self] in
        self?.refreshRegistration()
      }
    }
  }
}
