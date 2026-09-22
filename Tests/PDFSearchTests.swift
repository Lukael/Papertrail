import AppKit
import CoreText
import PDFKit
import SwiftUI

@main
@MainActor
struct PDFSearchTests {
  static func main() throws {
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
    let coordinator = PDFViewRepresentable.Coordinator(
      onSearchResultCountChanged: { counts.append($0) }, onChange: { _, _ in })
    let view = PDFView()
    coordinator.attach(to: view)
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
    print("PDF search regression passed")
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
