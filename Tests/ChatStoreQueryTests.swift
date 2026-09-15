import Foundation
import SwiftData
import PapertrailCore

@main struct ChatStoreQueryTests {
  @MainActor static func main() async throws {
    let container = try ModelContainerFactory.makeInMemory()
    let context = ModelContext(container)
    let selected = UUID(), other = UUID(), session = UUID()
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    for index in 0..<2_000 {
      context.insert(ChatMessage(
        paperID: other, sessionID: session, role: "user",
        committedContent: "Unrelated \(index)", deliveryState: "committed"))
    }
    for id in [second, first] {
      context.insert(ChatMessage(
        id: id, paperID: selected, sessionID: session, role: "user",
        committedContent: id.uuidString, deliveryState: "committed",
        createdAt: Date(timeIntervalSince1970: 100)))
    }
    try context.save()
    let store = SwiftDataPaperChatStore(container: container)
    let records = try await Task.detached {
      try store.messages(paperID: selected)
    }.value
    precondition(records.map(\.id) == [first, second])
    precondition(records.allSatisfy { $0.paperID == selected })
    let absent = try await Task.detached { try store.messages(paperID: UUID()) }.value
    precondition(absent.isEmpty)
    print("PASS SwiftData background query: paper isolation, stable timestamp ties, empty history amid 2000 unrelated messages")
  }
}
