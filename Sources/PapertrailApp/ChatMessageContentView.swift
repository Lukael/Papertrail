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
      let hasMath = ChatMathContent.segments(in: text).contains {
        if case .math = $0 { return true }
        return false
      }
      guard hasMath || ChatMarkdownRenderer.requiresHTML(in: text) else {
        html = nil
        renderingError = nil
        return
      }
      switch ChatMathRenderer.shared {
      case .success(let renderer):
        html = renderer.html(for: text)
        renderingError = nil
      case .failure(let error):
        html = nil
        renderingError = error.localizedDescription
      }
    }
  }
}
