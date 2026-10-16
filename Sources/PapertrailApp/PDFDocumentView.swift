import PDFKit
import SwiftUI
import CoreImage

/// Shows a 0-based PDF page and, when `text` is found on it, selects that text.
/// Each request has a fresh `id`, so repeating a click repeats the jump.
struct PDFFocusRequest: Equatable {
  let id = UUID()
  let pageIndex: Int
  var text: String?
}

/// Text to highlight on a 0-based PDF page, such as a verified review excerpt.
struct PDFTextAnchor: Equatable {
  let pageIndex: Int
  let text: String

  /// UTF-16 range of `text` in `pageText` for `PDFPage.selection(for:)`. Matches the review
  /// validator: whitespace runs, ligatures, soft hyphens, and hyphens between letters (PDF
  /// line-end breaks such as "fol-\nlowed") are ignored.
  static func range(of text: String, in pageText: String) -> NSRange? {
    let needle = normalized(text).characters
    guard let first = needle.first else { return nil }
    let (haystack, spans) = normalized(pageText)
    guard needle.count <= haystack.count else { return nil }
    for start in 0...(haystack.count - needle.count)
    where haystack[start] == first && haystack[start...].starts(with: needle) {
      let end = spans[start + needle.count - 1]
      return NSRange(
        location: spans[start].location, length: NSMaxRange(end) - spans[start].location)
    }
    return nil
  }

  /// Normalized characters, each with the UTF-16 span of the source text it came from.
  private static func normalized(_ text: String) -> (characters: [Character], spans: [NSRange]) {
    var characters: [Character] = []
    var spans: [NSRange] = []
    var pendingSpace = false
    var offset = 0
    for character in text {
      let length = character.utf16.count
      defer { offset += length }
      if character == "\u{00AD}" { continue }
      if character.isWhitespace {
        pendingSpace = !characters.isEmpty
        continue
      }
      if pendingSpace {
        characters.append(" ")
        spans.append(NSRange(location: offset, length: 0))
        pendingSpace = false
      }
      for expanded in String(character).precomposedStringWithCompatibilityMapping {
        characters.append(expanded)
        spans.append(NSRange(location: offset, length: length))
      }
    }
    var kept: [Character] = []
    var keptSpans: [NSRange] = []
    var index = 0
    while index < characters.count {
      if "-\u{2010}\u{2011}".contains(characters[index]), kept.last?.isLetter == true {
        var next = index + 1
        if next < characters.count, characters[next] == " " { next += 1 }
        if next < characters.count, characters[next].isLetter {
          index = next
          continue
        }
      }
      kept.append(characters[index])
      keptSpans.append(spans[index])
      index += 1
    }
    return (kept, keptSpans)
  }
}

enum PDFSelectionAction: Int, CaseIterable {
  case explain, translate, ask, highlight, highlightWithNote

  var title: String {
    switch self {
    case .explain: "Explain Selection"
    case .translate: "Translate Selection"
    case .ask: "Ask About Selection"
    case .highlight: "Highlight"
    case .highlightWithNote: "Highlight with Note…"
    }
  }
}

/// The passage a selection action applies to. `rects` are its lines in page space.
struct PDFSelectedPassage: Equatable {
  let text: String
  let pageNumber: Int
  let rects: [CGRect]
}

/// A saved highlight drawn on a 0-based page; `note` shows as its tooltip.
struct PDFUserHighlight: Equatable {
  let id: UUID
  let pageIndex: Int
  let rects: [CGRect]
  let note: String
}

enum PDFHighlightAction: Int {
  case editNote, remove
}

struct PDFDocumentView: View {
  let url: URL
  let pageIndex: Int
  let scale: Double
  var isDarkMode = false
  let onReadingStateChanged: (Int, Double) -> Void
  var focus: PDFFocusRequest?
  var highlights: [PDFTextAnchor] = []
  var userHighlights: [PDFUserHighlight] = []
  var onSelectionAction: ((PDFSelectionAction, PDFSelectedPassage) -> Void)?
  /// Receives an action chosen on an existing highlight, by its id.
  var onHighlightAction: ((PDFHighlightAction, UUID) -> Void)?

  @State private var isSearchVisible = false
  @State private var searchQuery = ""
  @State private var submittedSearchQuery = ""
  @State private var searchIndex = 0
  @State private var searchResultCount = 0
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      PDFViewRepresentable(
        url: url, pageIndex: pageIndex, scale: scale, isDarkMode: isDarkMode,
        searchQuery: submittedSearchQuery, searchIndex: searchIndex,
        focus: focus, highlights: highlights, userHighlights: userHighlights,
        onSearchResultCountChanged: { searchResultCount = $0 },
        onReadingStateChanged: onReadingStateChanged,
        onSelectionAction: onSelectionAction, onHighlightAction: onHighlightAction
      )
      .accessibilityLabel("Stored source PDF")

