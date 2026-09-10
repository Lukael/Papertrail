import Foundation

public struct ReviewHTMLRenderer: Sendable {
  public static let rendererVersion = 1

  public init() {}

  public func render(document: ReviewDocumentV1) -> String {
    let title = escape(document.title)
    return """
      <!doctype html>
      <html lang="ko">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="\(attribute(document.title)) 연구 해설">
        <meta http-equiv="Content-Security-Policy" content="\(attribute(ReviewResourceSanitizer.contentSecurityPolicy))">
        <title>\(title) | Papertrail</title>
        <style>\(Self.styles)</style>
      </head>
      <body>
        <header class="topbar"><div class="brand">PAPERTRAIL · STRUCTURED REVIEW</div><nav aria-label="주요 섹션"><a href="#summary">핵심</a>\(discussionNavigation(document.discussion))<a href="#method">방법</a><a href="#experiments">실험</a><a href="#critique">비판</a><a href="#notes">근거</a></nav></header>
        <header class="hero"><div><div class="eyebrow">EVIDENCE-GROUNDED REVIEW</div><h1>\(title)<span>논문 구조와 근거를 분리해 읽기</span></h1><p class="dek">\(statementBody(document.summary))</p></div><div class="meta"><b>검증 방식</b><p>논문의 페이지별 원문과 일치하는 근거만 연결한 정적 리뷰입니다.</p></div></header>
        <div class="shell">
          <aside><nav class="toc" aria-label="목차"><strong>CONTENTS</strong><a href="#summary">1. 한눈에 보기</a>\(discussionNavigation(document.discussion))<a href="#contributions">2. 기여</a><a href="#problem">3. 문제 정의</a><a href="#method">4. 방법</a><a href="#experiments">5. 실험</a><a href="#research">6. 후속 연구</a><a href="#critique">7. 한계와 비판</a><a href="#conclusion">8. 결론</a><a href="#notes">9. 원문 근거</a></nav></aside>
          <main>
            \(section(id: "summary", kicker: "01 · Executive summary", title: "이 논문이 한 일", body: statementCard(document.summary)))
            \(discussionSection(document.discussion))
            \(section(id: "contributions", kicker: "02 · Contribution map", title: "기여와 차별점", body: cards(document.contributions)))
            \(section(id: "problem", kicker: "03 · Problem", title: "논문이 해결하려는 문제", body: statementCard(document.researchProblem)))
            \(methodSection(document.method))
            \(experimentsSection(document.experiments))
            \(followUpSection(document.followUpQuestions))
            \(critiqueSection(limitations: document.authorLimitations, concerns: document.reviewerConcerns))
            \(section(id: "conclusion", kicker: "08 · Supported conclusion", title: "근거가 지지하는 가장 강한 결론", body: "<div class=\"callout\" id=\"claim-\(attribute(document.strongestSupportedConclusion.id))\">\(statementBody(document.strongestSupportedConclusion))</div>"))
            \(evidenceSection(document.evidence))
          </main>
        </div>
        <footer><div><b>문서 성격:</b> Papertrail이 구조화 데이터에서 결정적으로 렌더링한 연구·교육용 논문 리뷰입니다.</div></footer>
      </body>
      </html>
      """
  }

  private func discussionNavigation(_ discussion: [ReviewDiscussionNote]?) -> String {
    discussion == nil ? "" : "<a href=\"#discussion\">대화 정리</a>"
  }

  private func discussionSection(_ discussion: [ReviewDiscussionNote]?) -> String {
    guard let discussion else { return "" }
    let body = discussion.isEmpty
      ? "<p class=\"muted\">리뷰 생성 시점에 정리할 대화 내용이 없습니다.</p>"
      : "<div class=\"discussion-list\">\(discussion.map(discussionCard).joined())</div>"
    return section(
      id: "discussion", kicker: "Conversation notes", title: "대화에서 정리한 내용",
      body: "<div class=\"discussion-boundary\"><b>대화 기반 메모</b><p>아래 내용은 논문 원문으로 검증된 근거가 아니라 대화에서 나온 질문·해석·가설을 정리한 것입니다.</p></div>\(body)")
  }

