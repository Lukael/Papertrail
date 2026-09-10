import AppKit
import Foundation
import PDFKit
import PapertrailCore
import WebKit

struct Gate0GHarnessResult: Codable {
  let status: String
  let wideScreenshot: String
  let narrowPaperScreenshot: String
  let narrowReviewScreenshot: String
  let narrowChatScreenshot: String
  let recoveryScreenshot: String
  let hostileScreenshot: String
  let allowedReadDirectory: String
  let javaScriptEnabled: Bool
  let installedUserScriptCount: Int
  let scriptMessageBridgeInspection: String
  let persistentWebsiteDataStore: Bool
  let navigationMetrics: RestrictedReviewNavigationMetrics
  let externalOpenCountBeforeInteraction: Int
  let externalOpenCountAfterDeny: Int
  let externalOpenCountAfterPopupDeny: Int
  let externalOpenCountAfterConfirm: Int
  let confirmationRequestsAfterPopupDeny: Int
  let sameWebViewLocationSwitchPassed: Bool
  let coordinatorInitialReadRoot: String
  let coordinatorSwitchedReadRoot: String
  let coordinatorFinalDocumentMarker: String
  let ruleInstallationFailureObserved: Bool
  let ruleInstallationFailureReason: String
  let ruleInstallationRetryPassed: Bool
  let ruleInstallerAttemptCount: Int
  let captureRequestCount: Int
  let note: String
}

@main @MainActor
enum Gate0GHarness {
  static let paperID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
  static let generationID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
  static let sanitizedVersionID = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
  static let hostileVersionID = UUID(uuidString: "70000000-0000-0000-0000-000000000004")!
  static let switchedVersionID = UUID(uuidString: "70000000-0000-0000-0000-000000000005")!

  static func main() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let args = try Arguments.parse()
    try FileManager.default.createDirectory(at: args.evidenceDirectory, withIntermediateDirectories: true)
    let runtime = try makeRuntimeFixture(args)
    let coordinatorProof = try await verifyCoordinatorTransitions(runtime: runtime)

