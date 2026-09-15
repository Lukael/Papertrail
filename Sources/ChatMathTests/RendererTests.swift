import Foundation
import PapertrailCore

@MainActor
func testMathRenderer() throws {
  let renderer = try ChatMathRenderer()

  let supported = renderer.html(
    for: #"Inline $\frac{1}{\sqrt{x}}$, display $$\sum_{i=1}^{n} i$$, matrix \[\begin{matrix}a&b\\c&d\end{matrix}\]"#
  )
  try expectMath(supported.contains("<math"), "supported formulas did not produce MathML")
  try expectMath(supported.contains("<mfrac>"), "fraction MathML missing")
  try expectMath(supported.contains("<msqrt>"), "root MathML missing")
  try expectMath(supported.contains("∑"), "sum MathML missing")
  try expectMath(supported.contains("<mtable"), "matrix MathML missing")
  try expectMath(!supported.contains("<script"), "rendered document contains a script")

  let hostileText = renderer.html(for: #"<img src="https://example.invalid/x"> & <script>alert(1)</script>"#)
  try expectMath(hostileText.contains("&lt;img"), "raw HTML was not escaped")
  try expectMath(hostileText.contains("&lt;script&gt;"), "raw script text was not escaped")
  try expectMath(!hostileText.contains("<img"), "raw image became markup")
  try expectMath(!hostileText.contains("<script"), "raw script became executable markup")

  let javascriptSource = renderer.html(for: #"$</script><script>globalThis.compromised=true</script>$"#)
  try expectMath(!javascriptSource.contains("<script>"), "JavaScript-shaped TeX became executable markup")
  try expectMath(
    javascriptSource.contains("class=\"math-unsupported\"") || javascriptSource.contains("<math"),
    "JavaScript-shaped TeX was neither rendered nor visibly rejected"
  )
  try expectMath(
    renderer.html(for: "$x+1$").contains("<math"),
    "JavaScript-shaped TeX affected a subsequent render"
  )

  let untrusted = renderer.html(
    for: #"$\href{https://example.invalid/secret}{open}$ $\includegraphics{https://example.invalid/image.png}$"#
  )
  try expectMath(!untrusted.localizedCaseInsensitiveContains("<img"), "untrusted TeX produced an image")
  try expectMath(!untrusted.localizedCaseInsensitiveContains("<a "), "untrusted TeX produced a link")
  try expectMath(!untrusted.contains("src=\"https://"), "untrusted TeX produced a remote source")

  let unknown = renderer.html(for: #"$\definitelyUnknownCommand{x}$"#)
  try expectMath(unknown.contains("class=\"math-unsupported\""), "invalid TeX did not use the visible fallback")
  try expectMath(unknown.contains(#"$\definitelyUnknownCommand{x}$"#), "invalid TeX source was hidden")

  let macroLoop = renderer.html(for: #"$\def\loop{\loop}\loop$"#)
  try expectMath(macroLoop.contains("class=\"math-unsupported\""), "recursive macro did not fail within the expansion limit")

  _ = renderer.html(for: #"$\gdef\privateMacro{leaked}$"#)
  let independent = renderer.html(for: #"$\privateMacro$"#)
  try expectMath(independent.contains("class=\"math-unsupported\""), "macro state leaked between renders")

  let oversizedSource = String(repeating: "x", count: 16 * 1024 + 1)
  let oversized = renderer.html(for: "$\(oversizedSource)$")
  try expectMath(oversized.contains("class=\"math-unsupported\""), "oversized TeX did not use the visible fallback")

  let table = renderer.html(for: """
    | Name | Value |
    | --- | --- |
    | Alpha | 42 |
    """)
  try expectMath(ChatMarkdownTable.containsTable(in: "Name | Value\n--- | ---\nAlpha | 42"), "outer-pipe-free table was not detected")
  try expectMath(table.contains("<table>"), "valid pipe table did not produce a table")
  try expectMath(table.contains("<th style=\"text-align:left\">Name</th>"), "table header markup missing")
  try expectMath(table.contains("<td style=\"text-align:left\">42</td>"), "table cell markup missing")
  try expectMath(table.contains("class=\"table-scroll\""), "table horizontal overflow wrapper missing")

  let singleColumnTable = "| Result |\n| --- |\n| pass |"
  try expectMath(ChatMarkdownTable.containsTable(in: singleColumnTable), "single-column table was not detected")
  try expectMath(renderer.html(for: singleColumnTable).contains("<td style=\"text-align:left\">pass</td>"), "single-column row missing")

  let mathTable = renderer.html(for: "x | result\n--- | ---\n$\\frac{1}{2}$ | **half** and `0.5`")
  try expectMath(mathTable.contains("<mfrac>"), "math inside a table cell did not produce MathML")
  try expectMath(mathTable.contains("<strong>half</strong>"), "bold text inside a table cell was not rendered")
  try expectMath(mathTable.contains("<code>0.5</code>"), "code inside a table cell was not rendered")

  let alignedTable = renderer.html(for: "Left | Center | Right\n:--- | :---: | ---:\na | b | c")
  try expectMath(alignedTable.contains("text-align:left"), "left table alignment missing")
  try expectMath(alignedTable.contains("text-align:center"), "center table alignment missing")
  try expectMath(alignedTable.contains("text-align:right"), "right table alignment missing")

  let escapedPipe = renderer.html(for: "Expression | Meaning\n--- | ---\na \\| b | choice")
  try expectMath(escapedPipe.contains(">a | b</td>"), "escaped pipe split a table cell")

  let fencedTable = "```markdown\nA | B\n--- | ---\n1 | 2\n```"
  try expectMath(!ChatMarkdownTable.containsTable(in: fencedTable), "fenced code was mistaken for a table")
  try expectMath(!renderer.html(for: fencedTable).contains("<table>"), "fenced code produced table markup")

  let fenceAfterTable = "A | B\n--- | ---\n1 | 2\n```\ncode | stays code\n```"
  let fenceAfterTableHTML = renderer.html(for: fenceAfterTable)
  try expectMath(fenceAfterTableHTML.components(separatedBy: "<table>").count == 2, "fence after a table became another table row")

  let malformed = "A | B\n-- | ---\n1 | 2"
  try expectMath(!ChatMarkdownTable.containsTable(in: malformed), "malformed delimiter was accepted as a table")
  try expectMath(!renderer.html(for: malformed).contains("<table>"), "malformed table produced table markup")

  let hostileTable = renderer.html(for: "Header | Other\n--- | ---\n<img src=x> | <script>alert(1)</script>")
  try expectMath(hostileTable.contains("&lt;img src=x&gt;"), "raw HTML in table cell was not escaped")
  try expectMath(hostileTable.contains("&lt;script&gt;"), "raw script in table cell was not escaped")
  try expectMath(!hostileTable.contains("<img"), "raw image in table cell became markup")
  try expectMath(!hostileTable.contains("<script>"), "raw script in table cell became executable markup")

  try expectMath(!ChatMarkdownRenderer.requiresHTML(in: "ordinary chat text"), "plain text unnecessarily required HTML")
  try expectMath(ChatMarkdownRenderer.requiresHTML(in: "### Findings"), "heading Markdown was not detected")
  try expectMath(ChatMarkdownRenderer.requiresHTML(in: "- first\n- second"), "list Markdown was not detected")
  try expectMath(ChatMarkdownRenderer.requiresHTML(in: "**important**"), "inline Markdown was not detected")

  let basicMarkdown = renderer.html(for: """
    ### Findings

    A **strong**, *emphasized*, ~~removed~~, and `literal` result.

    > Read this carefully.

    1. first
    2. second

    - outer
      - inner

    ---
    """)
  try expectMath(basicMarkdown.contains("<h3>Findings</h3>"), "level-three heading was not rendered")
  try expectMath(basicMarkdown.contains("<strong>strong</strong>"), "strong emphasis was not rendered")
  try expectMath(basicMarkdown.contains("<em>emphasized</em>"), "emphasis was not rendered")
  try expectMath(basicMarkdown.contains("<del>removed</del>"), "strikethrough was not rendered")
  try expectMath(basicMarkdown.contains("<code>literal</code>"), "inline code was not rendered")
  try expectMath(basicMarkdown.contains("<blockquote>"), "block quote was not rendered")
  try expectMath(basicMarkdown.contains("<ol"), "ordered list was not rendered")
  try expectMath(basicMarkdown.components(separatedBy: "<ul>").count >= 3, "nested unordered list was not rendered")
  try expectMath(
    basicMarkdown.components(separatedBy: "<li").count == 5,
    "nested and sibling list items were duplicated"
  )
  try expectMath(basicMarkdown.contains("<hr>"), "thematic break was not rendered")

  let fencedCode = renderer.html(for: """
    ```swift
    let formula = "$notMath$"
    if value < 3 { print(value) }
    ```
    """)
  try expectMath(fencedCode.contains("<pre><code>"), "fenced code block was not rendered")
  try expectMath(fencedCode.contains("&lt; 3"), "code block content was not escaped")
  try expectMath(fencedCode.contains("$notMath$"), "math syntax inside code was interpreted")
  try expectMath(!fencedCode.contains("<math"), "code block produced math markup")

  let mixedMarkdownAndMath = renderer.html(for: "### Equation\n\n**Result:** $\\frac{1}{2}$")
  try expectMath(mixedMarkdownAndMath.contains("<h3>Equation</h3>"), "heading beside math was not rendered")
  try expectMath(mixedMarkdownAndMath.contains("<strong>Result:</strong>"), "bold text beside math was not rendered")
  try expectMath(mixedMarkdownAndMath.contains("<mfrac>"), "math beside Markdown was not preserved")

  let headingAndTable = renderer.html(for: "### Values\n\nName | Value\n--- | ---\nA | **one**")
  try expectMath(headingAndTable.contains("<h3>Values</h3>"), "heading before table was not rendered")
  try expectMath(headingAndTable.contains("<table>"), "table after heading was not preserved")
  try expectMath(headingAndTable.contains("<strong>one</strong>"), "table inline Markdown was not preserved")

  let safeLinks = renderer.html(
    for: "[web](https://example.com) [mail](mailto:test@example.com) [bad](javascript:evil)"
  )
  try expectMath(safeLinks.contains("href=\"https://example.com\""), "HTTPS link was not rendered")
  try expectMath(safeLinks.contains("href=\"mailto:test@example.com\""), "mailto link was not rendered")
  try expectMath(!safeLinks.contains("href=\"javascript:"), "unsafe link scheme was rendered")
  try expectMath(safeLinks.contains("bad"), "unsafe link label disappeared")

  let remoteImage = renderer.html(for: "![diagram](https://example.com/diagram.png)")
  try expectMath(remoteImage.contains("diagram"), "remote image alt text disappeared")
  try expectMath(!remoteImage.contains("<img"), "remote Markdown image became active content")

  let hostileMarkdown = renderer.html(for: "### <script>alert(1)</script>\n\n<img src=x>")
  try expectMath(hostileMarkdown.contains("&lt;script&gt;"), "raw HTML in Markdown was not escaped")
  try expectMath(!hostileMarkdown.contains("<script>"), "raw HTML in Markdown became executable")
  try expectMath(!hostileMarkdown.contains("<img"), "raw image HTML in Markdown became active content")

  print("PASS math renderer")
}

private func expectMath(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure(description: message) }
}
