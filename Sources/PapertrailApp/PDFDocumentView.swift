import PDFKit
import SwiftUI
import CoreImage

struct PDFDocumentView: View {
  let url: URL
  let pageIndex: Int
  let scale: Double
  var isDarkMode = false
  let onReadingStateChanged: (Int, Double) -> Void

  @State private var isSearchVisible = false
  @State private var searchQuery = ""
  @State private var searchIndex = 0
  @State private var searchResultCount = 0
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      PDFViewRepresentable(
        url: url, pageIndex: pageIndex, scale: scale, isDarkMode: isDarkMode,
        searchQuery: searchQuery, searchIndex: searchIndex,
        onSearchResultCountChanged: { searchResultCount = $0 },
        onReadingStateChanged: onReadingStateChanged
      )
      .accessibilityLabel("Stored source PDF")

      if isSearchVisible {
        HStack(spacing: 6) {
          TextField("Search", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 80, idealWidth: 180, maxWidth: 220)
            .focused($isSearchFocused)
            .onSubmit { moveSearch(by: 1) }

          Text(searchResultCount == 0 ? "0 of 0" : "\(searchIndex + 1) of \(searchResultCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 52)

          Button("Previous result", systemImage: "chevron.up") { moveSearch(by: -1) }
            .labelStyle(.iconOnly)
            .disabled(searchResultCount == 0)
          Button("Next result", systemImage: "chevron.down") { moveSearch(by: 1) }
            .labelStyle(.iconOnly)
            .disabled(searchResultCount == 0)
          Button("Close search", systemImage: "xmark") { closeSearch() }
            .labelStyle(.iconOnly)
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
          RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12))
        }
        .padding(12)
      }

      Button(action: openSearch) { Color.clear.frame(width: 1, height: 1) }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityHidden(true)
    }
    .onChange(of: searchQuery) { _, _ in searchIndex = 0 }
    .onChange(of: url) { _, _ in closeSearch() }
    .accessibilityElement(children: .contain)
  }

  private func openSearch() {
    isSearchVisible = true
    Task { @MainActor in isSearchFocused = true }
  }

  private func closeSearch() {
    isSearchVisible = false
    isSearchFocused = false
    searchQuery = ""
    searchIndex = 0
    searchResultCount = 0
  }

  private func moveSearch(by offset: Int) {
    guard searchResultCount > 0 else { return }
    searchIndex = (searchIndex + offset + searchResultCount) % searchResultCount
  }
}

