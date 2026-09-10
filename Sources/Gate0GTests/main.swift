import Foundation
import PapertrailCore
#if canImport(WebKit)
import AppKit
import WebKit
#endif

struct Gate0GFailure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Gate0GFailure(description: message) }
}

@main @MainActor
enum Gate0GTests {
  static func main() async throws {
    #if canImport(AppKit)
    _ = NSApplication.shared
    #endif
    let tests: [(String, () async throws -> Void)] = [
      ("navigation is confined to the selected review root", testNavigationBoundary),
      ("selected review resolution is exact and canonical", testSelectedReviewLocation),
      ("selected review rejects symlink and root replacement", testSelectedReviewSymlinks),
      ("approved publication links require confirmation", testExternalConfirmation),
      ("remote and active content channels are blocked", testContentRules),
      ("WebKit configuration is ephemeral and JavaScript-free", testWebKitConfiguration),
      ("hostile generated content is rejected or stripped", testHostileSanitization),
      ("app WebKit bridge denies popup chooser download and navigation", testAppWebKitSource),
      ("shared coordinator reloads location and exposes rule failures", testCoordinatorSource),
      ("external browser opening follows visible confirmation", testConfirmationSource),
      ("integrated workspace exposes truthful quality and recovery states", testWorkspaceStates),
      ("global activity log replaces review-local live activity", testActivityLogSurface),
      ("chat questions use a trailing translucent navigation rail", testQuestionRailSurface),
      ("chat composer omits redundant context and lifecycle prose", testChatComposerCopy),
      ("workspace is keyboard and accessibility navigable", testAccessibility),
      ("storage disclosure and scope exclusions remain visible", testDisclosureAndScope),
    ]
    var passed = 0
    for (name, test) in tests {
      do { try await test(); passed += 1; print("PASS \(name)") }
      catch { print("FAIL \(name): \(error)"); exit(1) }
    }
    print("PASS Gate0GTests \(passed)/\(tests.count)")
  }

  static func testNavigationBoundary() async throws {
    let root = URL(fileURLWithPath: "/tmp/review-version")
    let policy = ReviewNavigationPolicy(reviewDirectory: root)
    try expect(policy.decision(for: root.appendingPathComponent("index.html")) == .allowCurrentDocumentOrFragment, "index denied")
    try expect(
      policy.decision(for: root.appendingPathComponent("assets/legacy.png")) == .deny,
      "legacy review asset was allowed")
    try expect(policy.decision(for: root.deletingLastPathComponent().appendingPathComponent("sibling/index.html")) == .deny, "sibling allowed")
    try expect(policy.decision(for: URL(fileURLWithPath: "/etc/passwd")) == .deny, "outside file allowed")
    try expect(policy.decision(for: URL(string: "data:text/html,evil")!) == .deny, "data navigation allowed")
  }

  static func testExternalConfirmation() async throws {
    let policy = ReviewNavigationPolicy(reviewDirectory: URL(fileURLWithPath: "/tmp/review"))
    let doi = URL(string: "https://doi.org/10.1000/test")!
    try expect(policy.decision(for: doi) == .requireExternalConfirmation(doi), "DOI was not gated")
    try expect(ExternalLinkConfirmation(destination: doi)?.displayText == doi.absoluteString, "confirmation omitted exact destination")
    try expect(ExternalLinkConfirmation(destination: URL(string: "http://doi.org/10.1000/test")!) == nil, "HTTP link approved")
    try expect(policy.decision(for: URL(string: "https://evil.example/exfil")!) == .deny, "arbitrary HTTPS approved")
    try expect(policy.decision(for: doi, isMainFrame: false) == .deny, "subframe publication load approved")
  }

  static func testContentRules() async throws {
    let rules = ReviewContentPolicy.contentRuleJSON
    for scheme in ["https?://.*", "wss?://.*"] { try expect(rules.contains(scheme), "missing rule \(scheme)") }
    let csp = ReviewResourceSanitizer.contentSecurityPolicy
    for directive in ["default-src 'none'", "connect-src 'none'", "frame-src 'none'", "form-action 'none'", "object-src 'none'"] {
      try expect(csp.contains(directive), "missing CSP \(directive)")
    }
  }

