import Foundation
#if canImport(WebKit)
import WebKit

public enum RestrictedReviewRuleInstallationError: Error, LocalizedError {
  case storeUnavailable
  case compilationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .storeUnavailable: "The nonpersistent WebKit rule store could not be created."
    case .compilationFailed(let reason): "The WebKit restriction rules could not be compiled: \(reason)"
    }
  }
}

@MainActor
public final class RestrictedReviewRuleInstaller {
  public typealias StoreFactory = @MainActor () -> WKContentRuleListStore?
  public typealias Compiler = @MainActor (
    WKContentRuleListStore, String, String,
    @escaping @MainActor (Result<WKContentRuleList, Error>) -> Void
  ) -> Void

  private let storeFactory: StoreFactory
  private let compiler: Compiler

  public init(
    storeFactory: @escaping StoreFactory = RestrictedReviewRuleInstaller.defaultStoreFactory,
    compiler: @escaping Compiler = RestrictedReviewRuleInstaller.defaultCompiler
  ) {
    self.storeFactory = storeFactory
    self.compiler = compiler
  }

  public func install(
    identifier: String, encodedRules: String, in webView: WKWebView,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    guard let store = storeFactory() else {
      completion(.failure(RestrictedReviewRuleInstallationError.storeUnavailable))
      return
    }
    compiler(store, identifier, encodedRules) { result in
      switch result {
      case .success(let rules):
        webView.configuration.userContentController.add(rules)
        completion(.success(()))
      case .failure(let error):
        completion(.failure(
          RestrictedReviewRuleInstallationError.compilationFailed(error.localizedDescription)))
      }
    }
  }

  public static func defaultStoreFactory() -> WKContentRuleListStore? {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Papertrail-WebKitRules", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return WKContentRuleListStore(url: directory)
    } catch {
      return nil
    }
  }

  public static func defaultCompiler(
    store: WKContentRuleListStore, identifier: String, encodedRules: String,
    completion: @escaping @MainActor (Result<WKContentRuleList, Error>) -> Void
  ) {
    store.compileContentRuleList(
      forIdentifier: identifier, encodedContentRuleList: encodedRules
    ) { rules, error in
      Task { @MainActor in
        if let rules { completion(.success(rules)) }
        else {
          completion(.failure(error ?? RestrictedReviewRuleInstallationError.compilationFailed(
            "WebKit returned neither rules nor an error.")))
        }
      }
    }
  }
}

@MainActor
public final class RestrictedReviewWebCoordinator {
  public let navigationDelegate: RestrictedReviewNavigationDelegate

  private enum LocationFingerprint: Equatable {
    case resolved(SelectedReviewSelectionKey, SelectedReviewLocationIdentity)
    case unresolved(SelectedReviewSelectionKey)
  }

  private let ruleInstaller: RestrictedReviewRuleInstaller
  private let ruleListIdentifier: String
  private var rulesInstalled = false
  private var installationInFlight = false
  private var requestedFingerprint: LocationFingerprint?
  private var requestedReloadToken: Int?
  private var onLoadStateChanged: (RestrictedReviewLoadState) -> Void
  private weak var webView: WKWebView?

  public init(
    location: SelectedReviewLocation,
    ruleInstaller: RestrictedReviewRuleInstaller = RestrictedReviewRuleInstaller(),
    ruleListIdentifier: String = "Papertrail-RestrictedReview",
    onExternalLinkRequested: @escaping (URL) -> Void,
    onLoadStateChanged: @escaping (RestrictedReviewLoadState) -> Void
  ) {
    self.ruleInstaller = ruleInstaller
    self.ruleListIdentifier = ruleListIdentifier
    self.onLoadStateChanged = onLoadStateChanged
    navigationDelegate = RestrictedReviewNavigationDelegate(
      location: location, onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
  }

  public func connect(
    webView: WKWebView, location: SelectedReviewLocation, reloadToken: Int,
    onExternalLinkRequested: @escaping (URL) -> Void,
    onLoadStateChanged: @escaping (RestrictedReviewLoadState) -> Void
  ) {
    self.webView = webView
    webView.navigationDelegate = navigationDelegate
    webView.uiDelegate = navigationDelegate
    update(
      location: location, reloadToken: reloadToken,
      onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
  }

  public func update(
    location: SelectedReviewLocation, reloadToken: Int,
    onExternalLinkRequested: @escaping (URL) -> Void,
    onLoadStateChanged: @escaping (RestrictedReviewLoadState) -> Void
  ) {
    self.onLoadStateChanged = onLoadStateChanged
    navigationDelegate.update(
      location: location, onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
    let fingerprint = Self.fingerprint(for: location)
    let requiresReload = fingerprint != requestedFingerprint || reloadToken != requestedReloadToken
    guard requiresReload else { return }
    requestedFingerprint = fingerprint
    requestedReloadToken = reloadToken
    guard let webView else { return }
    if rulesInstalled {
      navigationDelegate.load(in: webView)
    } else if !installationInFlight {
      installRules(in: webView)
    }
  }

  private func installRules(in webView: WKWebView) {
    installationInFlight = true
    onLoadStateChanged(.loading)
    ruleInstaller.install(
      identifier: ruleListIdentifier,
      encodedRules: ReviewContentPolicy.contentRuleJSON,
      in: webView
    ) { [weak self, weak webView] result in
      guard let self else { return }
      self.installationInFlight = false
      switch result {
      case .success:
        self.rulesInstalled = true
        guard let webView else {
          self.onLoadStateChanged(.failed("Restricted review WebView became unavailable."))
          return
        }
        self.navigationDelegate.load(in: webView)
      case .failure(let error):
        self.rulesInstalled = false
        self.onLoadStateChanged(.failed(
          "Restricted WebKit rule installation failed: \(error.localizedDescription)"))
      }
    }
  }

  private static func fingerprint(for location: SelectedReviewLocation) -> LocationFingerprint {
    if let identity = try? location.identity() {
      return .resolved(location.selectionKey, identity)
    }
    return .unresolved(location.selectionKey)
  }
}
#endif
