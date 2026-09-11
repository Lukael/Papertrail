/// Bounds native message creation when opening a long conversation, while
/// retaining the complete transcript in the controller for question navigation.
struct ChatTranscriptWindow {
  static let pageSize = 40

  static func startIndex(count: Int, visibleLimit: Int) -> Int {
    max(0, count - max(pageSize, visibleLimit))
  }

  static func limitRevealing(index: Int, count: Int, currentLimit: Int) -> Int {
    max(currentLimit, count - index)
  }

  static func adjustedLimit(_ limit: Int, oldCount: Int, newCount: Int) -> Int {
    guard oldCount > 0 else { return limit }
    return max(pageSize, limit + newCount - oldCount)
  }
}
