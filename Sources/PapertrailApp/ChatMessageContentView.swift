import AppKit
import PapertrailCore
import SwiftUI

/// Keeps persisted messages untouched; only their presentation interprets math delimiters.
struct ChatMessageContentView: View {
  let text: String
  @State private var html: String?
  @State private var height: CGFloat = 24
  @State private var renderingError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let html {
        // Keep SwiftUI contextMenu off the native WebView: it blanks embedded content
        // after scrolling on macOS. The WebView supplies its own source-copy menu.
        ChatMathWebView(html: html, sourceText: text) { newHeight in
          if abs(height - newHeight) > 0.5 { height = newHeight }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
      } else {
        Text(text)
          .textSelection(.enabled)
          .contextMenu {
            Button("Copy message source") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
            }
          }
      }
      if let renderingError {
        Text("Math rendering unavailable")
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
      guard hasMath else {
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