  private func discussionCard(_ note: ReviewDiscussionNote) -> String {
    let references = note.messageIDs.map { "<code>\(escape($0))</code>" }.joined(separator: " ")
    return "<article class=\"discussion-card\"><span class=\"discussion-kind\">\(escape(discussionLabel(note.kind)))</span><p>\(escape(note.text))</p><div class=\"source\">대화 메시지: \(references)</div></article>"
  }

  private func discussionLabel(_ kind: ReviewDiscussionKind) -> String {
    switch kind {
    case .question: return "질문"
    case .interpretation: return "해석"
    case .hypothesis: return "가설"
    case .openQuestion: return "미해결 질문"
    }
  }

  private func methodSection(_ method: ReviewMethod) -> String {
    let steps = method.pipeline.map { step in
      "<article class=\"step\" id=\"claim-\(attribute(step.id))\"><div><b>입력 · \(escape(step.input))</b><p>\(escape(step.process))</p><span>출력 · \(escape(step.output)) \(references(step.evidenceIDs))</span></div></article>"
    }.joined()
    let assumptions = method.assumptions.isEmpty
      ? ""
      : "<h3>논문이 두는 가정</h3>\(cards(method.assumptions))"
    return section(
      id: "method", kicker: "04 · Proposed method", title: "제안 방법과 처리 흐름",
      body: "<div class=\"one-line\" id=\"claim-\(attribute(method.overview.id))\">\(statementBody(method.overview))</div><div class=\"flow\">\(steps)</div>\(assumptions)")
  }

  private func experimentsSection(_ experiments: ReportedExperiments) -> String {
    let body: String
    switch experiments {
    case .reported(let items):
      let rows = items.map { item in
        "<tr id=\"claim-\(attribute(item.id))\"><td>\(escape(item.condition))</td><td>\(escape(item.metric))</td><td>\(escape(item.result)) \(references(item.evidenceIDs))</td></tr>"
      }.joined()
      body = "<div class=\"table-wrap\"><table><caption>논문에 보고된 실험</caption><thead><tr><th>조건</th><th>지표</th><th>결과</th></tr></thead><tbody>\(rows)</tbody></table></div>"
    case .notReported(let note):
      body = "<div class=\"callout\"><b>보고되지 않음</b><p>\(escape(note))</p></div>"
    }
    return section(id: "experiments", kicker: "05 · Experiments", title: "실험과 관찰 결과", body: body)
  }

  private func followUpSection(_ questions: [String]) -> String {
    let body = questions.isEmpty
      ? "<p class=\"muted\">구조화 문서에 후속 질문이 없습니다.</p>"
      : "<ol class=\"questions\">\(questions.map { "<li>\(escape($0))</li>" }.joined())</ol>"
    return section(id: "research", kicker: "06 · Research use", title: "후속 연구 질문", body: body)
  }

  private func critiqueSection(
    limitations: ReportedStatements, concerns: ReportedConcerns
  ) -> String {
    let limitationsHTML: String
    switch limitations {
    case .reported(let items): limitationsHTML = cards(items)
    case .notReported(let note): limitationsHTML = "<div class=\"callout\"><b>저자 한계 미보고</b><p>\(escape(note))</p></div>"
    }
    let concernsHTML: String
    switch concerns {
    case .reported(let items):
      concernsHTML = items.map { item in
        """
        <details id="claim-\(attribute(item.id))"><summary>\(escape(item.concern))</summary><div class="note"><p><b>영향받는 주장</b> \(escape(item.affectedClaim))</p><p><b>중요한 이유</b> \(escape(item.whyItMatters))</p><p><b>남은 불확실성</b> \(escape(item.unresolved))</p><p><b>확인 방법</b> \(escape(item.resolvingCheck)) \(references(item.evidenceIDs))</p></div></details>
        """
      }.joined()
    case .noSupportedConcern(let note):
      concernsHTML = "<div class=\"callout\"><b>근거 있는 우려 없음</b><p>\(escape(note))</p></div>"
    }
    return section(
      id: "critique", kicker: "07 · Critical reading", title: "저자 한계와 리뷰어 비판",
      body: "<h3>저자가 밝힌 한계</h3>\(limitationsHTML)<h3>리뷰어가 구분해 제기한 우려</h3>\(concernsHTML)")
  }

