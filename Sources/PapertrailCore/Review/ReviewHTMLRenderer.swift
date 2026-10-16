import Foundation

public struct ReviewHTMLRenderer: Sendable {
  public static let rendererVersion = 2

  /// Renders LaTeX to MathML; without it equations show as escaped TeX source.
  private let math: (@Sendable (String, Bool) -> String)?

  public init(math: (@Sendable (_ latex: String, _ display: Bool) -> String)? = nil) {
    self.math = math
  }

  public func render(document: ReviewDocumentV2, omissions: ReviewOmissions = .init()) -> String {
    let title = escape(document.title)
    let pages = Dictionary(
      document.evidence.map { ($0.id, $0.pageIndex) }, uniquingKeysWith: { first, _ in first })
    let total = document.slides.count
    let slides = document.slides.enumerated().map { index, slide in
      slideArticle(slide, number: index + 1, total: total, pages: pages)
    }.joined()
    let contents = document.slides.enumerated().map { index, slide in
      "<a href=\"#slide-\(attribute(slide.id))\">\(Self.number(index + 1)). \(escape(slide.title))</a>"
    }.joined()
    return """
      <!doctype html>
      <html lang="ko">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="\(attribute(document.title)) 발표 자료">
        <meta http-equiv="Content-Security-Policy" content="\(attribute(ReviewResourceSanitizer.contentSecurityPolicy))">
        <title>\(title) | Papertrail</title>
        <style>\(Self.styles)</style>
      </head>
      <body>
        <header class="topbar"><div class="brand">PAPERTRAIL · JOURNAL CLUB</div><nav aria-label="주요 섹션"><a href="#slides">발표</a></nav></header>
        <header class="hero"><div><div class="eyebrow">EVIDENCE-GROUNDED PRESENTATION</div><h1>\(title)<span>논문 발표 자료와 대본</span></h1></div><div class="meta"><b>슬라이드 \(total)장</b><p>대본, 그림·표 설명, 예상 질문은 접혀 있습니다. 페이지 표시(p.N)를 누르면 PDF의 해당 근거로 이동합니다.</p></div></header>
        <div class="shell">
          <aside><nav class="toc" aria-label="목차"><strong>SLIDES</strong>\(contents)</nav></aside>
          <main>
            \(omissionWarning(omissions))
            <section id="slides" class="deck" aria-label="발표 슬라이드">\(slides)</section>
            \(evidenceSection(document.evidence))
          </main>
        </div>
        <footer><div><b>문서 성격:</b> Papertrail이 구조화 데이터에서 결정적으로 렌더링한 연구·교육용 논문 발표 자료입니다.</div></footer>
      </body>
      </html>
      """
  }

