import Foundation
#if canImport(WebKit)
import WebKit
#endif

public enum ReviewNavigationDecision: Equatable, Sendable {
  case allowCurrentDocumentOrFragment
  case requireExternalConfirmation(URL)
  case deny
}

public struct ExternalLinkConfirmation: Equatable, Sendable {
  public let destination: URL
  public let displayText: String

  public init?(destination: URL) {
    guard destination.scheme?.lowercased() == "https",
      ReviewNavigationPolicy.isApprovedExternal(destination)
    else { return nil }
    self.destination = destination
    self.displayText = destination.absoluteString
  }
}

public struct ReviewNavigationPolicy: Sendable {
  public let reviewDirectory: URL

  public init(reviewDirectory: URL) {
    self.reviewDirectory = reviewDirectory.standardizedFileURL.resolvingSymlinksInPath()
  }

  public func decision(for url: URL, isMainFrame: Bool = true) -> ReviewNavigationDecision {
    if url.isFileURL {
      let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
      let index = reviewDirectory.appendingPathComponent("index.html").standardizedFileURL
        .resolvingSymlinksInPath()
      return resolved.path == index.path ? .allowCurrentDocumentOrFragment : .deny
    }
    if url.scheme == "about", url.absoluteString == "about:blank" {
      return .allowCurrentDocumentOrFragment
    }
    if url.scheme?.lowercased() == "https", isApprovedExternal(url) {
      return isMainFrame ? .requireExternalConfirmation(url) : .deny
    }
    return .deny
  }

  public static func isApprovedExternal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "doi.org" || host == "imec-publications.be"
  }

  private func isApprovedExternal(_ url: URL) -> Bool {
    Self.isApprovedExternal(url)
  }
}

public struct ReviewContentPolicy: Sendable {
  public static let contentRuleJSON =
    """
    [{"trigger":{"url-filter":"https?://.*"},"action":{"type":"block"}},{"trigger":{"url-filter":"wss?://.*"},"action":{"type":"block"}}]
    """

  public init() {}

  #if canImport(WebKit)
  @MainActor
  public func makeBaseConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    let preferences = WKWebpagePreferences()
    preferences.allowsContentJavaScript = false
    configuration.defaultWebpagePreferences = preferences
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return configuration
  }

  @MainActor
  public func makeConfiguration(ruleListIdentifier: String = "ReviewContentPolicy") async throws
    -> WKWebViewConfiguration
  {
    let configuration = makeBaseConfiguration()
    let ruleStoreDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Papertrail-WebKitRules", isDirectory: true)
    try FileManager.default.createDirectory(
      at: ruleStoreDirectory, withIntermediateDirectories: true)
    guard let ruleStore = WKContentRuleListStore(url: ruleStoreDirectory) else {
      throw ReviewContentPolicyError.ruleStoreCreationFailed
    }
    guard let rules = try await ruleStore.compileContentRuleList(
      forIdentifier: ruleListIdentifier,
      encodedContentRuleList: Self.contentRuleJSON)
    else { throw ReviewContentPolicyError.ruleCompilationReturnedNil }
    configuration.userContentController.add(rules)
    // No script-message handlers, user scripts, or privileged bridge are installed.
    return configuration
  }
  #endif
}

public enum ReviewContentPolicyError: Error {
  case ruleStoreCreationFailed
  case ruleCompilationReturnedNil
}
