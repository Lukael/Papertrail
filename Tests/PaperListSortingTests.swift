import Foundation

@main
enum PaperListSortingTests {
  static func main() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let papers = [
      item(id: thirdID, title: "Zulu", uploaded: base, chatted: nil),
      item(id: secondID, title: "Alpha", uploaded: base.addingTimeInterval(20), chatted: base),
      item(id: firstID, title: "Alpha", uploaded: base.addingTimeInterval(10), chatted: base.addingTimeInterval(30)),
    ]

    precondition(PaperListSorter.sort(papers, by: .name).map(\.id) == [firstID, secondID, thirdID])
    precondition(PaperListSorter.sort(papers, by: .uploaded).map(\.id) == [secondID, firstID, thirdID])
    precondition(PaperListSorter.sort(papers, by: .recentChat).map(\.id) == [firstID, secondID, thirdID])

    let ties = [
      item(id: secondID, title: "Same", uploaded: base, chatted: nil),
      item(id: firstID, title: "Same", uploaded: base, chatted: nil),
    ]
    for order in PaperSortOrder.allCases {
      precondition(PaperListSorter.sort(ties, by: order).map(\.id) == [firstID, secondID])
    }

    let updated = papers[0].notingChatActivity(at: base.addingTimeInterval(60))
    precondition(updated.lastChatAt == base.addingTimeInterval(60))
    precondition(updated.notingChatActivity(at: base).lastChatAt == base.addingTimeInterval(60))

    let defaults = UserDefaults(suiteName: "PaperListSortingTests")!
    defaults.removePersistentDomain(forName: "PaperListSortingTests")
    precondition(PaperSortOrder.load(defaults: defaults) == .name)
    PaperSortOrder.recentChat.save(defaults: defaults)
    precondition(PaperSortOrder.load(defaults: defaults) == .recentChat)
    defaults.removePersistentDomain(forName: "PaperListSortingTests")

    print("PASS paper list sorting: name, upload time, recent user chat, stable ties")
  }

  private static func item(
    id: UUID, title: String, uploaded: Date, chatted: Date?
  ) -> PaperListItem {
    PaperListItem(
      id: id, title: title, sourceRelativePath: "papers/\(id).pdf", sourceSHA256: "hash",
      pageIndex: 0, scale: 1, createdAt: uploaded, lastChatAt: chatted)
  }
}