  private func slideArticle(
    _ slide: ReviewSlide, number: Int, total: Int, pages: [String: Int]
  ) -> String {
    let points = slide.points.map { point in
      "<li id=\"claim-\(attribute(point.id))\">\(escape(point.text)) \(references(point.evidenceIDs, pages: pages))</li>"
    }.joined()
    let chips = slide.figures.compactMap { figure -> String? in
      guard let evidenceID = figure.evidenceIDs.first else { return nil }
      let page = pages[evidenceID].map { " · p.\($0)" } ?? ""
      return "<a class=\"figure\" href=\"#evidence-\(attribute(evidenceID))\">\(escape(figure.label))\(page)</a>"
    }.joined()
    let equations = slide.equations.isEmpty ? "" : "<div class=\"equations\">" + slide.equations.map { equation in
      "<div class=\"equation\" id=\"claim-\(attribute(equation.id))\"><div class=\"eq-label\">\(escape(equation.label)) \(references(equation.evidenceIDs, pages: pages))</div>\(mathHTML(equation.latex, display: true))</div>"
    }.joined() + "</div>"
    var folded = folder(
      "발표 대본", body: paragraphs(slide.script), className: "script")
    if !slide.figures.isEmpty {
      let notes = slide.figures.map { figure in
        "<p id=\"claim-\(attribute(figure.id))\"><b>\(escape(figure.label))</b> \(escape(figure.description)) \(references(figure.evidenceIDs, pages: pages))</p>"
      }.joined()
      folded += folder("그림·표 설명 (\(slide.figures.count))", body: notes, className: "figure-notes")
    }
    if !slide.equations.isEmpty {
      let notes = slide.equations.map { equation in
        let rows = equation.variables.map {
          "<tr><td>\(mathHTML($0.symbol, display: false))</td><td>\(escape($0.meaning))</td></tr>"
        }.joined()
        let table = rows.isEmpty ? "" : "<table class=\"variables\">\(rows)</table>"
        return "<div class=\"eq-note\"><p><b>\(escape(equation.label))</b> \(escape(equation.meaning))</p>\(table)</div>"
      }.joined()
      folded += folder("수식 해설 (\(slide.equations.count))", body: notes, className: "equation-notes")
    }
    if !slide.qa.isEmpty {
      let items = slide.qa.map { "<dt>\(escape($0.question))</dt><dd>\(escape($0.answer))</dd>" }
        .joined()
      folded += folder(
        "예상 질문 (\(slide.qa.count))", body: "<dl class=\"qa\">\(items)</dl>", className: "qa")
    }
    return """
      <article class="slide" id="slide-\(attribute(slide.id))"><div class="frame"><div class="slide-meta"><span>\(Self.number(number)) / \(Self.number(total))</span><span class="kind kind-\(slide.kind.rawValue)">\(kindLabel(slide.kind))</span></div><h2>\(escape(slide.title))</h2><ul class="points">\(points)</ul>\(equations)\(chips.isEmpty ? "" : "<div class=\"figures\">\(chips)</div>")</div>\(folded)</article>
      """
  }

  private func mathHTML(_ latex: String, display: Bool) -> String {
    math?(latex, display) ?? "<code class=\"tex\">\(escape(latex))</code>"
  }

  private func folder(_ title: String, body: String, className: String) -> String {
    "<details class=\"\(className)\"><summary>\(escape(title))</summary><div class=\"note\">\(body)</div></details>"
  }

  private func paragraphs(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { "<p>\(escape($0))</p>" }
      .joined()
  }

  private func kindLabel(_ kind: ReviewSlideKind) -> String {
    switch kind {
    case .paper: "논문 내용"
    case .critique: "비판적 검토"
    case .questions: "토론 질문"
    }
  }

