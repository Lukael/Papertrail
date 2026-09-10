import SwiftUI

enum AppActivityLogSource: String, Sendable {
  case app = "App"
  case codex = "Codex"
}

enum AppActivityLogLevel: String, Sendable {
  case debug = "Debug"
  case info = "Info"
  case success = "Success"
  case warning = "Warning"
  case error = "Error"
}

struct AppActivityLogEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let source: AppActivityLogSource
  var level: AppActivityLogLevel
  let createdAt: Date
  var updatedAt: Date
  var message: String
  let coalescingKey: String?
}

@MainActor
final class AppActivityLog: ObservableObject {
  @Published private(set) var entries: [AppActivityLogEntry] = []
  private let maximumEntryCount = 500

  var latest: AppActivityLogEntry? {
    entries.max { $0.updatedAt < $1.updatedAt }
  }

  func append(
    source: AppActivityLogSource = .app,
    level: AppActivityLogLevel = .info,
    _ message: String
  ) {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let now = Date()
    entries.append(
      AppActivityLogEntry(
        id: UUID(), source: source, level: level, createdAt: now, updatedAt: now,
        message: normalized, coalescingKey: nil))
    trimIfNeeded()
  }

  func upsert(
    key: String,
    source: AppActivityLogSource,
    level: AppActivityLogLevel = .info,
    message: String
  ) {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    if let index = entries.firstIndex(where: { $0.coalescingKey == key }) {
      var entry = entries.remove(at: index)
      entry.updatedAt = Date()
      entry.level = level
      entry.message = normalized
      entries.append(entry)
    } else {
      let now = Date()
      entries.append(
        AppActivityLogEntry(
          id: UUID(), source: source, level: level, createdAt: now, updatedAt: now,
          message: normalized, coalescingKey: key))
    }
    trimIfNeeded()
  }

  private func trimIfNeeded() {
    if entries.count > maximumEntryCount {
      entries.removeFirst(entries.count - maximumEntryCount)
    }
  }
}

struct ActivityLogBar: View {
  @ObservedObject var log: AppActivityLog
  @State private var showsHistory = false

  var body: some View {
    HStack(spacing: 8) {
      if let latest = log.latest {
        Image(systemName: symbol(for: latest))
          .foregroundStyle(color(for: latest.level))
          .frame(width: 14)
        Text(latest.updatedAt, format: .dateTime.hour().minute().second())
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(latest.source.rawValue)
          .font(.caption.weight(.semibold))
        Text(latest.message)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.tail)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
        Text("App log is ready")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button("Show log history", systemImage: "chevron.up") {
        showsHistory.toggle()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Show app and Codex log history")
      .popover(isPresented: $showsHistory, arrowEdge: .top) {
        ActivityLogHistoryView(log: log, onClose: { showsHistory = false })
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("App and Codex activity log")
  }

  private func symbol(for entry: AppActivityLogEntry) -> String {
    if entry.source == .codex { return "terminal" }
    return switch entry.level {
    case .debug: "ladybug"
    case .info: "info.circle"
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  private func color(for level: AppActivityLogLevel) -> Color {
    switch level {
    case .debug: .secondary
    case .info: .accentColor
    case .success: .green
    case .warning: .orange
    case .error: .red
    }
  }
}

private struct ActivityLogHistoryView: View {
  @ObservedObject var log: AppActivityLog
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Activity log", systemImage: "list.bullet.rectangle")
          .font(.headline)
        Spacer()
        Text("App + Codex")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Close", systemImage: "xmark") { onClose() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      .padding(12)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if log.entries.isEmpty {
              ContentUnavailableView("No log entries", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, minHeight: 220)
            }
            ForEach(log.entries) { entry in
              HStack(alignment: .top, spacing: 8) {
                Text(entry.updatedAt, format: .dateTime.hour().minute().second())
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.secondary)
                  .frame(width: 58, alignment: .leading)
                Text(entry.source.rawValue)
                  .font(.caption2.weight(.semibold))
                  .frame(width: 42, alignment: .leading)
                Text(entry.level.rawValue)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .frame(width: 48, alignment: .leading)
                Text(entry.message)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .id(entry.id)
            }
          }
          .padding(12)
        }
        .onAppear {
          if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        .onChange(of: log.entries.count) {
          if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }
    .frame(width: 660, height: 330)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("App and Codex log history")
  }
}
