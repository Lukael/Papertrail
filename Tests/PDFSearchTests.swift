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
