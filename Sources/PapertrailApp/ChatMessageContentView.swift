import AppKit
import PapertrailCore
import SwiftUI

/// Keeps persisted messages untouched while presenting Markdown and math.
struct ChatMessageContentView: View {
  let text: String
  @AppStorage("chatTextSizePercent") private var textSizePercent = 100
  @State private var html: String?
  @State private var height: CGFloat = 24
  @State private var renderingError: String?

  private var fontSize: CGFloat { 13 * CGFloat(min(200, max(80, textSizePercent))) / 100 }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let html {
        // Keep SwiftUI contextMenu off the native WebView: it blanks embedded content
        // after scrolling on macOS. The WebView supplies its own source-copy menu.
        ChatMathWebView(html: html, sourceText: text, fontSize: fontSize) { newHeight in
          if abs(height - newHeight) > 0.5 { height = newHeight }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
      } else {
        Text(text)
          .font(.system(size: fontSize))
          .lineSpacing(max(0, fontSize * 1.6 - NSLayoutManager().defaultLineHeight(
            for: .systemFont(ofSize: fontSize))))
          .textSelection(.enabled)
          .contextMenu {
            Button("Copy message source") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
            }
          }
      }
      if let renderingError {
        Text("Message formatting unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(renderingError)
      }
    }
    .task(id: text) {
      // Off the main thread: opening a chat renders up to a page of messages at once, and the
      // first math message also loads KaTeX.
      let rendered = await Task.detached(priority: .userInitiated) { [text] in
        Self.render(text)
      }.value
      guard !Task.isCancelled else { return }
      (html, renderingError) = rendered
    }
  }

  private nonisolated static func render(_ text: String) -> (html: String?, error: String?) {
    let hasMath = ChatMathContent.segments(in: text).contains {
      if case .math = $0 { return true }
      return false
    }
    let linked = PaperSourceLink.linkingPageCitations(in: text)
    guard hasMath || ChatMarkdownRenderer.requiresHTML(in: linked) else { return (nil, nil) }
    switch ChatMathRenderer.shared {
    case .success(let renderer): return (renderer.html(for: linked), nil)
    case .failure(let error): return (nil, error.localizedDescription)
    }
  }
}