    let opened = OpenCounter()
    let confirmation = ExternalLinkConfirmationController { opened.open($0) }
    let hostile = try await makeLoadedWebView(
      location: runtime.hostileLocation, size: NSSize(width: 1100, height: 760),
      confirmation: confirmation)
    let threatWindow = makeWindow(content: hostile.webView, size: hostile.webView.frame.size)
    threatWindow.setFrameOrigin(NSPoint(x: 80, y: 80))
    threatWindow.makeKeyAndOrderFront(nil)
    threatWindow.makeFirstResponder(hostile.webView)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(250))
    let before = opened.count

    try await clickElement(id: "external-link", in: hostile.webView)
    try await Task.sleep(for: .milliseconds(250))
    guard confirmation.pendingDestination?.host == "doi.org" else { throw HarnessError.externalClick }
    confirmation.deny()
    let afterDeny = opened.count

    let requestsBeforePopup = hostile.delegate.metrics.externalConfirmationRequestCount
    try await clickElement(id: "popup-link", in: hostile.webView)
    try await Task.sleep(for: .milliseconds(250))
    let afterPopup = opened.count
    let requestsAfterPopup = hostile.delegate.metrics.externalConfirmationRequestCount
    guard confirmation.pendingDestination == nil else { throw HarnessError.popupRequestedConfirmation }

    try await clickElement(id: "download-link", in: hostile.webView)
    try await Task.sleep(for: .milliseconds(250))
    try await clickElement(id: "file-input", in: hostile.webView)
    try await Task.sleep(for: .milliseconds(350))

    try await clickElement(id: "external-link", in: hostile.webView)
    try await Task.sleep(for: .milliseconds(250))
    guard confirmation.pendingDestination != nil else { throw HarnessError.externalClick }
    confirmation.confirm()
    let afterConfirm = opened.count
    let hostileScreenshot = args.evidenceDirectory.appendingPathComponent("hostile-runtime.png")
    try await snapshot(hostile.webView, to: hostileScreenshot)

    let selectedConfirmation = ExternalLinkConfirmationController { _ in }
    let selected = try await makeLoadedWebView(
      location: runtime.sanitizedLocation, size: NSSize(width: 720, height: 790),
      confirmation: selectedConfirmation)
    let reviewImage = try await selected.webView.takeSnapshot(configuration: nil)
    let paperImage = try renderPDFPage(runtime.pdfURL, size: NSSize(width: 700, height: 730))

    let wideURL = args.evidenceDirectory.appendingPathComponent("workspace-wide.png")
    let wide = makeWideWorkspace(pdfImage: paperImage, reviewImage: reviewImage)
    let wideWindow = makeWindow(content: wide, size: wide.frame.size)
    wideWindow.makeKeyAndOrderFront(nil)
    try captureView(wide, to: wideURL)

    let narrowPaperURL = args.evidenceDirectory.appendingPathComponent("workspace-narrow-paper.png")
    let narrowReviewURL = args.evidenceDirectory.appendingPathComponent("workspace-narrow-review.png")
    let narrowChatURL = args.evidenceDirectory.appendingPathComponent("workspace-narrow-chat.png")
    try captureView(makeNarrowWorkspace(section: .paper, contentImage: paperImage), to: narrowPaperURL)
    try captureView(makeNarrowWorkspace(section: .review, contentImage: reviewImage), to: narrowReviewURL)
    try captureView(makeNarrowWorkspace(section: .chat, contentImage: nil), to: narrowChatURL)

    let recoveryURL = args.evidenceDirectory.appendingPathComponent("workspace-recovery.png")
    try captureView(makeRecoveryWorkspace(), to: recoveryURL)

    let metrics = hostile.delegate.metrics
    let result = Gate0GHarnessResult(
      status: "passed",
      wideScreenshot: wideURL.path,
      narrowPaperScreenshot: narrowPaperURL.path,
      narrowReviewScreenshot: narrowReviewURL.path,
      narrowChatScreenshot: narrowChatURL.path,
      recoveryScreenshot: recoveryURL.path,
      hostileScreenshot: hostileScreenshot.path,
      allowedReadDirectory: hostile.delegate.resolvedLocation?.readRoot.path ?? "missing",
      javaScriptEnabled: hostile.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript,
      installedUserScriptCount: hostile.webView.configuration.userContentController.userScripts.count,
      scriptMessageBridgeInspection: "No public runtime handler enumeration API; production source contract is checked for zero addScriptMessageHandler calls.",
      persistentWebsiteDataStore: hostile.webView.configuration.websiteDataStore.isPersistent,
      navigationMetrics: metrics,
      externalOpenCountBeforeInteraction: before,
      externalOpenCountAfterDeny: afterDeny,
      externalOpenCountAfterPopupDeny: afterPopup,
      externalOpenCountAfterConfirm: afterConfirm,
      confirmationRequestsAfterPopupDeny:
        requestsAfterPopup - requestsBeforePopup,
      sameWebViewLocationSwitchPassed: coordinatorProof.locationSwitchPassed,
      coordinatorInitialReadRoot: coordinatorProof.initialReadRoot,
      coordinatorSwitchedReadRoot: coordinatorProof.switchedReadRoot,
      coordinatorFinalDocumentMarker: coordinatorProof.finalMarker,
      ruleInstallationFailureObserved: coordinatorProof.failureObserved,
      ruleInstallationFailureReason: coordinatorProof.failureReason,
      ruleInstallationRetryPassed: coordinatorProof.retryPassed,
      ruleInstallerAttemptCount: coordinatorProof.attemptCount,
      captureRequestCount: args.captureRequestCount,
      note: "Production RestrictedReviewNavigationDelegate and ExternalLinkConfirmationController drove real WKWebView focus-plus-AppKit-keyboard interactions. Host evaluation only focused an element; AppKit Return performed activation. Visual fixtures use a real PDFKit page, restricted selected review, chat, narrow states, disclosure, and recovery actions; no semantic research-quality claim is made.")
    try JSONEncoder.pretty.encode(result).write(to: args.resultURL, options: .atomic)

    guard !result.javaScriptEnabled, result.installedUserScriptCount == 0,
      !result.persistentWebsiteDataStore,
      metrics.deniedNewWindowCount >= 1, metrics.deniedDownloadCount >= 1,
      metrics.deniedFileChooserCount >= 1,
      before == 0, afterDeny == 0, afterPopup == 0, afterConfirm == 1,
      result.confirmationRequestsAfterPopupDeny == 0,
      metrics.externalConfirmationRequestCount == 2,
      result.sameWebViewLocationSwitchPassed,
      result.coordinatorInitialReadRoot != result.coordinatorSwitchedReadRoot,
      result.coordinatorFinalDocumentMarker == "COORDINATOR-B",
      result.ruleInstallationFailureObserved,
      result.ruleInstallationRetryPassed,
      result.ruleInstallerAttemptCount == 2
    else { throw HarnessError.invariant }
    print("PASS Gate0GHarness")
  }

  static func makeRuntimeFixture(_ args: Arguments) throws -> RuntimeFixture {
    let applicationSupport = args.evidenceDirectory.appendingPathComponent("runtime/ApplicationSupport")
    let paths = LibraryPaths(applicationSupport: applicationSupport)
    try paths.createRootTopology()
    let sourceDirectory = paths.sourceDirectory(paperID: paperID)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let pdfURL = sourceDirectory.appendingPathComponent("paper.pdf")
    if FileManager.default.fileExists(atPath: pdfURL.path) { try FileManager.default.removeItem(at: pdfURL) }
    try FileManager.default.copyItem(at: args.pdfURL, to: pdfURL)

    let source = try String(contentsOf: args.hostileHTML, encoding: .utf8)
    let sanitizedRoot = paths.reviewVersion(
      sanitizedVersionID, generationID: generationID, paperID: paperID)
    let hostileRoot = paths.reviewVersion(
      hostileVersionID, generationID: generationID, paperID: paperID)
    let switchedRoot = paths.reviewVersion(
      switchedVersionID, generationID: generationID, paperID: paperID)
    try FileManager.default.createDirectory(at: sanitizedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hostileRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: switchedRoot, withIntermediateDirectories: true)
    let selectedHTML = """
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <style>body{margin:0;background:#f7f8fa;color:#172033;font:16px -apple-system,sans-serif}main{margin:34px;padding:42px 46px;background:white;border-radius:16px}h1{font-size:28px}.eyebrow{color:#3266cc;font-weight:700;text-transform:uppercase;font-size:12px}.finding{border-left:4px solid #3266cc;background:#eef4ff;padding:12px 16px;margin:24px 0}footer{border-top:1px solid #dde2ea;margin-top:28px;padding-top:18px;color:#5d6677;font-size:13px}</style></head>
      <body data-marker="COORDINATOR-A"><main><div class="eyebrow">Generated · structure checked</div><h1>Signals in a Small Synthetic Sensor Array</h1>
      <p>This selected review is generator-produced and remains unverified until a human review is recorded.</p>
      <div class="finding"><strong>Primary finding.</strong> The reported effect is internally consistent, while external validity remains limited by the synthetic sample.</div>
      <h2>Evidence note</h2><blockquote>Signals were recorded from sixteen synthetic sensor channels.</blockquote>
      <footer>Private local review · JavaScript, bridges, and remote resources disabled</footer></main></body></html>
      """
    let sanitized = try ReviewResourceSanitizer().sanitize(selectedHTML)
    try Data(sanitized.html.utf8).write(
      to: sanitizedRoot.appendingPathComponent("index.html"), options: .atomic)
    try JSONEncoder.pretty.encode(sanitized.report).write(
      to: sanitizedRoot.appendingPathComponent("sanitization-report.json"), options: .atomic)
    try Data(source.utf8).write(to: hostileRoot.appendingPathComponent("index.html"), options: .atomic)
    try Data(selectedHTML.replacingOccurrences(of: "COORDINATOR-A", with: "COORDINATOR-B").replacingOccurrences(of: "Signals in a Small Synthetic Sensor Array", with: "Switched Review Version").utf8)
      .write(to: switchedRoot.appendingPathComponent("index.html"), options: .atomic)
    try Data("download fixture".utf8).write(to: hostileRoot.appendingPathComponent("download.bin"))
    let relative: (URL) throws -> String = { try paths.relativePath(for: $0) }
    return RuntimeFixture(
      pdfURL: pdfURL,
      sanitizedLocation: SelectedReviewLocation(
        paths: paths, paperID: paperID, generationID: generationID,
        versionID: sanitizedVersionID, persistedRelativePath: try relative(sanitizedRoot)),
      hostileLocation: SelectedReviewLocation(
        paths: paths, paperID: paperID, generationID: generationID,
        versionID: hostileVersionID, persistedRelativePath: try relative(hostileRoot)),
      switchedLocation: SelectedReviewLocation(
        paths: paths, paperID: paperID, generationID: generationID,
        versionID: switchedVersionID, persistedRelativePath: try relative(switchedRoot)))
  }

  static func verifyCoordinatorTransitions(runtime: RuntimeFixture) async throws -> CoordinatorProof {
    final class AttemptCounter { var value = 0 }
    let attempts = AttemptCounter()
    let installer = RestrictedReviewRuleInstaller(
      storeFactory: RestrictedReviewRuleInstaller.defaultStoreFactory,
      compiler: { store, identifier, rules, completion in
        attempts.value += 1
        if attempts.value == 1 {
          completion(.failure(HarnessError.injectedRuleCompilationFailure))
        } else {
          RestrictedReviewRuleInstaller.defaultCompiler(
            store: store, identifier: identifier, encodedRules: rules,
            completion: completion)
        }
      })
    let configuration = ReviewContentPolicy().makeBaseConfiguration()
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 790), configuration: configuration)
    let state = LoadBox()
    let coordinator = RestrictedReviewWebCoordinator(
      location: runtime.sanitizedLocation, ruleInstaller: installer,
      ruleListIdentifier: "Gate0G-Coordinator-\(UUID().uuidString)",
      onExternalLinkRequested: { _ in }, onLoadStateChanged: { state.state = $0 })
    let window = makeWindow(content: webView, size: webView.frame.size)
    window.orderFrontRegardless()
    coordinator.connect(
      webView: webView, location: runtime.sanitizedLocation, reloadToken: 0,
      onExternalLinkRequested: { _ in }, onLoadStateChanged: { state.state = $0 })
    guard case .failed(let failureReason) = state.state,
      failureReason.contains("rule installation failed"), attempts.value == 1
    else { throw HarnessError.ruleFailureNotObservable }
    coordinator.update(
      location: runtime.sanitizedLocation, reloadToken: 0,
      onExternalLinkRequested: { _ in }, onLoadStateChanged: { state.state = $0 })
    guard attempts.value == 1 else { throw HarnessError.ruleRetriedWithoutAction }
    coordinator.update(
      location: runtime.sanitizedLocation, reloadToken: 1,
      onExternalLinkRequested: { _ in }, onLoadStateChanged: { state.state = $0 })
    try await waitForLoad(state, webView: webView, expectedLocation: runtime.sanitizedLocation)
    let expectedA = try runtime.sanitizedLocation.resolve()
    let markerA = try await webView.evaluateJavaScript("document.body.dataset.marker") as? String
    guard markerA == "COORDINATOR-A", attempts.value == 2 else {
      throw HarnessError.ruleRetryDidNotLoad
    }
    state.state = .loading
    coordinator.update(
      location: runtime.switchedLocation, reloadToken: 1,
      onExternalLinkRequested: { _ in }, onLoadStateChanged: { state.state = $0 })
    try await waitForLoad(state, webView: webView, expectedLocation: runtime.switchedLocation)
    guard let markerB = try await webView.evaluateJavaScript(
      "document.body.dataset.marker") as? String
    else { throw HarnessError.staleReviewLocation }
    let expectedB = try runtime.switchedLocation.resolve()
    guard markerB == "COORDINATOR-B", webView.url == expectedB.indexURL,
      coordinator.navigationDelegate.resolvedLocation == expectedB
    else { throw HarnessError.staleReviewLocation }
    window.close()
    return CoordinatorProof(
      locationSwitchPassed: true, failureObserved: true, retryPassed: true,
      attemptCount: attempts.value, initialReadRoot: expectedA.readRoot.path,
      switchedReadRoot: expectedB.readRoot.path, finalMarker: markerB,
      failureReason: failureReason)
  }

  static func waitForLoad(
    _ state: LoadBox, webView: WKWebView, expectedLocation: SelectedReviewLocation
  ) async throws {
    let expected = try expectedLocation.resolve()
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if case .loaded = state.state, webView.url == expected.indexURL { return }
      if case .failed(let reason) = state.state { throw HarnessError.load(reason) }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw HarnessError.timeout
  }

  static func makeLoadedWebView(
    location: SelectedReviewLocation, size: NSSize,
    confirmation: ExternalLinkConfirmationController
  ) async throws -> (webView: WKWebView, delegate: RestrictedReviewNavigationDelegate) {
    let configuration = try await ReviewContentPolicy().makeConfiguration(
      ruleListIdentifier: "Gate0G-\(UUID().uuidString)")
    let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
    let loadBox = LoadBox()
    let delegate = RestrictedReviewNavigationDelegate(
      location: location,
      onExternalLinkRequested: { confirmation.request($0) },
      onLoadStateChanged: { loadBox.state = $0 })
    webView.navigationDelegate = delegate
    webView.uiDelegate = delegate
    delegate.load(in: webView)
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if case .loaded = loadBox.state { return (webView, delegate) }
      if case .failed(let reason) = loadBox.state { throw HarnessError.load(reason) }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw HarnessError.timeout
  }

  static func clickElement(id: String, in webView: WKWebView) async throws {
    guard webView.window?.firstResponder != nil else { throw HarnessError.element(id) }
    // Host-side evaluation only moves focus; it does not click or navigate. Return is
    // delivered by AppKit and therefore exercises WebKit's user-link activation path.
    _ = try await webView.evaluateJavaScript(
      "document.getElementById('\(id)').focus(); document.activeElement.id")
    try await Task.sleep(for: .milliseconds(40))
    try postKey(36, characters: "\r", in: webView) // Return performs a real keyboard activation.
  }

  static func postKey(_ code: UInt16, characters: String, in webView: WKWebView) throws {
    guard let window = webView.window,
      let down = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code),
      let up = NSEvent.keyEvent(
        with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    else { throw HarnessError.element("keyboard") }
    window.sendEvent(down)
    window.sendEvent(up)
  }

  static func makeWideWorkspace(pdfImage: NSImage, reviewImage: NSImage) -> NSView {
    let root = baseRoot(size: NSSize(width: 1800, height: 1000))
    header(in: root, width: 1800, title: "Signals in a Small Synthetic Sensor Array")
    disclosure(in: root, frame: NSRect(x: 18, y: 884, width: 1764, height: 54))
    let pdfPane = pane(frame: NSRect(x: 18, y: 22, width: 520, height: 850), title: "Paper · page 1")
    let pdfView = NSImageView(frame: NSRect(x: 12, y: 12, width: 496, height: 790))
    pdfView.image = pdfImage; pdfView.imageScaling = .scaleProportionallyUpOrDown
    pdfPane.addSubview(pdfView); root.addSubview(pdfPane)
    let reviewPane = pane(frame: NSRect(x: 550, y: 22, width: 820, height: 850), title: "Selected review · Generated · structure checked")
    let reviewView = NSImageView(frame: NSRect(x: 12, y: 12, width: 796, height: 790))
    reviewView.image = reviewImage; reviewView.imageScaling = .scaleProportionallyUpOrDown
    reviewPane.addSubview(reviewView); root.addSubview(reviewPane)
    root.addSubview(chatPane(frame: NSRect(x: 1382, y: 22, width: 400, height: 850)))
    return root
  }

  enum NarrowSection: String { case paper = "Paper", review = "Review", chat = "Chat" }
  static func makeNarrowWorkspace(section: NarrowSection, contentImage: NSImage?) -> NSView {
    let root = baseRoot(size: NSSize(width: 760, height: 920))
    header(in: root, width: 760, title: "Paper workspace")
    let selector = NSSegmentedControl(labels: ["Paper", "Review", "Chat"], trackingMode: .selectOne, target: nil, action: nil)
    selector.frame = NSRect(x: 130, y: 820, width: 500, height: 34)
    selector.selectedSegment = [NarrowSection.paper: 0, .review: 1, .chat: 2][section]!
    root.addSubview(selector)
    disclosure(in: root, frame: NSRect(x: 28, y: 744, width: 704, height: 62))
    label("\(section.rawValue) view · Cmd-1/2/3", in: root, frame: NSRect(x: 30, y: 706, width: 400, height: 24), size: 15, color: .labelColor, weight: .semibold)
    if section == .chat {
      root.addSubview(chatPane(frame: NSRect(x: 28, y: 26, width: 704, height: 668)))
    } else if let contentImage {
      let imageView = NSImageView(frame: NSRect(x: 28, y: 26, width: 704, height: 668))
      imageView.image = contentImage; imageView.imageScaling = .scaleProportionallyUpOrDown
      root.addSubview(imageView)
    }
    return root
  }

  static func makeRecoveryWorkspace() -> NSView {
    let root = baseRoot(size: NSSize(width: 760, height: 920))
    header(in: root, width: 760, title: "Recovery states")
    let selector = NSSegmentedControl(labels: ["Paper", "Review", "Chat"], trackingMode: .selectOne, target: nil, action: nil)
    selector.frame = NSRect(x: 130, y: 820, width: 500, height: 34); selector.selectedSegment = 1; root.addSubview(selector)
    disclosure(in: root, frame: NSRect(x: 28, y: 744, width: 704, height: 62))
    recoveryCard(in: root, y: 574, icon: "doc.badge.ellipsis", title: "Stored PDF unavailable", detail: "The record, prior review, and chat remain preserved.", action: "Locate recovery folder")
    recoveryCard(in: root, y: 394, icon: "checkmark.shield", title: "Restricted review path validation failed", detail: "The immutable review was not granted file read access.", action: "Retry secure load")
    recoveryCard(in: root, y: 214, icon: "bubble.left.and.exclamationmark.bubble.right", title: "Chat operation interrupted", detail: "The committed message and operation record remain recoverable.", action: "Retry message")
    return root
  }

  static func recoveryCard(in root: NSView, y: CGFloat, icon: String, title: String, detail: String, action: String) {
    let card = NSView(frame: NSRect(x: 42, y: y, width: 676, height: 146)); card.wantsLayer = true
    card.layer?.cornerRadius = 14; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    label(title, in: card, frame: NSRect(x: 22, y: 98, width: 620, height: 24), size: 17, color: .labelColor, weight: .semibold)
    label(detail, in: card, frame: NSRect(x: 22, y: 65, width: 620, height: 22), size: 13, color: .secondaryLabelColor)
    let button = NSButton(title: action, target: nil, action: nil); button.frame = NSRect(x: 20, y: 18, width: 190, height: 34); card.addSubview(button)
    root.addSubview(card)
  }

  static func baseRoot(size: NSSize) -> NSView {
    let root = NSView(frame: NSRect(origin: .zero, size: size)); root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; return root
  }

  static func header(in root: NSView, width: CGFloat, title: String) {
    label(title, in: root, frame: NSRect(x: 22, y: root.bounds.height - 48, width: width - 44, height: 28), size: 20, color: .labelColor, weight: .semibold)
  }

  static func disclosure(in root: NSView, frame: NSRect) {
    let banner = NSView(frame: frame); banner.wantsLayer = true; banner.layer?.cornerRadius = 10
    banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
    label("Web review · local files only · JavaScript/bridges/network off", in: banner, frame: NSRect(x: 16, y: 31, width: frame.width - 32, height: 18), size: 12, color: .labelColor, weight: .semibold)
    label("Codex child process · workspace writes · accepted residual reads, network, and process spawning", in: banner, frame: NSRect(x: 16, y: 9, width: frame.width - 32, height: 18), size: 12, color: .systemOrange, weight: .semibold)
    root.addSubview(banner)
  }

  static func pane(frame: NSRect, title: String) -> NSView {
    let view = NSView(frame: frame); view.wantsLayer = true; view.layer?.cornerRadius = 14
    view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    label(title, in: view, frame: NSRect(x: 14, y: frame.height - 36, width: frame.width - 28, height: 22), size: 14, color: .labelColor, weight: .semibold)
    return view
  }

  static func chatPane(frame: NSRect) -> NSView {
    let view = pane(frame: frame, title: "Paper-scoped chat")
    message("You", "What is the main limitation?", y: frame.height - 160, in: view, accent: true)
    message("Codex", "The synthetic sample supports internal checks, but does not establish external validity.", y: frame.height - 300, in: view, accent: false)
    let retry = NSButton(title: "Retry interrupted message", target: nil, action: nil); retry.frame = NSRect(x: 18, y: 68, width: 210, height: 34); view.addSubview(retry)
    label("Messages and lineage are stored locally.", in: view, frame: NSRect(x: 18, y: 34, width: frame.width - 36, height: 20), size: 12, color: .secondaryLabelColor)
    return view
  }

  static func message(_ role: String, _ text: String, y: CGFloat, in parent: NSView, accent: Bool) {
    let box = NSView(frame: NSRect(x: 16, y: y, width: parent.bounds.width - 32, height: 112)); box.wantsLayer = true
    box.layer?.cornerRadius = 12; box.layer?.backgroundColor = (accent ? NSColor.systemBlue.withAlphaComponent(0.13) : NSColor.quaternaryLabelColor).cgColor
    parent.addSubview(box); label(role, in: box, frame: NSRect(x: 12, y: 80, width: box.bounds.width - 24, height: 18), size: 11, color: .secondaryLabelColor, weight: .semibold)
    label(text, in: box, frame: NSRect(x: 12, y: 16, width: box.bounds.width - 24, height: 58), size: 13, color: .labelColor, wraps: true)
  }

  static func renderPDFPage(_ url: URL, size: NSSize) throws -> NSImage {
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
      throw HarnessError.pdf
    }
    let image = NSImage(size: size)
    image.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    let bounds = page.bounds(for: .mediaBox)
    let scale = min(size.width / bounds.width, size.height / bounds.height)
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState(); context.translateBy(x: (size.width - bounds.width * scale) / 2, y: 0); context.scaleBy(x: scale, y: scale); page.draw(with: .mediaBox, to: context); context.restoreGState()
    image.unlockFocus(); return image
  }

  static func makeWindow(content: NSView, size: NSSize) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = content; return window
  }

  static func captureView(_ view: NSView, to url: URL) throws {
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HarnessError.snapshot }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw HarnessError.snapshot }
    try png.write(to: url, options: .atomic)
  }

  static func snapshot(_ webView: WKWebView, to url: URL) async throws {
    let image = try await webView.takeSnapshot(configuration: nil)
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw HarnessError.snapshot }
    try png.write(to: url, options: .atomic)
  }

  @discardableResult static func label(_ text: String, in parent: NSView, frame: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, wraps: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text); field.frame = frame; field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.maximumNumberOfLines = wraps ? 3 : 1; field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail; parent.addSubview(field); return field
  }
}

