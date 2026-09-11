import Foundation

@main struct ChatTranscriptWindowTests {
  static func main() {
    precondition(
      ChatTranscriptWindow.startIndex(count: 400, visibleLimit: 40) == 360,
      "starts a long transcript at the newest 40 messages")

    precondition(
      ChatTranscriptWindow.startIndex(count: 12, visibleLimit: 40) == 0,
      "shows every message when the transcript is shorter than one page")

    precondition(
      ChatTranscriptWindow.limitRevealing(index: 120, count: 400, currentLimit: 40) == 280,
      "reveals the selected older question")

    precondition(
      ChatTranscriptWindow.limitRevealing(index: 390, count: 400, currentLimit: 80) == 80,
      "does not shrink an already expanded transcript")

    var limit = 40
    for _ in 0..<100 {
      limit = ChatTranscriptWindow.adjustedLimit(limit, oldCount: 400, newCount: 401)
      limit = ChatTranscriptWindow.adjustedLimit(limit, oldCount: 401, newCount: 400)
    }
    precondition(limit == 40, "failed optimistic sends must not expand history")
    precondition(ChatTranscriptWindow.adjustedLimit(80, oldCount: 400, newCount: 402) == 82)
    print("PASS ChatTranscriptWindow: newest page, short history, question reveal, retained expansion, failed sends")
  }
}