  private static func number(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  private func omissionWarning(_ omissions: ReviewOmissions) -> String {
    guard !omissions.isEmpty else { return "" }
    let excerpts = omissions.evidence.map { item in
      let excerpt = item.exactExcerpt.count > 160
        ? String(item.exactExcerpt.prefix(160)) + "…" : item.exactExcerpt
      return "<li>p.\(item.pageIndex) · \u{201C}\(escape(excerpt))\u{201D}</li>"
    }.joined()
    let dependents = (omissions.claims + omissions.slides.map { "슬라이드: \($0)" })
      .map { "<li>\(escape($0))</li>" }.joined()
    let dependentsList = dependents.isEmpty
      ? "" : "<p>함께 제외한 항목</p><ul>\(dependents)</ul>"
    return """
      <details class="omissions"><summary>검증 경고 · 원문에서 찾지 못한 근거 \(omissions.evidence.count)개와 이에만 기대던 항목 \(omissions.claims.count + omissions.slides.count)개를 제외했습니다</summary><div class="note"><p>제외한 근거</p><ul>\(excerpts)</ul>\(dependentsList)</div></details>
      """
  }

  // Not shown: page links and PDF highlights read this markup (ReviewEvidenceAnchor), and the
  // review validator requires every #evidence- link to resolve.
  private func evidenceSection(_ evidence: [ReviewEvidence]) -> String {
    let notes = evidence.map { item in
      let locator = item.printedLocator.map { " · \(escape($0))" } ?? ""
      let supports = item.supports.map { "<a href=\"#claim-\(attribute($0))\">\(escape($0))</a>" }.joined(separator: ", ")
      return """
        <details id="evidence-\(attribute(item.id))"><summary>[\(escape(item.id))] p.\(item.pageIndex)\(locator) · \(escape(item.class.rawValue))</summary><div class="note"><blockquote lang="en">\(escape(item.exactExcerpt))</blockquote><div class="source">연결된 항목: \(supports)</div></div></details>
        """
    }.joined()
    return "<section id=\"notes\" hidden aria-hidden=\"true\">\(notes)</section>"
  }

  private func references(_ evidenceIDs: [String], pages: [String: Int]) -> String {
    evidenceIDs.map { id in
      let label = pages[id].map { "p.\($0)" } ?? id
      return "<sup><a href=\"#evidence-\(attribute(id))\" aria-label=\"근거 \(attribute(id)), \(attribute(label))\">\(escape(label))</a></sup>"
    }.joined(separator: " ")
  }

  private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private func attribute(_ value: String) -> String { escape(value) }

  private static let styles = """
    :root{color-scheme:dark;--bg:#101010;--surface:#191919;--surface-2:#202020;--line:#303030;--text:#d4d4d4;--muted:#929292;--accent:#b8b8b8;--link:#b1b1b1;--shadow:0 18px 48px rgba(0,0,0,.2);--radius:18px}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--text);background:radial-gradient(circle at 82% 2%,rgba(190,190,190,.055),transparent 30rem),linear-gradient(180deg,#151515,var(--bg) 36rem);font-family:Pretendard,"Noto Sans KR","Apple SD Gothic Neo",system-ui,sans-serif;line-height:1.76;word-break:keep-all}a{color:var(--link);text-underline-offset:3px}.topbar{position:sticky;top:0;z-index:10;display:flex;justify-content:space-between;align-items:center;gap:1rem;min-height:52px;padding:.65rem clamp(1rem,3vw,2.4rem);border-bottom:1px solid rgba(180,180,180,.12);background:rgba(16,16,16,.92);backdrop-filter:blur(15px)}.brand{color:var(--accent);font-size:.82rem;font-weight:850;letter-spacing:.1em}.topbar nav{display:flex;gap:1rem;font-size:.8rem}.topbar nav a,.toc a{color:var(--muted);text-decoration:none}.hero{max-width:1180px;margin:0 auto;padding:clamp(3rem,7vw,6rem) clamp(1.2rem,4vw,3rem) 2.5rem;display:grid;grid-template-columns:1.35fr .65fr;gap:clamp(2rem,5vw,5rem);align-items:end}.eyebrow,.kicker{color:var(--accent);font-size:.75rem;font-weight:900;letter-spacing:.13em;text-transform:uppercase}h1{margin:.65rem 0 1.2rem;font:600 clamp(2.1rem,5vw,4.4rem)/1.05 Georgia,"Times New Roman","Noto Serif KR",serif;letter-spacing:-.04em}h1 span{display:block;margin-top:.5rem;color:var(--accent);font:750 clamp(1.05rem,2.1vw,1.55rem)/1.35 system-ui,sans-serif;letter-spacing:-.02em}.meta{padding:1.35rem;border:1px solid var(--line);border-radius:var(--radius);background:rgba(25,25,25,.9);box-shadow:var(--shadow);font-size:.88rem}.meta p{margin:.35rem 0 0;color:var(--muted)}.shell{max-width:1180px;margin:0 auto;padding:0 clamp(1.2rem,4vw,3rem) 7rem;display:grid;grid-template-columns:240px minmax(0,1fr);gap:3rem}aside{position:sticky;top:84px;align-self:start;max-height:calc(100vh - 100px);overflow-y:auto}.toc{padding-left:1rem;border-left:1px solid var(--line)}.toc strong{display:block;margin-bottom:.65rem;color:var(--muted);font-size:.76rem;letter-spacing:.1em}.toc a{display:block;padding:.24rem 0;font-size:.8rem;line-height:1.45}main{min-width:0}section{margin-bottom:5rem;scroll-margin-top:78px}h2{margin:.35rem 0 1.35rem;font-size:clamp(1.6rem,3vw,2.4rem);line-height:1.2;letter-spacing:-.035em}p{margin:.75rem 0 1.05rem}sup a{padding:0 .12rem;color:var(--accent);font-size:.78rem;font-weight:800;text-decoration:none}.deck{display:grid;gap:2.6rem}.slide{scroll-margin-top:78px}.frame{padding:clamp(1.3rem,3vw,2.2rem);border:1px solid #3b3b3b;border-radius:var(--radius);background:linear-gradient(160deg,var(--surface-2),var(--surface));box-shadow:var(--shadow)}.slide-meta{display:flex;justify-content:space-between;gap:1rem;color:var(--muted);font-size:.74rem;font-weight:800;letter-spacing:.1em}.kind{padding:.05rem .55rem;border:1px solid #4a4a4a;border-radius:999px;letter-spacing:.02em}.kind-critique{border-color:#7a6440;color:#d6b98a}.kind-questions{border-color:#4f6578;color:#9fbcd4}.frame h2{margin:.7rem 0 1rem;font-size:clamp(1.35rem,2.4vw,1.9rem)}.points{margin:0;padding-left:1.25rem}.points li{margin:.5rem 0;font-size:1.02rem}.figures{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:1.1rem}.figure{padding:.2rem .7rem;border:1px solid var(--line);border-radius:999px;background:#151515;font-size:.8rem;font-weight:700;text-decoration:none}.slide>details{margin-top:.6rem}details{border:1px solid var(--line);border-radius:13px;background:var(--surface)}details+details{margin-top:.6rem}summary{cursor:pointer;padding:.75rem 1rem;font-weight:800}.note{padding:0 1.1rem 1rem}.script .note p{margin:.5rem 0 .9rem}.qa dt{margin-top:.7rem;font-weight:800}.qa dd{margin:.25rem 0 0;color:#bdbdbd}.figure-notes p{margin:.5rem 0}blockquote{margin:.2rem 0 .7rem;padding:.85rem 1rem;border-left:3px solid var(--accent);background:#1e1e1e;color:#bdbdbd;font:.9rem/1.62 Georgia,"Times New Roman",serif}.source{color:var(--muted);font-size:.76rem}.muted{color:var(--muted);font-size:.88rem}[hidden]{display:none!important}.equations{display:grid;gap:.6rem;margin-top:1.1rem}.equation{padding:.7rem 1rem;border:1px solid var(--line);border-radius:12px;background:#151515;overflow-x:auto}.eq-label{color:var(--muted);font-size:.74rem;font-weight:800;letter-spacing:.04em}.equation math{font-size:1.35em}.eq-note p{margin:.5rem 0 .3rem}.variables{border-collapse:collapse;margin:0 0 .8rem}.variables td{padding:.3rem .9rem .3rem 0;border-top:1px solid var(--line);vertical-align:top;font-size:.9rem}code.tex{font-family:ui-monospace,Menlo,monospace;font-size:.85em;color:#cfcfcf}.omissions{margin:0 0 1.6rem;border-color:#7a6440;background:#1b1712}.omissions summary{color:#d6b98a}.omissions li{margin:.3rem 0;color:#bdbdbd;font-size:.86rem}footer{padding:2rem clamp(1.2rem,4vw,3rem);border-top:1px solid #292929;background:#0b0b0b;color:#8f8f8f;font-size:.8rem}footer div{max-width:1180px;margin:0 auto}@media(max-width:900px){.hero,.shell{grid-template-columns:1fr}.shell{display:block}aside{display:none}}@media(max-width:620px){.topbar nav{display:none}h1{font-size:2.3rem}}@media print{.topbar,aside{display:none}body{background:#fff;color:#191919;font-size:10.5pt}.hero,.shell{display:block;max-width:none;padding:1cm}.frame,details{break-inside:avoid;box-shadow:none}.slide{break-before:page}details>*{display:block!important}}
    """
}
