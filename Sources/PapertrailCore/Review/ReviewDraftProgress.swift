import Foundation

/// Summarizes a streaming review document into "which section is being written" without
/// parsing incomplete JSON: it watches top-level schema keys and counts evidence excerpts as
/// text deltas arrive, keeping only a short tail so a key split across deltas is still seen.
public struct ReviewDraftProgress: Sendable {
  public static let sections: [(key: String, title: String)] = [
    ("summary", "summary"), ("researchProblem", "research problem"), ("method", "method"),
    ("contributions", "contributions"), ("experiments", "experiments"),
    ("authorLimitations", "author limitations"), ("reviewerConcerns", "reviewer concerns"),
    ("strongestSupportedConclusion", "conclusion"), ("followUpQuestions", "follow-up questions"),
    ("evidence", "evidence"), ("discussion", "discussion"),
  ]
  private static let keyPattern = try! NSRegularExpression(pattern: #""([A-Za-z]+)"\s*:"#)
  private static let tailLength = 48

  private var tail = ""
  public private(set) var sectionIndex: Int?
  public private(set) var evidenceCount = 0

  public init() {}

  /// Consumes one delta and returns a new status line when the visible progress changed.
  public mutating func consume(_ delta: String) -> String? {
    let window = tail + delta
    let newDataStart = (window as NSString).length - (delta as NSString).length
    let before = (sectionIndex, evidenceCount)
    let range = NSRange(location: 0, length: (window as NSString).length)
    for match in Self.keyPattern.matches(in: window, range: range)
    where NSMaxRange(match.range) > newDataStart {
      let key = (window as NSString).substring(with: match.range(at: 1))
      if key == "exactExcerpt" {
        evidenceCount += 1
      } else if let index = Self.sections.firstIndex(where: { $0.key == key }) {
        sectionIndex = max(sectionIndex ?? index, index)
      }
    }
    tail = String(window.suffix(Self.tailLength))
    guard before.0 != sectionIndex || before.1 != evidenceCount else { return nil }
    return statusText
  }

  public var statusText: String {
    guard let sectionIndex else { return "Writing the review document…" }
    let section = Self.sections[sectionIndex]
    var text = "Writing review: \(section.title) (\(sectionIndex + 1) of \(Self.sections.count))"
    if evidenceCount > 0 {
      text += " · \(evidenceCount) evidence excerpt\(evidenceCount == 1 ? "" : "s")"
    }
    return text
  }
}

/// Lock-protected progress state shared with the transport's background reader.
final class ReviewDraftProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var progress = ReviewDraftProgress()

  func consume(_ delta: String) -> String? { lock.withLock { progress.consume(delta) } }
  func reset() { lock.withLock { progress = ReviewDraftProgress() } }
}