  private func evidenceSection(_ evidence: [ReviewEvidence]) -> String {
    let notes = evidence.map { item in
      let locator = item.printedLocator.map { " · \(escape($0))" } ?? ""
      let supports = item.supports.map { "<a href=\"#claim-\(attribute($0))\">\(escape($0))</a>" }.joined(separator: ", ")
      return """
        <details id="evidence-\(attribute(item.id))"><summary>[\(escape(item.id))] p.\(item.pageIndex)\(locator) · \(escape(item.class.rawValue))</summary><div class="note"><blockquote lang="en">\(escape(item.exactExcerpt))</blockquote><div class="source">연결된 항목: \(supports)</div></div></details>
        """
    }.joined()
    return section(id: "notes", kicker: "09 · Source notes", title: "페이지별 원문 근거", body: notes)
  }

  private func cards(_ statements: [EvidenceLinkedStatement]) -> String {
    "<div class=\"grid-2\">\(statements.map(statementCard).joined())</div>"
  }

  private func statementCard(_ statement: EvidenceLinkedStatement) -> String {
    "<article class=\"card\" id=\"claim-\(attribute(statement.id))\"><p>\(statementBody(statement))</p></article>"
  }

  private func statementBody(_ statement: EvidenceLinkedStatement) -> String {
    "\(escape(statement.text)) \(references(statement.evidenceIDs))"
  }

  private func references(_ evidenceIDs: [String]) -> String {
    evidenceIDs.map { id in
      "<sup><a href=\"#evidence-\(attribute(id))\" aria-label=\"근거 \(attribute(id))\">[\(escape(id))]</a></sup>"
    }.joined(separator: " ")
  }

