import Foundation

/// Summarizes a streaming presentation into "which slide is being written" without parsing
/// incomplete JSON: it counts slide and evidence keys as text deltas arrive, keeping only a short
/// tail so a key split across deltas is still seen.
public struct ReviewDraftProgress: Sendable {
  public enum Phase: Int, Comparable, Sendable {
    case slides, evidence, discussion
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  private static let keyPattern = try! NSRegularExpression(pattern: #""([A-Za-z]+)"\s*:"#)
  private static let tailLength = 48

  private var tail = ""
  public private(set) var phase: Phase?
  public private(set) var slideCount = 0
  public private(set) var evidenceCount = 0

  public init() {}

  /// Consumes one delta and returns a new status line when the visible progress changed.
  public mutating func consume(_ delta: String) -> String? {
    let window = tail + delta
    let newDataStart = (window as NSString).length - (delta as NSString).length
    let before = (phase, slideCount, evidenceCount)
    let range = NSRange(location: 0, length: (window as NSString).length)
    for match in Self.keyPattern.matches(in: window, range: range)
    where NSMaxRange(match.range) > newDataStart {
      switch (window as NSString).substring(with: match.range(at: 1)) {
      // Only slides have points, so each "points" key starts the next slide.
      case "points" where phase ?? .slides == .slides:
        slideCount += 1
        phase = .slides
      case "exactExcerpt": evidenceCount += 1
      case "evidence": phase = max(phase ?? .evidence, .evidence)
      case "discussion": phase = max(phase ?? .discussion, .discussion)
      default: break
      }
    }
    tail = String(window.suffix(Self.tailLength))
    guard before != (phase, slideCount, evidenceCount) else { return nil }
    return statusText
  }

  public var statusText: String {
    let excerpts = "\(evidenceCount) evidence excerpt\(evidenceCount == 1 ? "" : "s")"
    switch phase {
    case nil: return "Writing the presentation…"
    case .slides: return "Writing presentation: slide \(slideCount)"
    case .evidence: return "Writing presentation: evidence · \(slideCount) slides · \(excerpts)"
    case .discussion:
      return "Writing presentation: conversation notes · \(slideCount) slides · \(excerpts)"
    }
  }
}

/// Lock-protected progress state shared with the transport's background reader.
final class ReviewDraftProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var progress = ReviewDraftProgress()

  func consume(_ delta: String) -> String? { lock.withLock { progress.consume(delta) } }
  func reset() { lock.withLock { progress = ReviewDraftProgress() } }
}
