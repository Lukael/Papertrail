import Foundation
import PapertrailCore

struct TestFailure: Error, CustomStringConvertible { let description: String }

func expect(_ actual: [ChatMathContent.Segment], _ expected: [ChatMathContent.Segment], _ name: String) throws {
  guard actual == expected else {
    throw TestFailure(description: "\(name): expected \(expected), got \(actual)")
  }
}

@main enum ChatMathTests {
  @MainActor static func main() throws {
    let cases: [(String, String, [ChatMathContent.Segment])] = [
      ("inline dollar", "Before $x^2 + y^2$ after", [.text("Before "), .math(source: "x^2 + y^2", display: false), .text(" after")]),
      ("display dollar", "$$\\sum_i x_i$$", [.math(source: "\\sum_i x_i", display: true)]),
      ("parentheses", "Value \\(\\alpha + 1\\).", [.text("Value "), .math(source: "\\alpha + 1", display: false), .text(".")]),
      ("brackets", "Start\\[x = y\\]End", [.text("Start"), .math(source: "x = y", display: true), .text("End")]),
      ("multiple forms", "$a$ and \\(b\\), then $$c$$", [.math(source: "a", display: false), .text(" and "), .math(source: "b", display: false), .text(", then "), .math(source: "c", display: true)]),
      ("escaped dollar", "Cost \\$5 and $x$", [.text("Cost \\$5 and "), .math(source: "x", display: false)]),
      ("escaped backtick", "Use \\` literally, then $x$", [.text("Use \\` literally, then "), .math(source: "x", display: false)]),
      ("escaped slash delimiter", #"Keep \\(literal\) and \(math\)"#, [.text(#"Keep \\(literal\) and "#), .math(source: "math", display: false)]),
      ("inline code", "Use `$x$` then $y$", [.text("Use `$x$` then "), .math(source: "y", display: false)]),
      ("fenced code", "```latex\n$$x$$\n```\n$y$", [.text("```latex\n$$x$$\n```\n"), .math(source: "y", display: false)]),
      ("variable backticks", "``code ` $x$`` and $y$", [.text("``code ` $x$`` and "), .math(source: "y", display: false)]),
      ("unclosed code", "Before `code $x$", [.text("Before `code $x$")]),
      ("unclosed dollar", "Before $x + y", [.text("Before $x + y")]),
      ("unclosed display", "Before $$x + y", [.text("Before $$x + y")]),
      ("unclosed slash", "Before \\(x + y", [.text("Before \\(x + y")]),
      ("opening whitespace", "$ x$ and $y$", [.text("$ x$ and "), .math(source: "y", display: false)]),
      ("closing whitespace", "$x $ and $y$", [.text("$x $ and "), .math(source: "y", display: false)]),
      ("prices", "Prices are $5 and $10 today.", [.text("Prices are $5 and $10 today.")]),
      ("price range", "$5-$10", [.text("$5-$10")]),
      ("inline newline", "$x\n$ then $y$", [.text("$x\n$ then "), .math(source: "y", display: false)]),
      ("inline does not use display close", "$x$$ then $y$", [.text("$x$$ then "), .math(source: "y", display: false)]),
      ("code boundary aborts math", "$unfinished `$fake$` then $real$", [.text("$unfinished `$fake$` then "), .math(source: "real", display: false)]),
      ("unicode", "한글 $\\mu=평균$ 끝", [.text("한글 "), .math(source: "\\mu=평균", display: false), .text(" 끝")]),
      ("empty", "", []),
    ]

    for (name, input, expected) in cases {
      try expect(ChatMathContent.segments(in: input), expected, name)
      print("PASS \(name)")
    }
    if CommandLine.arguments.contains("--parser-only") {
      print("PASS ChatMathTests parser \(cases.count)/\(cases.count)")
    } else {
      try testMathRenderer()
      if CommandLine.arguments.contains("--web-scroll") {
        try testWebKitScrollIsolation()
      }
      let suiteCount = cases.count + 1 + (CommandLine.arguments.contains("--web-scroll") ? 1 : 0)
      print("PASS ChatMathTests \(suiteCount)/\(suiteCount)")
    }
  }
}
