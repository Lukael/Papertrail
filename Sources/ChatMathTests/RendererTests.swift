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

  print("PASS math renderer")
}

private func expectMath(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure(description: message) }
}
