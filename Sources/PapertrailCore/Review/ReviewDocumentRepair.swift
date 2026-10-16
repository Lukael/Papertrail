import Foundation

/// A partial correction from Claude: complete replacement items keyed by ID, and IDs to remove.
/// Sending only these items keeps a correction turn short instead of rewriting the document.
public struct ReviewDocumentPatch: Codable, Equatable, Sendable {
  public struct Replacements: Codable, Equatable, Sendable {
    public var evidence: [ReviewEvidence]?
    public var points: [EvidenceLinkedStatement]?
    public var figures: [ReviewFigureReference]?
    public var equations: [ReviewEquation]?
  }

  public struct Removals: Codable, Equatable, Sendable {
    public var evidence: [String]?
    public var points: [String]?
    public var figures: [String]?
    public var equations: [String]?
    public var slides: [String]?
  }

  public var replace: Replacements?
  public var remove: Removals?
}

/// What the app removed so a document could pass verification; shown as a warning.
public struct ReviewOmissions: Codable, Equatable, Sendable {
  public var evidence: [ReviewEvidence] = []
  public var claims: [String] = []
  public var slides: [String] = []

  public init() {}

  public var isEmpty: Bool { evidence.isEmpty && claims.isEmpty && slides.isEmpty }
}

extension ReviewDocumentV2 {
  public func applying(_ patch: ReviewDocumentPatch) -> ReviewDocumentV2 {
    var evidence = self.evidence
    for item in patch.replace?.evidence ?? [] {
      if let index = evidence.firstIndex(where: { $0.id == item.id }) {
        evidence[index] = item
      } else {
        evidence.append(item)
      }
    }
    let points = Dictionary(
      (patch.replace?.points ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let figures = Dictionary(
      (patch.replace?.figures ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let equations = Dictionary(
      (patch.replace?.equations ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let slides = self.slides.map { slide in
      ReviewSlide(
        id: slide.id, kind: slide.kind, title: slide.title,
        points: slide.points.map { points[$0.id] ?? $0 },
        figures: slide.figures.map { figures[$0.id] ?? $0 },
        equations: slide.equations.map { equations[$0.id] ?? $0 },
        script: slide.script, qa: slide.qa)
    }
    let remove = patch.remove
    return ReviewDocumentV2(
      schemaVersion: schemaVersion, title: title, slides: slides, evidence: evidence,
      discussion: discussion
    ).removing(
      evidenceIDs: Set(remove?.evidence ?? []),
      claimIDs: Set((remove?.points ?? []) + (remove?.figures ?? []) + (remove?.equations ?? [])),
      slideIDs: Set(remove?.slides ?? [])
    ).document
  }

  /// Removes items and everything that rested only on them, keeping references two-way: a
  /// paper point or figure left without evidence goes, a slide left without points goes, and
  /// evidence that no longer supports anything goes.
  public func removing(
    evidenceIDs: Set<String>, claimIDs: Set<String> = [], slideIDs: Set<String> = []
  ) -> (document: ReviewDocumentV2, omissions: ReviewOmissions) {
    var omissions = ReviewOmissions()
    var removedClaims = claimIDs
    let slides = self.slides.compactMap { slide -> ReviewSlide? in
      let slideClaims =
        slide.points.map(\.id) + slide.figures.map(\.id) + slide.equations.map(\.id)
      if slideIDs.contains(slide.id) {
        removedClaims.formUnion(slideClaims)
        omissions.slides.append(slide.title)
        return nil
      }
      let points = slide.points.compactMap { point -> EvidenceLinkedStatement? in
        let kept = point.evidenceIDs.filter { !evidenceIDs.contains($0) }
        let orphaned = slide.kind == .paper && kept.isEmpty && !point.evidenceIDs.isEmpty
        guard !removedClaims.contains(point.id), !orphaned else {
          removedClaims.insert(point.id)
          omissions.claims.append(point.text)
          return nil
        }
        return EvidenceLinkedStatement(id: point.id, text: point.text, evidenceIDs: kept)
      }
      let figures = slide.figures.compactMap { figure -> ReviewFigureReference? in
        let kept = figure.evidenceIDs.filter { !evidenceIDs.contains($0) }
        guard !removedClaims.contains(figure.id), !kept.isEmpty else {
          removedClaims.insert(figure.id)
          omissions.claims.append(figure.label)
          return nil
        }
        return ReviewFigureReference(
          id: figure.id, label: figure.label, description: figure.description,
          evidenceIDs: kept)
      }
      let equations = slide.equations.compactMap { equation -> ReviewEquation? in
        let kept = equation.evidenceIDs.filter { !evidenceIDs.contains($0) }
        guard !removedClaims.contains(equation.id), !kept.isEmpty else {
          removedClaims.insert(equation.id)
          omissions.claims.append(equation.label)
          return nil
        }
        return ReviewEquation(
          id: equation.id, label: equation.label, latex: equation.latex,
          meaning: equation.meaning, variables: equation.variables, evidenceIDs: kept)
      }
      guard !points.isEmpty else {
        removedClaims.formUnion(slideClaims)
        omissions.slides.append(slide.title)
        return nil
      }
      return ReviewSlide(
        id: slide.id, kind: slide.kind, title: slide.title, points: points, figures: figures,
        equations: equations, script: slide.script, qa: slide.qa)
    }
    let evidence = self.evidence.compactMap { item -> ReviewEvidence? in
      if evidenceIDs.contains(item.id) {
        omissions.evidence.append(item)
        return nil
      }
      let supports = item.supports.filter { !removedClaims.contains($0) }
      if supports.isEmpty && !item.supports.isEmpty { return nil }
      return ReviewEvidence(
        id: item.id, pageIndex: item.pageIndex, printedLocator: item.printedLocator,
        class: item.class, exactExcerpt: item.exactExcerpt, supports: supports)
    }
    return (
      ReviewDocumentV2(
        schemaVersion: schemaVersion, title: title, slides: slides, evidence: evidence,
        discussion: discussion),
      omissions
    )
  }

  /// Last resort when correction fails: drops excerpts that are not on their declared page,
  /// then any paper slide left without author-statement or direct evidence.
  public func pruningUnverifiedEvidence(pageTexts: [String])
    -> (document: ReviewDocumentV2, omissions: ReviewOmissions)
  {
    let pages = pageTexts.map(ReviewDocumentValidator.normalizeEvidenceText)
    let unverified = evidence.filter { item in
      guard pages.indices.contains(item.pageIndex - 1) else { return true }
      let excerpt = ReviewDocumentValidator.normalizeEvidenceText(item.exactExcerpt)
      return excerpt.isEmpty || !pages[item.pageIndex - 1].contains(excerpt)
    }
    var (document, omissions) = removing(evidenceIDs: Set(unverified.map(\.id)))
    while true {
      let strong = Set(
        document.evidence.filter { $0.class == .authorStatement || $0.class == .directEvidence }
          .map(\.id))
      let weak = document.slides.filter { slide in
        slide.kind == .paper
          && !slide.points.contains { !strong.isDisjoint(with: $0.evidenceIDs) }
      }
      guard !weak.isEmpty else { break }
      let next = document.removing(evidenceIDs: [], slideIDs: Set(weak.map(\.id)))
      document = next.document
      omissions.claims += next.omissions.claims
      omissions.slides += next.omissions.slides
    }
    return (document, omissions)
  }
}