struct RuntimeFixture {
  let pdfURL: URL
  let sanitizedLocation: SelectedReviewLocation
  let hostileLocation: SelectedReviewLocation
  let switchedLocation: SelectedReviewLocation
}
struct CoordinatorProof {
  let locationSwitchPassed: Bool
  let failureObserved: Bool
  let retryPassed: Bool
  let attemptCount: Int
  let initialReadRoot: String
  let switchedReadRoot: String
  let finalMarker: String
  let failureReason: String
}
@MainActor final class LoadBox { var state: RestrictedReviewLoadState = .loading }
final class OpenCounter { private(set) var count = 0; func open(_ url: URL) { count += 1 } }

struct Arguments {
  let hostileHTML: URL, pdfURL: URL, evidenceDirectory: URL, resultURL: URL
  let captureRequestCount: Int
  static func parse() throws -> Self {
    let values = CommandLine.arguments
    func value(_ flag: String) throws -> String {
      guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else { throw HarnessError.arguments }
      return values[index + 1]
    }
    return .init(
      hostileHTML: URL(fileURLWithPath: try value("--hostile-html")),
      pdfURL: URL(fileURLWithPath: try value("--pdf")),
      evidenceDirectory: URL(fileURLWithPath: try value("--evidence-directory")),
      resultURL: URL(fileURLWithPath: try value("--result")),
      captureRequestCount: Int(try value("--capture-request-count")) ?? -1)
  }
}

enum HarnessError: Error {
  case arguments, timeout, snapshot, pdf, invariant, externalClick, popupRequestedConfirmation
  case element(String), load(String), injectedRuleCompilationFailure, ruleFailureNotObservable
  case ruleRetriedWithoutAction, ruleRetryDidNotLoad, staleReviewLocation
}
extension JSONEncoder { static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder } }
