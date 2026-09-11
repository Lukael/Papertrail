#!/usr/bin/env python3
"""Verify trackpad routing and the production chat View in isolated native windows."""
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".build/scenarios/scroll-render"
ENV = dict(os.environ, DEVELOPER_DIR="/Library/Developer/CommandLineTools")


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, env=ENV, check=True, timeout=300, **kwargs)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run(["swift", "build", "--disable-sandbox", "--product", "ChatMathTests"])
    bin_path = Path(run(
        ["swift", "build", "--disable-sandbox", "--show-bin-path"],
        capture_output=True, text=True,
    ).stdout.strip())
    compiler = ["swiftc", "-module-cache-path", str(ROOT / ".build/ModuleCache"),
                "-parse-as-library"]
    router = "Sources/PapertrailApp/ChatScrollEventRouter.swift"
    routing = OUTPUT / "TrackpadRoutingTests"
    run(compiler + [router, "Tests/ChatScrollRoutingTests.swift", "-o", str(routing)])
    transcript_window = OUTPUT / "ChatTranscriptWindowTests"
    run(compiler + ["Sources/PapertrailApp/ChatTranscriptWindow.swift",
                    "Tests/ChatTranscriptWindowTests.swift", "-o", str(transcript_window)])

    # Compile the actual chat View against an inert controller fixture, rather
    # than maintaining a second approximation of the production layout.
    source = (ROOT / "Sources/PapertrailApp/PaperWorkspaceViews.swift").read_text()
    marker = "private struct PaperChatView:"
    assert source.count(marker) == 1, "Update production View extraction boundary"
    view = OUTPUT / "ChatView.swift"
    extracted = ("import AppKit\nimport SwiftUI\nimport PapertrailCore\n" +
                 source[source.index(marker):].replace(marker, "struct PaperChatView:", 1))
    view.write_text(extracted)
    bounded_expression = "controller.messages.suffix(from: firstVisibleIndex)"
    assert extracted.count(bounded_expression) == 1, "Update transcript window baseline replacement"
    baseline_view = OUTPUT / "ChatViewAllHistoryBaseline.swift"
    baseline_view.write_text(extracted.replace(bounded_expression, "controller.messages", 1))
    objects = (bin_path / "ChatMathTests.product/Objects.LinkFileList").read_text().splitlines()
    objects = [p for p in objects if "/PapertrailCore.build/" in p or
               "/PPRProcessSupervisor.build/" in p]
    assert objects, "Missing core linker inputs"
    rendering = OUTPUT / "TrackpadRenderingTests"
    baseline_rendering = OUTPUT / "TrackpadRenderingAllHistoryBaseline"
    render_inputs = ["Tests/ChatScrollRenderingTests.swift", router,
                     "Sources/PapertrailApp/ChatTranscriptWindow.swift",
                     "Sources/PapertrailApp/ChatMathWebView.swift",
                     "Sources/PapertrailApp/ChatMessageContentView.swift"]
    for input_view, output in [(view, rendering), (baseline_view, baseline_rendering)]:
        run(compiler + ["-I", str(bin_path / "Modules"), "-I",
            str(bin_path / "PPRProcessSupervisor.build"), str(input_view)] +
            render_inputs + objects + ["-o", str(output)])
    for name, args in [
        ("trackpad-routing", [str(routing)]),
        ("transcript-window", [str(transcript_window)]),
        ("trackpad-render", [str(rendering), "60"]),
        ("trackpad-math", [str(rendering), "20", "--math"]),
    ]:
        result = run(args, capture_output=True, text=True)
        (OUTPUT / f"{name}.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="")

    history_results = {}
    for name, args in [
        ("all-history-baseline", [str(baseline_rendering), "400", "--math",
                                  "--history-probe", "--all-history"]),
        ("bounded-history", [str(rendering), "400", "--math",
                             "--history-probe", "--bounded-history"]),
    ]:
        result = run(args, capture_output=True, text=True)
        (OUTPUT / f"{name}.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="")
        history_results[name] = json.loads(result.stdout.strip().splitlines()[-1])

    baseline = history_results["all-history-baseline"]
    bounded = history_results["bounded-history"]
    assert baseline["math_webviews"] == 200
    assert bounded["math_webviews"] <= 20
    comparison = {
        "baseline_initial_layout_ms": baseline["initial_layout_ms"],
        "baseline_math_webviews": baseline["math_webviews"],
        "bounded_initial_layout_ms": bounded["initial_layout_ms"],
        "bounded_math_webviews": bounded["math_webviews"],
        "status": "passed",
    }
    comparison_text = json.dumps(comparison, sort_keys=True)
    (OUTPUT / "history-render-comparison.log").write_text(comparison_text + "\n")
    print(comparison_text)


if __name__ == "__main__":
    main()
