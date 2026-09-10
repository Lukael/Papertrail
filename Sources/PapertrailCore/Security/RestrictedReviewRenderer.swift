import Foundation
#if canImport(AppKit) && canImport(WebKit)
import AppKit
import WebKit

public struct RestrictedRenderResult: Codable, Equatable, Sendable {
  public let status: String
  public let loadedURL: String
  public let allowedReadDirectory: String
  public let javaScriptEnabled: Bool
  public let scriptMessageHandlerCount: Int
  public let unexpectedRequestCount: Int
  public let screenshotPath: String?
  public let note: String
}

@MainActor
public final class RestrictedReviewRenderer: NSObject, WKNavigationDelegate {
  private var navigationPolicy: ReviewNavigationPolicy?
  private var unexpectedNavigations = 0
  private var loadError: Error?

  public override init() {}

  public func render(indexURL: URL, screenshotURL: URL, timeout: TimeInterval = 15) async throws
    -> RestrictedRenderResult
  {
    let reviewDirectory = indexURL.deletingLastPathComponent().standardizedFileURL
    navigationPolicy = ReviewNavigationPolicy(reviewDirectory: reviewDirectory)
    let configuration = try await ReviewContentPolicy().makeConfiguration(
      ruleListIdentifier: "ReviewContentPolicy-\(UUID().uuidString)")
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 850), configuration: configuration)
    webView.navigationDelegate = self
    let loaded = webView.loadFileURL(indexURL, allowingReadAccessTo: reviewDirectory)
    guard loaded != nil else { throw RestrictedRenderError.loadRejected }
    let deadline = Date().addingTimeInterval(timeout)
    while webView.isLoading && Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    if let loadError { throw loadError }
    guard !webView.isLoading else { throw RestrictedRenderError.timedOut }
    let snapshot = try await webView.takeSnapshot(configuration: nil)
    guard let tiff = snapshot.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw RestrictedRenderError.snapshotFailed }
    try png.write(to: screenshotURL, options: .atomic)
    return RestrictedRenderResult(
      status: unexpectedNavigations == 0 ? "passed" : "failed",
      loadedURL: indexURL.path,
      allowedReadDirectory: reviewDirectory.path,
      javaScriptEnabled: false,
      scriptMessageHandlerCount: 0,
      unexpectedRequestCount: unexpectedNavigations,
      screenshotPath: screenshotURL.path,
      note: "Static WebKit render only; this is not independent semantic or visual-quality verification.")
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    loadError = error
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    loadError = error
  }

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url, let navigationPolicy else {
      unexpectedNavigations += 1
      decisionHandler(.cancel)
      return
    }
    guard !navigationAction.shouldPerformDownload else {
      unexpectedNavigations += 1
      decisionHandler(.cancel)
      return
    }
    switch navigationPolicy.decision(
      for: url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
    {
    case .allowCurrentDocumentOrFragment:
      decisionHandler(.allow)
    case .requireExternalConfirmation, .deny:
      unexpectedNavigations += 1
      decisionHandler(.cancel)
    }
  }
}

public enum RestrictedRenderError: Error, Equatable {
  case loadRejected
  case timedOut
  case snapshotFailed
}
#endif