private struct PDFViewRepresentable: NSViewRepresentable {
  let url: URL
  let pageIndex: Int
  let scale: Double
  let isDarkMode: Bool
  let searchQuery: String
  let searchIndex: Int
  let onSearchResultCountChanged: (Int) -> Void
  let onReadingStateChanged: (Int, Double) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onSearchResultCountChanged: onSearchResultCountChanged,
      onChange: onReadingStateChanged)
  }

  func makeNSView(context: Context) -> PDFView {
    let view = AppearancePDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.pageShadowsEnabled = false
    view.autoScales = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 16
    context.coordinator.attach(to: view)
    context.coordinator.apply(url: url, pageIndex: pageIndex, scale: scale, to: view)
    context.coordinator.applyAppearance(isDarkMode: isDarkMode, to: view)
    context.coordinator.applySearch(query: searchQuery, index: searchIndex, to: view)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    context.coordinator.onChange = onReadingStateChanged
    context.coordinator.onSearchResultCountChanged = onSearchResultCountChanged
    context.coordinator.apply(url: url, pageIndex: pageIndex, scale: scale, to: view)
    context.coordinator.applyAppearance(isDarkMode: isDarkMode, to: view)
    context.coordinator.applySearch(query: searchQuery, index: searchIndex, to: view)
  }

  static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject {
    var onChange: (Int, Double) -> Void
    var onSearchResultCountChanged: (Int) -> Void
    private weak var observedView: PDFView?
    private var loadedURL: URL?
    private var applyingState = false
    private var appliedDarkMode: Bool?
    private var originalBackgroundColor: NSColor?
    private var searchedDocument: PDFDocument?
    private var searchedQuery = ""
    private var searchResults: [PDFSelection] = []
    private var selectedSearchIndex = -1
    private var searchGeneration = 0

    init(
      onSearchResultCountChanged: @escaping (Int) -> Void,
      onChange: @escaping (Int, Double) -> Void
    ) {
      self.onSearchResultCountChanged = onSearchResultCountChanged
      self.onChange = onChange
    }

    func applyAppearance(isDarkMode: Bool, to view: PDFView) {
      guard appliedDarkMode != isDarkMode else { return }
      appliedDarkMode = isDarkMode
      view.wantsLayer = true
      if originalBackgroundColor == nil { originalBackgroundColor = view.backgroundColor }
      view.backgroundColor = isDarkMode ? .white : (originalBackgroundColor ?? .windowBackgroundColor)
      (view as? AppearancePDFView)?.setDarkMode(isDarkMode)
    }

    func attach(to view: PDFView) {
      observedView = view
      NotificationCenter.default.addObserver(
        self, selector: #selector(readingStateDidChange(_:)),
        name: .PDFViewPageChanged, object: view)
      NotificationCenter.default.addObserver(
        self, selector: #selector(readingStateDidChange(_:)),
        name: .PDFViewScaleChanged, object: view)
      NotificationCenter.default.addObserver(
        self, selector: #selector(searchDidFindMatch(_:)),
        name: .PDFDocumentDidFindMatch, object: nil)
    }

    func detach() {
      searchGeneration += 1
      searchedDocument?.cancelFindString()
      NotificationCenter.default.removeObserver(self)
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

    func applySearch(query: String, index: Int, to view: PDFView) {
      if searchedDocument !== view.document || searchedQuery != query {
        searchedDocument?.cancelFindString()
        searchGeneration += 1
        searchedDocument = view.document
        searchedQuery = query
        searchResults = []
        selectedSearchIndex = -1
        view.highlightedSelections = nil
        view.currentSelection = nil
        publishResultCount(0, generation: searchGeneration)
        if !query.isEmpty {
          view.document?.beginFindString(query, withOptions: .caseInsensitive)
        }
      }

      guard !query.isEmpty else { return }
      for selection in searchResults {
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
      }
      view.highlightedSelections = searchResults.isEmpty ? nil : searchResults

      guard !searchResults.isEmpty else {
        view.currentSelection = nil
        return
      }
      let boundedIndex = min(max(index, 0), searchResults.count - 1)
      let shouldNavigate = selectedSearchIndex != boundedIndex
      selectedSearchIndex = boundedIndex
      let selection = searchResults[boundedIndex]
      selection.color = NSColor.systemOrange.withAlphaComponent(0.7)
      view.currentSelection = selection
      if shouldNavigate { view.go(to: selection) }
    }

    @objc private func searchDidFindMatch(_ notification: Notification) {
      guard
        !searchedQuery.isEmpty,
        notification.object as? PDFDocument === searchedDocument,
        let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
        selection.string?.range(of: searchedQuery, options: .caseInsensitive) != nil,
        let view = observedView
      else { return }
      selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
      searchResults.append(selection)
      view.highlightedSelections = searchResults
      if searchResults.count == 1 {
        selectedSearchIndex = 0
        selection.color = NSColor.systemOrange.withAlphaComponent(0.7)
        view.currentSelection = selection
        view.go(to: selection)
      }
      let count = searchResults.count
      publishResultCount(count, generation: searchGeneration)
    }

    private func publishResultCount(_ count: Int, generation: Int) {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.searchGeneration == generation else { return }
        self.onSearchResultCountChanged(count)
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


/// Blends above live PDFKit tiles instead of caching them through a content filter.
private final class AppearancePDFView: PDFView {
  private let tint = PDFTintView()

  override func layout() {
    super.layout()
    tint.needsDisplay = true
  }

  func setDarkMode(_ enabled: Bool) {
    if tint.superview == nil {
      tint.wantsLayer = true
      tint.pdfView = self
      tint.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
      tint.alphaValue = 1
      tint.autoresizingMask = [.width, .height]
      tint.frame = bounds
      addSubview(tint, positioned: .above, relativeTo: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(scrollBoundsChanged(_:)),
        name: NSView.boundsDidChangeNotification, object: nil)
    }
    tint.isHidden = !enabled
    tint.needsDisplay = true
  }

  @objc private func scrollBoundsChanged(_ notification: Notification) {
    guard let clip = notification.object as? NSClipView, clip.isDescendant(of: self) else { return }
    tint.needsDisplay = true
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

private final class PDFTintView: NSView {
  weak var pdfView: PDFView?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    // A partially visible page can extend behind the toolbar; clip its outline.
    NSBezierPath(rect: bounds).addClip()
    NSColor.white.setFill()
    bounds.fill()
    guard let pdfView else { return }
    // Black in the difference overlay preserves the white page edge below it.
    NSColor.black.setFill()
    let thickness = 1 / (window?.backingScaleFactor ?? 1)
    for page in pdfView.visiblePages {
      let pageRect = convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
      let outline = NSBezierPath(rect: pageRect.insetBy(dx: thickness / 2, dy: thickness / 2))
      outline.lineWidth = thickness
      NSColor.black.setStroke()
      outline.stroke()
    }
  }
}