  private func section(id: String, kicker: String, title: String, body: String) -> String {
    "<section id=\"\(attribute(id))\"><div class=\"kicker\">\(escape(kicker))</div><h2>\(escape(title))</h2>\(body)</section>"
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
    :root{color-scheme:dark;--bg:#101010;--surface:#191919;--surface-2:#202020;--line:#303030;--text:#d4d4d4;--muted:#929292;--accent:#b8b8b8;--link:#b1b1b1;--shadow:0 18px 48px rgba(0,0,0,.2);--radius:18px}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--text);background:radial-gradient(circle at 82% 2%,rgba(190,190,190,.055),transparent 30rem),linear-gradient(180deg,#151515,var(--bg) 36rem);font-family:Pretendard,"Noto Sans KR","Apple SD Gothic Neo",system-ui,sans-serif;line-height:1.76;word-break:keep-all}a{color:var(--link);text-underline-offset:3px}.topbar{position:sticky;top:0;z-index:10;display:flex;justify-content:space-between;align-items:center;gap:1rem;min-height:52px;padding:.65rem clamp(1rem,3vw,2.4rem);border-bottom:1px solid rgba(180,180,180,.12);background:rgba(16,16,16,.92);backdrop-filter:blur(15px)}.brand{color:var(--accent);font-size:.82rem;font-weight:850;letter-spacing:.1em}.topbar nav{display:flex;gap:1rem;font-size:.8rem}.topbar nav a,.toc a{color:var(--muted);text-decoration:none}.hero{max-width:1180px;margin:0 auto;padding:clamp(3.5rem,8vw,7rem) clamp(1.2rem,4vw,3rem) 3rem;display:grid;grid-template-columns:1.35fr .65fr;gap:clamp(2rem,5vw,5rem);align-items:end}.eyebrow,.kicker{color:var(--accent);font-size:.75rem;font-weight:900;letter-spacing:.13em;text-transform:uppercase}h1{margin:.65rem 0 1.2rem;font:600 clamp(2.35rem,6vw,5.1rem)/1 Georgia,"Times New Roman","Noto Serif KR",serif;letter-spacing:-.045em}h1 span{display:block;margin-top:.5rem;color:var(--accent);font:750 clamp(1.05rem,2.1vw,1.65rem)/1.35 system-ui,sans-serif;letter-spacing:-.02em}.dek{max-width:760px;color:#adadad;font-size:clamp(1rem,1.6vw,1.18rem)}.meta{padding:1.35rem;border:1px solid var(--line);border-radius:var(--radius);background:rgba(25,25,25,.9);box-shadow:var(--shadow);font-size:.88rem}.meta p{margin:.35rem 0 0;color:var(--muted)}.shell{max-width:1180px;margin:0 auto;padding:0 clamp(1.2rem,4vw,3rem) 7rem;display:grid;grid-template-columns:225px minmax(0,1fr);gap:3rem}aside{position:sticky;top:84px;align-self:start}.toc{padding-left:1rem;border-left:1px solid var(--line)}.toc strong{display:block;margin-bottom:.65rem;color:var(--muted);font-size:.76rem;letter-spacing:.1em}.toc a{display:block;padding:.28rem 0;font-size:.83rem}main{min-width:0}section{margin-bottom:5rem;scroll-margin-top:78px}h2{margin:.35rem 0 1.35rem;font-size:clamp(1.7rem,3vw,2.55rem);line-height:1.2;letter-spacing:-.035em}h3{margin:2.2rem 0 .7rem;font-size:1.15rem}p{margin:.75rem 0 1.05rem}sup a{padding:0 .12rem;color:var(--accent);font-weight:900;text-decoration:none}.grid-2{display:grid;grid-template-columns:repeat(2,1fr);gap:1rem}.card{padding:1.2rem;border:1px solid var(--line);border-radius:15px;background:var(--surface)}.card p{margin:0;color:var(--muted);font-size:.9rem}.one-line,.callout{margin:1rem 0;padding:1.15rem 1.3rem;border:1px solid #3b3b3b;border-radius:15px;background:var(--surface-2)}.flow{display:grid;gap:.75rem;counter-reset:step}.step{display:grid;grid-template-columns:3rem 1fr;gap:.9rem;padding:1rem 1.1rem;border:1px solid var(--line);border-radius:14px;background:var(--surface)}.step::before{counter-increment:step;content:counter(step,decimal-leading-zero);color:var(--accent);font-weight:900}.step p{margin:.35rem 0}.step span,.muted{color:var(--muted);font-size:.88rem}.table-wrap{margin:1.4rem 0;overflow-x:auto;border:1px solid var(--line);border-radius:15px;background:var(--surface)}table{width:100%;min-width:650px;border-collapse:collapse;font-size:.86rem}caption{padding:1rem;text-align:left;font-weight:850}th,td{padding:.65rem .8rem;border-top:1px solid var(--line);text-align:left}thead th{color:var(--muted);font-size:.75rem}details{border:1px solid var(--line);border-radius:13px;background:var(--surface)}details+details{margin-top:.6rem}summary{cursor:pointer;padding:.85rem 1rem;font-weight:800}.note{padding:0 1rem 1rem}blockquote{margin:.2rem 0 .7rem;padding:.85rem 1rem;border-left:3px solid var(--accent);background:#1e1e1e;color:#bdbdbd;font:.9rem/1.62 Georgia,"Times New Roman",serif}.source{color:var(--muted);font-size:.76rem}.discussion-boundary{margin:0 0 1rem;padding:1rem 1.15rem;border:1px dashed #555;border-radius:14px;background:#171717;color:var(--muted)}.discussion-boundary p{margin:.3rem 0 0}.discussion-list{display:grid;gap:.75rem}.discussion-card{padding:1rem 1.15rem;border:1px solid #464646;border-radius:14px;background:var(--surface)}.discussion-card p{margin:.55rem 0}.discussion-kind{display:inline-block;padding:.12rem .5rem;border:1px solid #5a5a5a;border-radius:999px;color:#c8c8c8;font-size:.72rem;font-weight:850}.discussion-card code{display:inline-block;margin:.15rem .2rem .15rem 0;padding:.08rem .3rem;border-radius:5px;background:#272727;color:#aaa;font-size:.7rem}.questions{padding-left:1.4rem}.questions li{margin:.65rem 0}footer{padding:2rem clamp(1.2rem,4vw,3rem);border-top:1px solid #292929;background:#0b0b0b;color:#8f8f8f;font-size:.8rem}footer div{max-width:1180px;margin:0 auto}@media(max-width:900px){.hero,.shell{grid-template-columns:1fr}.shell{display:block}aside{display:none}.grid-2{grid-template-columns:1fr}}@media(max-width:620px){.topbar nav{display:none}.step{grid-template-columns:1fr}h1{font-size:2.55rem}}@media print{.topbar,aside{display:none}body{background:#fff;color:#191919;font-size:10.5pt}.hero,.shell{display:block;max-width:none;padding:1cm}.card,.step,details{break-inside:avoid;box-shadow:none}details>*{display:block!important}}
    """
}
