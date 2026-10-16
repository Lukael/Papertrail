import AppKit
import CoreText
import PDFKit
import SwiftUI

@main
@MainActor
struct PDFSearchTests {
  static func main() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("papertrail-pdf-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstURL = directory.appendingPathComponent("first.pdf")
    let secondURL = directory.appendingPathComponent("second.pdf")
    try makePDF(pages: ["Alpha first page", "alpha second page"], at: firstURL)
    try makePDF(pages: ["Beta replacement document"], at: secondURL)

    if CommandLine.arguments.contains("--interactive") {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      window.title = "Papertrail PDF Search"
      window.contentView = NSHostingView(rootView: PDFDocumentView(
        url: firstURL, pageIndex: 0, scale: 1, onReadingStateChanged: { _, _ in }))
      window.center()
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      app.run()
      return
    }

    var counts: [Int] = []
    var recordedScale = 0.0
    let coordinator = PDFViewRepresentable.Coordinator(
      onSearchResultCountChanged: { counts.append($0) },
      onChange: { _, scale in
        recordedScale = scale
      })
    let view = PDFView()
    coordinator.attach(to: view)
    defer { coordinator.detach() }
    coordinator.apply(url: firstURL, pageIndex: 0, scale: 1, to: view)
    coordinator.applySearch(query: "ALPHA", index: 0, to: view)
    try waitUntil { counts.last == 2 }
    try expect(view.highlightedSelections?.count == 2, "case-insensitive matches were not highlighted")

    coordinator.applySearch(query: "ALPHA", index: 1, to: view)
    try expect(
      view.currentSelection?.pages.first === view.document?.page(at: 1),
      "next result did not select the second-page match")

    coordinator.applySearch(query: "", index: 0, to: view)
    try waitUntil { counts.last == 0 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try expect(view.highlightedSelections == nil, "cleared search was highlighted again by a stale result")

    try expect(
      PDFTextAnchor.range(of: "first\n  page", in: "Alpha  first page")
        == NSRange(location: 7, length: 10), "excerpt whitespace was not normalized")
    try expect(
      PDFTextAnchor.range(of: "missing", in: "Alpha first page") == nil, "missing excerpt was located")
    try expect(
      PDFTextAnchor.range(of: "followed by", in: "fol-\nlowed by") == NSRange(location: 0, length: 13),
      "line-end hyphenation was not bridged")
    try expect(
      PDFTextAnchor.range(of: "a filter", in: "Use a \u{FB01}lter") == NSRange(location: 4, length: 7),
      "ligature was not expanded")
    try expect(
      PDFTextAnchor.range(of: "sub-view", in: "each sub-\nview") == NSRange(location: 5, length: 9),
      "hyphenated compound split across lines was not found")
    coordinator.applyHighlights(
      [PDFTextAnchor(pageIndex: 1, text: "second page"), PDFTextAnchor(pageIndex: 7, text: "x")],
      to: view)
    try expect(view.document?.page(at: 1)?.annotations.count == 1, "evidence was not highlighted")
    coordinator.applyFocus(PDFFocusRequest(pageIndex: 1, text: "second"), to: view)
    try waitUntil { view.currentSelection?.string == "second" }
    coordinator.applyHighlights([], to: view)
    try expect(view.document?.page(at: 1)?.annotations.isEmpty == true, "cleared highlights remained")
    try verifySelectionMenu(document: view.document!)

    coordinator.apply(url: secondURL, pageIndex: 0, scale: 1, to: view)
    coordinator.applySearch(query: "beta", index: 0, to: view)
    try waitUntil { counts.last == 1 }
    try expect(view.highlightedSelections?.count == 1, "replacement document was not searched")
    try verifyControlScroll(view: view, coordinator: coordinator, recordedScale: { recordedScale })
    print("PDF search regression passed")
  }

  private static func verifyControlScroll(
    view: PDFView, coordinator: PDFViewRepresentable.Coordinator,
    recordedScale: () -> Double
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = content
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
    view.autoScales = false
    view.minScaleFactor = 0.1
    view.maxScaleFactor = 16
    view.scaleFactor = 1
    content.addSubview(view)
    content.layoutSubtreeIfNeeded()
    defer { view.removeFromSuperview() }

    @discardableResult
    func scroll(
      _ delta: Int32, control: Bool = true, precise: Bool = false, x: CGFloat = 300
    ) -> NSEvent? {
      let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
        wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
      cg.flags = control ? [.maskControl] : []
      let event = NSEvent(cgEvent: cg)!
      return coordinator.routeScroll(event, hitView: content.hitTest(NSPoint(x: x, y: 300)))
    }

    try expect(scroll(1) == nil, "Ctrl+scroll was not consumed")
    try expect(view.scaleFactor > 1, "Ctrl+wheel up did not zoom in")
    try expect(abs(recordedScale() - view.scaleFactor) < 0.001, "zoom did not record reading state")
    scroll(-1)
    try expect(abs(view.scaleFactor - 1) < 0.001, "Ctrl+wheel down did not zoom out")
    scroll(10, precise: true)
    try expect(view.scaleFactor > 1, "Ctrl+trackpad scroll did not zoom in")
    let scale = view.scaleFactor
    try expect(scroll(1, control: false) != nil, "ordinary scroll was consumed")
    try expect(view.scaleFactor == scale, "ordinary scroll changed PDF zoom")
    try expect(scroll(1, x: 700) != nil, "scroll outside the PDF was consumed")
    try expect(view.scaleFactor == scale, "Ctrl+scroll outside the PDF changed zoom")
    scroll(10_000)
    try expect(view.scaleFactor == 16, "zoom exceeded the maximum scale")
    scroll(-10_000)
    try expect(view.scaleFactor == 0.1, "zoom exceeded the minimum scale")
    coordinator.detach()
    try expect(scroll(1) != nil, "detaching left Ctrl+scroll active")
    try expect(view.scaleFactor == 0.1, "detaching left the scroll monitor active")
    print("PDF Ctrl+scroll zoom regression passed")
  }

  private static func verifySelectionMenu(document: PDFDocument) throws {
    let view = AppearancePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    view.document = document
    let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: NSPoint(x: 300, y: 300), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    var received: (PDFSelectionAction, PDFSelectedPassage)?
    view.onSelectionAction = { received = ($0, $1) }
    let selection = document.page(at: 1)!.selection(for: NSRange(location: 6, length: 6))!
    view.currentSelection = selection
    let menu = view.menu(for: event)
    try expect(
      menu?.items.prefix(PDFSelectionAction.allCases.count).map(\.title)
        == PDFSelectionAction.allCases.map(\.title),
      "selection actions were not offered")
    let highlight = menu!.items[PDFSelectionAction.highlight.rawValue]
    NSApp.sendAction(highlight.action!, to: highlight.target, from: highlight)
    try expect(
      received?.0 == .highlight && received?.1.text == "second" && received?.1.pageNumber == 2
        && received?.1.rects.count == 1 && received!.1.rects[0].width > 0,
      "selection action did not report text, 1-based page, and line rectangles")
    view.currentSelection = nil
    try expect(
      view.menu(for: event)?.items.contains { $0.title == PDFSelectionAction.ask.title } != true,
      "selection actions were offered without a selection")

    // A saved highlight is drawn, found under the pointer, and offers its own actions.
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 600, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.autoScales = true
    view.layoutSubtreeIfNeeded()
    let page = document.page(at: 1)!
    view.go(to: page)
    let coordinator = PDFViewRepresentable.Coordinator(onSearchResultCountChanged: { _ in }, onChange: { _, _ in })
    let id = UUID()
    let rect = received!.1.rects[0]
    coordinator.applyUserHighlights(
      [PDFUserHighlight(id: id, pageIndex: 1, rects: [rect], note: "memo")], to: view)
    try expect(
      page.annotations.filter { $0.userName == AppearancePDFView.highlightPrefix + id.uuidString }.count == 1,
      "saved highlight was not drawn")
    let center = view.convert(view.convert(NSPoint(x: rect.midX, y: rect.midY), from: page), to: nil)
    let onHighlight = NSEvent.mouseEvent(
      with: .rightMouseDown, location: center, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    var highlightAction: (PDFHighlightAction, UUID)?
    view.onHighlightAction = { highlightAction = ($0, $1) }
    try expect(view.highlightID(at: onHighlight) == id, "saved highlight was not found under the pointer")
    let highlightMenu = view.menu(for: onHighlight)
    try expect(
      highlightMenu?.items.map(\.title) == ["Edit Note…", "Remove Highlight", ""],
      "PDFKit markup items appeared over a saved highlight: \(highlightMenu?.items.map(\.title) ?? [])")
    let remove = highlightMenu?.items.first { $0.title == "Remove Highlight" }
    NSApp.sendAction(remove!.action!, to: remove!.target, from: remove)
    try expect(highlightAction?.0 == .remove && highlightAction?.1 == id, "highlight action was not reported")
    coordinator.applyUserHighlights([], to: view)
    try expect(
      !page.annotations.contains { $0.userName?.hasPrefix(AppearancePDFView.highlightPrefix) == true },
      "removed highlight is still drawn")
  }

  private static func makePDF(pages: [String], at url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
      throw TestError("Could not create PDF context")
    }
    for text in pages {
      context.beginPDFPage(nil)
      let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 18)]))
      context.textPosition = CGPoint(x: 72, y: 700)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  private static func waitUntil(_ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)),
      Date() < deadline {}
    try expect(condition(), "Timed out waiting for PDFKit search")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestError(message) }
  }

  private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