  static func testWebKitConfiguration() async throws {
    #if canImport(WebKit)
    let configuration = ReviewContentPolicy().makeBaseConfiguration()
    try expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false, "JavaScript enabled")
    try expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false, "window JavaScript enabled")
    try expect(configuration.websiteDataStore.isPersistent == false, "persistent website data enabled")
    try expect(configuration.userContentController.userScripts.isEmpty, "user scripts installed")
    #endif
  }

  static func testHostileSanitization() async throws {
    let url = URL(fileURLWithPath: "Fixtures/Gate0G/hostile-integrated-review.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let result = try ReviewResourceSanitizer().sanitize(html)
    for forbidden in ["<script", "<iframe", "<form", "<object", "onload=", "127.0.0.1:8765"] {
      try expect(!result.html.lowercased().contains(forbidden.lowercased()), "hostile channel survived: \(forbidden)")
    }
    try expect(result.html.contains("Content-Security-Policy"), "CSP absent after sanitization")
    try expect(!result.html.lowercased().contains("<img"), "broken remote image placeholder survived")
    try expect(result.report.removedConstructs.contains("tag:img"), "removed image was not reported")
    try expect(!result.report.removedConstructs.isEmpty, "sanitizer did not report removals")

    let legacyImages = try ReviewResourceSanitizer().sanitize(
      #"<html><body background="assets/legacy.png"><img src="assets/legacy.png"><image src="data:image/png;base64,AA=="></image></body></html>"#)
    try expect(
      !legacyImages.html.lowercased().contains("<img")
        && !legacyImages.html.lowercased().contains("<image")
        && !legacyImages.html.lowercased().contains("background="),
      "legacy image element or background attribute survived")
    try expect(legacyImages.report.removedConstructs.contains("tag:img"), "image removal was not reported")
    try expect(legacyImages.report.removedConstructs.contains("tag:image"), "image element removal was not reported")
  }

  static func testAppWebKitSource() async throws {
    let source = try appSource("RestrictedReviewWebView.swift")
    let delegate = try coreSource("Security/RestrictedReviewNavigationDelegate.swift")
    for contract in [
      "RestrictedReviewWebCoordinator", "webCoordinator.connect(",
      "webCoordinator.update(",
    ] { try expect(source.contains(contract), "app does not use shared WebKit contract: \(contract)") }
    for contract in [
      "loadFileURL(", "allowingReadAccessTo: resolved.readRoot",
      "action.navigationType == .linkActivated", "action.shouldPerformDownload",
      "guard action.targetFrame != nil else", "decisionHandler(.cancel)",
      "createWebViewWith", "runOpenPanelWith", "completionHandler(nil)",
    ] { try expect(delegate.contains(contract), "missing shared WebKit contract: \(contract)") }
    let nilFrame = try expectRange("guard action.targetFrame != nil else", in: delegate)
    let confirmation = try expectRange("metrics.externalConfirmationRequestCount += 1", in: delegate)
    try expect(nilFrame.lowerBound < confirmation.lowerBound, "new-window denial occurs after confirmation callback")
    try expect(!source.contains("addScriptMessageHandler") && !delegate.contains("addScriptMessageHandler"), "privileged bridge installed")
    try expect(!source.contains("WKDownloadDelegate") && !delegate.contains("WKDownloadDelegate"), "download delegate exposed")
  }

  static func testCoordinatorSource() async throws {
    let source = try coreSource("Security/RestrictedReviewWebCoordinator.swift")
    for contract in [
      "fingerprint != requestedFingerprint || reloadToken != requestedReloadToken",
      "location.identity()", "navigationDelegate.load(in: webView)",
      "Restricted WebKit rule installation failed:", "onLoadStateChanged(.failed(",
      "installationInFlight = false", "rulesInstalled = false",
    ] { try expect(source.contains(contract), "missing coordinator contract: \(contract)") }
    let app = try appSource("RestrictedReviewWebView.swift")
    try expect(!app.contains("compileContentRuleList"), "app bypasses shared fallible rule installer")
    let workspace = try appSource("PaperWorkspaceViews.swift")
    try expect(workspace.contains("Button(\"Retry secure load\") { reloadToken += 1 }"), "rule failure has no retry action")
  }

  static func testConfirmationSource() async throws {
    let source = try appSource("PaperWorkspaceViews.swift")
    let request = source.range(of: "Open external publication link?")
    let controller = source.range(of: "ExternalLinkConfirmationController { NSWorkspace.shared.open($0) }")
    try expect(request != nil && controller != nil, "confirmation controller is not connected to browser opener")
    try expect(source.contains("destination.absoluteString"), "visible destination missing")
  }

  static func testWorkspaceStates() async throws {
    let source = try appSource("PaperWorkspaceViews.swift")
    for state in ["The immutable review was preserved", "prior review or chat remain preserved"] {
      try expect(source.contains(state), "missing recovery state: \(state)")
    }
    for removed in ["Generated · structure checked", "generator-produced and unverified", "Process:", "Structure:", "Evidence:", "Human/visual:"] {
      try expect(!source.contains(removed), "review status text remains visible: \(removed)")
    }
  }

  static func testActivityLogSurface() async throws {
    let workspace = try appSource("PaperWorkspaceViews.swift")
    let log = try appSource("AppActivityLog.swift")
    let review = try appSource("ReviewGenerationController.swift")
    try expect(
      !workspace.contains("ReviewLiveActivityView")
        && !workspace.contains("Live Codex activity"),
      "Review panel still renders local live Codex activity")
    for contract in [
      "ActivityLogBar(log: controller.activityLog)", "Show log history",
      "ActivityLogHistoryView", "App + Codex", "maximumEntryCount = 500",
      "App and Codex activity log",
    ] {
      try expect(
        workspace.contains(contract) || log.contains(contract),
        "global activity log lacks \(contract)")
    }
    for contract in ["activityLog.upsert", "source: .codex", "appendLiveProgress"] {
      try expect(review.contains(contract), "Codex progress is not routed to global log: \(contract)")
    }
  }

  static func testQuestionRailSurface() async throws {
    let source = try appSource("PaperWorkspaceViews.swift")
    for contract in [
      "ChatQuestionRail", "ChatQuestionRailMarker", "Previous question", "Next question",
      "ZStack(alignment: .trailing)", ".padding(.trailing, 10)", ".padding(.trailing, 52)",
      ".ultraThinMaterial",
      ".frame(width: 36, height: 14)", ".contentShape(Rectangle())", ".zIndex(2)",
      ".onHover { isHovered = $0 }", ".lineLimit(1)", ".truncationMode(.tail)",
      "ChatQuestionOffsetPreferenceKey", ".coordinateSpace(name: \"paper-chat-scroll\")",
      "isActiveQuestion: message.id == activeQuestionID", "bookmark.fill",
      "proxy.scrollTo(questionID, anchor: anchor)",
    ] {
      try expect(source.contains(contract), "question index lacks \(contract)")
    }
    try expect(
      source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
      "question navigation ignores reduced motion")
    try expect(!source.contains("ChatQuestionIndexBar"), "horizontal question index remains")
    try expect(!source.contains("Question index"), "question index label or menu remains")
  }

  static func testChatComposerCopy() async throws {
    let source = try appSource("PaperWorkspaceViews.swift")
    try expect(!source.contains("Paper context included"), "chat composer repeats paper context")
    try expect(!source.contains("if let status = controller.status"), "chat composer renders Codex lifecycle status")
    try expect(
      source.contains("HStack(alignment: .bottom, spacing: 10)")
        && source.contains(".lineLimit(1...6)"),
      "empty chat composer is not a single-row field that grows with multiline input")
  }

  static func testAccessibility() async throws {
    let source = try appSource("PaperWorkspaceViews.swift")
    for contract in ["accessibilityLabel(\"Restricted local review reader\")", "accessibilityLabel(accessibilityIdentity)", "Question navigation, question", "HSplitView", "accessibilityLabel(\"Resizable paper and chat workspace\")", "accessibilityLabel(\"Resizable paper and review panes\")"] {
      try expect(source.contains(contract), "missing accessibility/adaptive contract: \(contract)")
    }
    try expect(source.contains("Toggle(isOn: paperVisibility)") && source.contains("Toggle(isOn: reviewVisibility)"), "left source controls are not independent toggles")
    try expect(source.contains("if requested || showsReview") && source.contains("if requested || showsPaper"), "source toggles permit an empty workspace")
    try expect(source.contains("if showsPaper && showsReview"), "Paper and Review cannot be shown together")
    try expect(source.contains("chatView\n        .frame(minWidth: 340, idealWidth: 440)"), "Chat is not persistently visible beside the source pane")
    try expect(!source.contains("Workspace section") && !source.contains("workspaceSection"), "Workspace section label or selection state remains")
  }

  static func testDisclosureAndScope() async throws {
    let workspace = try appSource("PaperWorkspaceViews.swift")
    try expect(workspace.contains("Private local storage"), "storage disclosure missing")
    try expect(workspace.contains("Nothing is auto-deleted"), "retention disclosure missing")
    for contract in [
      "Button(\"App information\", systemImage: \"info.circle\")",
      "Show storage and security information", "Local-only WebView",
      "accepted residual read, network, and process-spawning authority",
      ".frame(minWidth: 170, alignment: .leading)",
      ".fixedSize(horizontal: true, vertical: false)",
      "Codex model \\(controller.codexModel.title), reasoning effort \\(controller.codexEffort.title)",
    ] {
      try expect(workspace.contains(contract), "toolbar information disclosure lacks \(contract)")
    }
    guard let headerStart = workspace.range(of: "private var workspaceHeader"),
      let headerEnd = workspace.range(
        of: "private var paperVisibility", range: headerStart.upperBound..<workspace.endIndex)
    else { throw Gate0GFailure(description: "workspace header could not be inspected") }
    let header = String(workspace[headerStart.lowerBound..<headerEnd.lowerBound])
    for removed in ["Private local storage", "Web review:", "Codex child:", "Button(\"Storage\""] {
      try expect(!header.contains(removed), "workspace header still exposes \(removed)")
    }
    let allAppSources = try FileManager.default.contentsOfDirectory(atPath: "Sources/PapertrailApp")
      .filter { $0.hasSuffix(".swift") }.map { try appSource($0) }.joined(separator: "\n")
    for excluded in ["API key", "OpenAI API", "CloudKit", "Sign in", "ShareLink"] {
      try expect(!allAppSources.localizedCaseInsensitiveContains(excluded), "excluded surface present: \(excluded)")
    }
  }

  static func appSource(_ name: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailApp/\(name)"), encoding: .utf8)
  }

  static func coreSource(_ name: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: "Sources/PapertrailCore/\(name)"), encoding: .utf8)
  }

  static func expectRange(_ needle: String, in source: String) throws -> Range<String.Index> {
    guard let range = source.range(of: needle) else { throw Gate0GFailure(description: "missing source contract: \(needle)") }
    return range
  }

  static func testSelectedReviewLocation() async throws {
    let fixture = try ReviewFixture.make(label: "exact")
    defer { fixture.cleanup() }
    let resolved = try fixture.location.resolve()
    try expect(resolved.readRoot == fixture.reviewRoot.standardizedFileURL, "read root was broadened")
    try expect(resolved.indexURL == fixture.reviewRoot.appendingPathComponent("index.html").standardizedFileURL, "index mismatch")
    let mismatched = SelectedReviewLocation(
      paths: fixture.paths, paperID: fixture.paperID, generationID: fixture.generationID,
      versionID: fixture.versionID, persistedRelativePath: "Papers/another/review")
    do {
      _ = try mismatched.resolve()
      throw Gate0GFailure(description: "persisted path mismatch was accepted")
    } catch SelectedReviewLocationError.persistedPathMismatch {}
  }

  static func testSelectedReviewSymlinks() async throws {
    for component in ReviewFixture.symlinkComponents.indices {
      let fixture = try ReviewFixture.make(label: "symlink-\(component)")
      defer { fixture.cleanup() }
      _ = try fixture.location.resolve()
      try fixture.replaceWithSymlink(at: ReviewFixture.symlinkComponents[component])
      do {
        _ = try fixture.location.resolve()
        throw Gate0GFailure(description: "symlink component \(component) was accepted")
      } catch let failure as Gate0GFailure { throw failure }
      catch {}
    }
  }
}