      if isSearchVisible {
        HStack(spacing: 6) {
          TextField("Search", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 80, idealWidth: 180, maxWidth: 220)
            .focused($isSearchFocused)
            .onSubmit {
              if searchQuery == submittedSearchQuery {
                moveSearch(by: 1)
              } else {
                searchIndex = 0
                searchResultCount = 0
                submittedSearchQuery = searchQuery
              }
            }

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
    submittedSearchQuery = ""
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
  let focus: PDFFocusRequest?
  let highlights: [PDFTextAnchor]
  let userHighlights: [PDFUserHighlight]
  let onSearchResultCountChanged: (Int) -> Void
  let onReadingStateChanged: (Int, Double) -> Void
  let onSelectionAction: ((PDFSelectionAction, PDFSelectedPassage) -> Void)?
  let onHighlightAction: ((PDFHighlightAction, UUID) -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onSearchResultCountChanged: onSearchResultCountChanged,
      onChange: onReadingStateChanged)
  }

  func makeNSView(context: Context) -> AppearancePDFView {
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
    context.coordinator.applyHighlights(highlights, to: view)
    context.coordinator.applyUserHighlights(userHighlights, to: view)
    context.coordinator.applyFocus(focus, to: view)
    view.onSelectionAction = onSelectionAction
    view.onHighlightAction = onHighlightAction
    return view
  }

  func updateNSView(_ view: AppearancePDFView, context: Context) {
    context.coordinator.onChange = onReadingStateChanged
    context.coordinator.onSearchResultCountChanged = onSearchResultCountChanged
    context.coordinator.apply(url: url, pageIndex: pageIndex, scale: scale, to: view)
    context.coordinator.applyAppearance(isDarkMode: isDarkMode, to: view)
    context.coordinator.applySearch(query: searchQuery, index: searchIndex, to: view)
    context.coordinator.applyHighlights(highlights, to: view)
    context.coordinator.applyUserHighlights(userHighlights, to: view)
    context.coordinator.applyFocus(focus, to: view)
    view.onSelectionAction = onSelectionAction
    view.onHighlightAction = onHighlightAction
  }

  static func dismantleNSView(_ view: AppearancePDFView, coordinator: Coordinator) {
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
    private var scrollMonitor: Any?
    private var appliedFocusID: UUID?
    private var appliedHighlights: [PDFTextAnchor] = []
    private weak var highlightedDocument: PDFDocument?
    private var highlightAnnotations: [PDFAnnotation] = []
    private var appliedUserHighlights: [PDFUserHighlight] = []
    private weak var userHighlightedDocument: PDFDocument?
    private var userAnnotations: [PDFAnnotation] = []

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
      // PDFKit's nested scroll view consumes wheel events before PDFView sees them.
      scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        guard let self, let view = self.observedView,
          let window = view.window, event.window === window,
          let content = window.contentView
        else { return event }
        return self.routeScroll(
          event, hitView: content.hitTest(content.convert(event.locationInWindow, from: nil)))
      }
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
      if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
      scrollMonitor = nil
      observedView = nil
      NotificationCenter.default.removeObserver(self)
    }

