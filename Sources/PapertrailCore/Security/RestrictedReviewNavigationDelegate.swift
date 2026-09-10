import Combine
import Foundation
#if canImport(WebKit)
import WebKit

public enum RestrictedReviewLoadState: Equatable, Sendable {
  case loading
  case loaded
  case failed(String)
}

public struct RestrictedReviewNavigationMetrics: Codable, Equatable, Sendable {
  public var deniedNavigationCount = 0
  public var deniedNewWindowCount = 0
  public var deniedDownloadCount = 0
  public var deniedFileChooserCount = 0
  public var externalConfirmationRequestCount = 0
}

@MainActor
public final class ExternalLinkConfirmationController: ObservableObject {
  @Published public private(set) var pendingDestination: URL?
  public private(set) var openInvocationCount = 0
  private let opener: (URL) -> Void

  public init(opener: @escaping (URL) -> Void) { self.opener = opener }

  public func request(_ destination: URL) {
    guard ExternalLinkConfirmation(destination: destination) != nil else { return }
    pendingDestination = destination
  }

  public func deny() { pendingDestination = nil }

  public func confirm() {
    guard let destination = pendingDestination else { return }
    pendingDestination = nil
    openInvocationCount += 1
    opener(destination)
  }
}

@MainActor
public final class RestrictedReviewNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
  public private(set) var metrics = RestrictedReviewNavigationMetrics()
  public private(set) var resolvedLocation: ResolvedReviewLocation?
  private var location: SelectedReviewLocation
  private var policy: ReviewNavigationPolicy?
  private var onExternalLinkRequested: (URL) -> Void
  private var onLoadStateChanged: (RestrictedReviewLoadState) -> Void

  public init(
    location: SelectedReviewLocation,
    onExternalLinkRequested: @escaping (URL) -> Void,
    onLoadStateChanged: @escaping (RestrictedReviewLoadState) -> Void
  ) {
    self.location = location
    self.onExternalLinkRequested = onExternalLinkRequested
    self.onLoadStateChanged = onLoadStateChanged
  }

  public func update(
    location: SelectedReviewLocation,
    onExternalLinkRequested: @escaping (URL) -> Void,
    onLoadStateChanged: @escaping (RestrictedReviewLoadState) -> Void
  ) {
    self.location = location
    self.onExternalLinkRequested = onExternalLinkRequested
    self.onLoadStateChanged = onLoadStateChanged
  }

  public func load(in webView: WKWebView) {
    do {
      let resolved = try location.resolve()
      resolvedLocation = resolved
      policy = ReviewNavigationPolicy(reviewDirectory: resolved.readRoot)
      onLoadStateChanged(.loading)
      _ = webView.loadFileURL(
        resolved.indexURL, allowingReadAccessTo: resolved.readRoot)
    } catch {
      resolvedLocation = nil
      policy = nil
      onLoadStateChanged(.failed("Restricted review path validation failed: \(error)"))
    }
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    onLoadStateChanged(.loaded)
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) { onLoadStateChanged(.failed(error.localizedDescription)) }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { onLoadStateChanged(.failed(error.localizedDescription)) }

  public func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else { denyNavigation(decisionHandler); return }
    if action.shouldPerformDownload {
      metrics.deniedDownloadCount += 1
      if action.targetFrame == nil { metrics.deniedNewWindowCount += 1 }
      denyNavigation(decisionHandler)
      return
    }
    guard action.targetFrame != nil else {
      metrics.deniedNewWindowCount += 1
      denyNavigation(decisionHandler)
      return
    }
    guard let policy, (try? location.resolve())?.readRoot == resolvedLocation?.readRoot else {
      denyNavigation(decisionHandler)
      return
    }
    switch policy.decision(for: url, isMainFrame: action.targetFrame?.isMainFrame == true) {
    case .allowCurrentDocumentOrFragment:
      decisionHandler(.allow)
    case .requireExternalConfirmation(let destination):
      guard action.targetFrame?.isMainFrame == true, action.navigationType == .linkActivated else {
        denyNavigation(decisionHandler); return
      }
      metrics.externalConfirmationRequestCount += 1
      onExternalLinkRequested(destination)
      decisionHandler(.cancel)
    case .deny:
      denyNavigation(decisionHandler)
    }
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    guard response.canShowMIMEType, let url = response.response.url, let policy,
      policy.decision(for: url) == .allowCurrentDocumentOrFragment
    else {
      metrics.deniedDownloadCount += 1
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  public func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    metrics.deniedNewWindowCount += 1
    return nil
  }

  public func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
  ) {
    metrics.deniedFileChooserCount += 1
    completionHandler(nil)
  }

  private func denyNavigation(
    _ decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    metrics.deniedNavigationCount += 1
    decisionHandler(.cancel)
  }
}
#endif