struct ReviewFixture {
  static let symlinkComponents = ["root", "papers", "paper", "generations", "generation", "review", "version", "index"]
  let base: URL
  let paths: LibraryPaths
  let paperID: UUID
  let generationID: UUID
  let versionID: UUID
  let reviewRoot: URL
  let location: SelectedReviewLocation

  static func make(label: String) throws -> ReviewFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Gate0G-\(label)-\(UUID().uuidString)", isDirectory: true)
    let paths = LibraryPaths(applicationSupport: base)
    let paperID = UUID(), generationID = UUID(), versionID = UUID()
    try paths.createRootTopology()
    let reviewRoot = paths.reviewVersion(versionID, generationID: generationID, paperID: paperID)
    try FileManager.default.createDirectory(at: reviewRoot, withIntermediateDirectories: true)
    try Data("<!doctype html><title>safe</title>".utf8).write(to: reviewRoot.appendingPathComponent("index.html"))
    let relative = try paths.relativePath(for: reviewRoot)
    return ReviewFixture(
      base: base, paths: paths, paperID: paperID, generationID: generationID,
      versionID: versionID, reviewRoot: reviewRoot,
      location: SelectedReviewLocation(
        paths: paths, paperID: paperID, generationID: generationID,
        versionID: versionID, persistedRelativePath: relative))
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }

  func replaceWithSymlink(at component: String) throws {
    let targets: [String: URL] = [
      "root": paths.root,
      "papers": paths.papersDirectory,
      "paper": paths.paper(paperID),
      "generations": paths.paper(paperID).appendingPathComponent("generations"),
      "generation": paths.generation(generationID, paperID: paperID),
      "review": paths.generation(generationID, paperID: paperID).appendingPathComponent("review"),
      "version": reviewRoot,
      "index": reviewRoot.appendingPathComponent("index.html"),
    ]
    guard let original = targets[component] else { throw Gate0GFailure(description: "unknown symlink fixture") }
    let moved = base.appendingPathComponent("moved-\(component)-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
  }
}
