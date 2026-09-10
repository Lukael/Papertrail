import PDFKit
import SwiftUI

struct PDFDocumentView: View {
  let url: URL
  let pageIndex: Int
  let scale: Double
  let onReadingStateChanged: (Int, Double) -> Void

  var body: some View {
    PDFViewRepresentable(
      url: url, pageIndex: pageIndex, scale: scale,
      onReadingStateChanged: onReadingStateChanged
    )
    .accessibilityLabel("Stored source PDF")
  }
}

private struct PDFViewRepresentable: NSViewRepresentable {
  let url: URL
  let pageIndex: Int
  let scale: Double
  let onReadingStateChanged: (Int, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onChange: onReadingStateChanged) }

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.autoScales = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 16
    context.coordinator.attach(to: view)
    context.coordinator.apply(url: url, pageIndex: pageIndex, scale: scale, to: view)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    context.coordinator.onChange = onReadingStateChanged
    context.coordinator.apply(url: url, pageIndex: pageIndex, scale: scale, to: view)
  }

  @MainActor
  final class Coordinator: NSObject {
    var onChange: (Int, Double) -> Void
    private weak var observedView: PDFView?
    private var loadedURL: URL?
    private var applyingState = false

    init(onChange: @escaping (Int, Double) -> Void) { self.onChange = onChange }

    func attach(to view: PDFView) {
      observedView = view
      NotificationCenter.default.addObserver(
        self, selector: #selector(readingStateDidChange(_:)),
        name: .PDFViewPageChanged, object: view)
      NotificationCenter.default.addObserver(
        self, selector: #selector(readingStateDidChange(_:)),
        name: .PDFViewScaleChanged, object: view)
    }

    func apply(url: URL, pageIndex: Int, scale: Double, to view: PDFView) {
      applyingState = true
      defer { applyingState = false }
      if loadedURL != url {
        view.document = PDFDocument(url: url)
        loadedURL = url
      }
      if let document = view.document, document.pageCount > 0 {
        let boundedPage = min(max(0, pageIndex), document.pageCount - 1)
        if let page = document.page(at: boundedPage), view.currentPage !== page {
          view.go(to: page)
        }
      }
      if scale.isFinite, scale > 0, abs(view.scaleFactor - scale) > 0.001 {
        view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
      }
    }

    @objc private func readingStateDidChange(_ notification: Notification) {
      record(notification.object as? PDFView ?? observedView)
    }

    private func record(_ view: PDFView?) {
      guard !applyingState, let view, let document = view.document, let page = view.currentPage
      else {
        return
      }
      onChange(document.index(for: page), view.scaleFactor)
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }
}
