import Foundation

enum PaperSortOrder: String, CaseIterable, Identifiable, Sendable {
  case name
  case uploaded
  case recentChat

  static let defaultsKey = "paperListSortOrder"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .name: "Name"
    case .uploaded: "Upload date"
    case .recentChat: "Recent chat"
    }
  }

  static func load(defaults: UserDefaults = .standard) -> Self {
    guard let rawValue = defaults.string(forKey: defaultsKey) else { return .name }
    return Self(rawValue: rawValue) ?? .name
  }

  func save(defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.defaultsKey)
  }
}

struct PaperListItem: Identifiable, Hashable, Sendable {
  let id: UUID
  let title: String
  let sourceRelativePath: String
  let sourceSHA256: String
  let pageIndex: Int
  let scale: Double
  let createdAt: Date
  let lastChatAt: Date?
  var tags: [String] = []

  func notingChatActivity(at date: Date) -> Self {
    Self(
      id: id, title: title, sourceRelativePath: sourceRelativePath,
      sourceSHA256: sourceSHA256, pageIndex: pageIndex, scale: scale,
      createdAt: createdAt, lastChatAt: max(lastChatAt ?? .distantPast, date), tags: tags)
  }
}

enum PaperListSorter {
  static func sort(_ papers: [PaperListItem], by order: PaperSortOrder) -> [PaperListItem] {
    papers.sorted { lhs, rhs in
      switch order {
      case .name:
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
      case .uploaded:
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      case .recentChat:
        switch (lhs.lastChatAt, rhs.lastChatAt) {
        case let (lhsDate?, rhsDate?):
          if lhsDate != rhsDate { return lhsDate > rhsDate }
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          break
        }
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}

enum PaperListFilter {
  static func matching(_ papers: [PaperListItem], title query: String) -> [PaperListItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return papers }
    return papers.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }
}
