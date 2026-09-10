#!/usr/bin/env python3
"""Verify trackpad routing and the production chat View in isolated native windows."""
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

    # Compile the actual chat View against an inert controller fixture, rather
    # than maintaining a second approximation of the production layout.
    source = (ROOT / "Sources/PapertrailApp/PaperWorkspaceViews.swift").read_text()
    marker = "private struct PaperChatView:"
    assert source.count(marker) == 1, "Update production View extraction boundary"
    view = OUTPUT / "ChatView.swift"
    view.write_text("import AppKit\nimport SwiftUI\nimport PapertrailCore\n" +
                    source[source.index(marker):].replace(marker, "struct PaperChatView:", 1))
    objects = (bin_path / "ChatMathTests.product/Objects.LinkFileList").read_text().splitlines()
    objects = [p for p in objects if "/PapertrailCore.build/" in p or
               "/PPRProcessSupervisor.build/" in p]
    assert objects, "Missing core linker inputs"
    rendering = OUTPUT / "TrackpadRenderingTests"
    run(compiler + ["-I", str(bin_path / "Modules"), "-I",
        str(bin_path / "PPRProcessSupervisor.build"), str(view),
        "Tests/ChatScrollRenderingTests.swift", router,
        "Sources/PapertrailApp/ChatMathWebView.swift",
        "Sources/PapertrailApp/ChatMessageContentView.swift"] + objects +
        ["-o", str(rendering)])
    for name, args in [
        ("trackpad-routing", [str(routing)]),
        ("trackpad-render", [str(rendering), "60"]),
        ("trackpad-math", [str(rendering), "20", "--math"]),
    ]:
        result = run(args, capture_output=True, text=True)
        (OUTPUT / f"{name}.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="")


if __name__ == "__main__":
    main()
