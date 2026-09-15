import AppKit
import SwiftUI

@main
@MainActor
enum PaperTagsEditorTests {
  static func main() throws {
    NSApplication.shared.setActivationPolicy(.accessory)

    if CommandLine.arguments.contains("--render-only") {
      try rendersTheEditorToABitmap(persist: true)
      print("PASS PaperTagsEditor host bitmap capture")
      return
    }

    try addsATrimmedTag()
    try savesPendingText()
    try ignoresACaseInsensitiveDuplicate()
    try rendersTheEditorToABitmap(persist: true)

    print(
      "PASS PaperTagsEditor: add, pending Save, duplicate handling, host bitmap capture")
  }

  private static func addsATrimmedTag() throws {
    let harness = EditorHarness(tags: ["Existing"])
    try harness.setTextFieldValue("  New tag  ")
    try harness.submitTextField()
    try harness.invokeDefaultAction()
    precondition(harness.savedTags == ["Existing", "New tag"])
  }

  private static func savesPendingText() throws {
    let harness = EditorHarness(tags: ["Existing"])
    try harness.setTextFieldValue("Pending")
    try harness.invokeDefaultAction()
    precondition(harness.savedTags == ["Existing", "Pending"])
  }

  private static func ignoresACaseInsensitiveDuplicate() throws {
    let harness = EditorHarness(tags: ["Existing"])
    try harness.setTextFieldValue("eXiStInG")
    try harness.invokeDefaultAction()
    precondition(harness.savedTags == ["Existing"])
  }

  private static func rendersTheEditorToABitmap(persist: Bool) throws {
    let harness = EditorHarness(tags: ["Vision", "읽을 논문"])
    guard let representation = harness.host.bitmapImageRepForCachingDisplay(in: harness.host.bounds)
    else { throw TestFailure("Could not create a bitmap representation") }
    harness.host.cacheDisplay(in: harness.host.bounds, to: representation)
    precondition(representation.pixelsWide > 300)
    precondition(representation.pixelsHigh > 200)
    if persist {
      guard let data = representation.representation(using: .png, properties: [:]) else {
        throw TestFailure("Could not encode the editor bitmap as PNG")
      }
      let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/scenarios/paper-search-tags/tag-editor.png")
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: output, options: .atomic)
    }
  }
}

@MainActor
private final class EditorHarness {
  let host: NSHostingView<PaperTagsEditor>
  private let window: NSWindow
  private(set) var savedTags: [String]?

  init(tags: [String]) {
    let paper = PaperListItem(
      id: UUID(), title: "Attention Is All You Need", sourceRelativePath: "paper.pdf",
      sourceSHA256: "hash", pageIndex: 0, scale: 1, createdAt: Date(), lastChatAt: nil,
      tags: tags)
    var captured: [String]?
    host = NSHostingView(rootView: PaperTagsEditor(paper: paper) { captured = $0 })
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = window.contentView!.bounds
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    settle()
    savedTagsProvider = { captured }
  }

  private var savedTagsProvider: () -> [String]? = { nil }

  func setTextFieldValue(_ newValue: String) throws {
    guard let field = nativeTextField() else {
      throw TestFailure("New tag native text field was not found; views: \(viewSummary())")
    }
    field.stringValue = newValue
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    settle()
  }

  func submitTextField() throws {
    guard let field = nativeTextField() else { throw TestFailure("New tag text field was not found") }
    window.makeFirstResponder(field)
    try sendKey(characters: "\r", keyCode: 36)
  }

  func invokeDefaultAction() throws {
    window.makeFirstResponder(nil)
    try sendKey(characters: "\r", keyCode: 36)
    savedTags = savedTagsProvider()
  }

  private func nativeTextField() -> NSTextField? {
    func find(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, !(field is NSSecureTextField) { return field }
      return view.subviews.lazy.compactMap(find).first
    }
    return find(in: host)
  }

  private func sendKey(characters: String, keyCode: UInt16) throws {
    guard let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    else { throw TestFailure("Could not create keyboard event") }
    window.sendEvent(event)
    settle()
  }

  private func viewSummary() -> String {
    func collect(_ view: NSView) -> [String] {
      [String(describing: type(of: view))] + view.subviews.flatMap(collect)
    }
    return collect(host).joined(separator: ", ")
  }

  private func settle() {
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
  }

}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