    func routeScroll(_ event: NSEvent, hitView: NSView?) -> NSEvent? {
      guard event.modifierFlags.contains(.control),
        let view = observedView, let hitView, hitView.isDescendant(of: view)
      else { return event }
      let sensitivity = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
      let scale = view.scaleFactor * exp(event.scrollingDeltaY * sensitivity)
      view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
      return nil
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

    func applyFocus(_ request: PDFFocusRequest?, to view: PDFView) {
      guard let request, request.id != appliedFocusID else { return }
      appliedFocusID = request.id
      // Navigate after this view update: the page change records reading state,
      // and a just-created view needs a layout pass before it can scroll.
      DispatchQueue.main.async { [weak view] in
        guard let view, let document = view.document,
          (0..<document.pageCount).contains(request.pageIndex),
          let page = document.page(at: request.pageIndex)
        else { return }
        if let text = request.text,
          let range = PDFTextAnchor.range(of: text, in: page.string ?? ""),
          let selection = page.selection(for: range)
        {
          view.setCurrentSelection(selection, animate: true)
          view.go(to: selection)
        } else {
          view.go(to: page)
        }
      }
    }

    /// Draws in-memory highlight annotations; the stored PDF file is never written.
    func applyHighlights(_ anchors: [PDFTextAnchor], to view: PDFView) {
      guard anchors != appliedHighlights || view.document !== highlightedDocument else { return }
      for annotation in highlightAnnotations { annotation.page?.removeAnnotation(annotation) }
      highlightAnnotations = []
      appliedHighlights = anchors
      highlightedDocument = view.document
      guard let document = view.document else { return }
      for anchor in anchors {
        guard (0..<document.pageCount).contains(anchor.pageIndex),
          let page = document.page(at: anchor.pageIndex),
          let range = PDFTextAnchor.range(of: anchor.text, in: page.string ?? ""),
          let selection = page.selection(for: range)
        else { continue }
        for line in selection.selectionsByLine() {
          let annotation = PDFAnnotation(
            bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
          annotation.color = NSColor.systemTeal.withAlphaComponent(0.22)
          annotation.isReadOnly = true
          page.addAnnotation(annotation)
          highlightAnnotations.append(annotation)
        }
      }
    }

    /// Saved highlights, kept apart from evidence highlights so each set updates on its own.
    func applyUserHighlights(_ highlights: [PDFUserHighlight], to view: PDFView) {
      guard highlights != appliedUserHighlights || view.document !== userHighlightedDocument
      else { return }
      for annotation in userAnnotations { annotation.page?.removeAnnotation(annotation) }
      userAnnotations = []
      appliedUserHighlights = highlights
      userHighlightedDocument = view.document
      guard let document = view.document else { return }
      for highlight in highlights {
        guard (0..<document.pageCount).contains(highlight.pageIndex),
          let page = document.page(at: highlight.pageIndex)
        else { continue }
        for rect in highlight.rects {
          let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
          annotation.color = NSColor.systemYellow.withAlphaComponent(0.4)
          annotation.userName = AppearancePDFView.highlightPrefix + highlight.id.uuidString
          annotation.isReadOnly = true
          if !highlight.note.isEmpty { annotation.contents = highlight.note }
          page.addAnnotation(annotation)
          userAnnotations.append(annotation)
        }
      }
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

    isolated deinit {
      if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
      NotificationCenter.default.removeObserver(self)
    }
  }
}


/// Blends above live PDFKit tiles instead of caching them through a content filter.
final class AppearancePDFView: PDFView {
  private let tint = PDFTintView()
  static let highlightPrefix = "papertrail-highlight:"
  var onSelectionAction: ((PDFSelectionAction, PDFSelectedPassage) -> Void)?
  var onHighlightAction: ((PDFHighlightAction, UUID) -> Void)?

  override func menu(for event: NSEvent) -> NSMenu? {
    // Capture before super: building PDFKit's menu can clear the selection.
    let passage = selectedPassage()
    let highlight = onHighlightAction == nil ? nil : highlightID(at: event)
    guard passage != nil || highlight != nil else { return super.menu(for: event) }
    // Over a saved highlight PDFKit adds its own markup items (colors, Remove Highlight, Remove
    // Note) that would change the page without updating the saved notes, so leave them out.
    let menu = highlight == nil ? (super.menu(for: event) ?? NSMenu()) : NSMenu()
    var index = 0
    if let highlight {
      for (title, action) in [("Edit Note…", PDFHighlightAction.editNote), ("Remove Highlight", .remove)] {
        let item = NSMenuItem(
          title: title, action: #selector(performHighlightAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        item.representedObject = highlight
        menu.insertItem(item, at: index)
        index += 1
      }
    }
    if let passage {
      for action in PDFSelectionAction.allCases {
        let item = NSMenuItem(
          title: action.title, action: #selector(performSelectionAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        item.representedObject = passage
        menu.insertItem(item, at: index)
        index += 1
      }
    }
    menu.insertItem(.separator(), at: index)
    return menu
  }

  /// The selected text with its first page; a selection spanning pages highlights that page only.
  private func selectedPassage() -> PDFSelectedPassage? {
    guard onSelectionAction != nil, let document, let selection = currentSelection,
      let text = selection.string, text.contains(where: { !$0.isWhitespace }),
      let page = selection.pages.first
    else { return nil }
    let rects = selection.selectionsByLine()
      .filter { $0.pages.first === page }
      .map { $0.bounds(for: page) }
    return PDFSelectedPassage(text: text, pageNumber: document.index(for: page) + 1, rects: rects)
  }

  func highlightID(at event: NSEvent) -> UUID? {
    let point = convert(event.locationInWindow, from: nil)
    guard let page = page(for: point, nearest: false) else { return nil }
    let pagePoint = convert(point, to: page)
    return page.annotations.lazy.compactMap { annotation -> UUID? in
      guard annotation.bounds.contains(pagePoint), let name = annotation.userName,
        name.hasPrefix(Self.highlightPrefix)
      else { return nil }
      return UUID(uuidString: String(name.dropFirst(Self.highlightPrefix.count)))
    }.first
  }

  @objc private func performSelectionAction(_ sender: NSMenuItem) {
    guard let action = PDFSelectionAction(rawValue: sender.tag),
      let passage = sender.representedObject as? PDFSelectedPassage
    else { return }
    onSelectionAction?(action, passage)
  }

  @objc private func performHighlightAction(_ sender: NSMenuItem) {
    guard let action = PDFHighlightAction(rawValue: sender.tag),
      let id = sender.representedObject as? UUID
    else { return }
    onHighlightAction?(action, id)
  }

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
