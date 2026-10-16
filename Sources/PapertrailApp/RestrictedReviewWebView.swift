import AppKit
import PapertrailCore
import SwiftUI
import WebKit

struct RestrictedReviewWebView: NSViewRepresentable {
  typealias ReviewLoadState = RestrictedReviewLoadState

  let location: SelectedReviewLocation
  let reloadToken: Int
  let onExternalLinkRequested: (URL) -> Void
  let onLoadStateChanged: (ReviewLoadState) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      location: location,
      onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = ReviewContentPolicy().makeBaseConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    context.coordinator.webCoordinator.connect(
      webView: webView, location: location, reloadToken: reloadToken,
      onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
    connectEvidenceLinks(context)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.webCoordinator.update(
      location: location, reloadToken: reloadToken,
      onExternalLinkRequested: onExternalLinkRequested,
      onLoadStateChanged: onLoadStateChanged)
    connectEvidenceLinks(context)
  }

  /// Evidence links still scroll the review; the workspace also focuses the PDF.
  private func connectEvidenceLinks(_ context: Context) {
    let openURL = context.environment.openURL
    context.coordinator.webCoordinator.navigationDelegate.onEvidenceActivated = { id in
      openURL(PaperSourceLink.evidence(id).url)
    }
  }

  @MainActor
  final class Coordinator {
    let webCoordinator: RestrictedReviewWebCoordinator

    init(
      location: SelectedReviewLocation,
      onExternalLinkRequested: @escaping (URL) -> Void,
      onLoadStateChanged: @escaping (ReviewLoadState) -> Void
    ) {
      webCoordinator = RestrictedReviewWebCoordinator(
        location: location,
        onExternalLinkRequested: onExternalLinkRequested,
        onLoadStateChanged: onLoadStateChanged)
    }
  }
}
