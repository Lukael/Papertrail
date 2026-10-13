#!/usr/bin/env python3
"""Verify catalog protocol and the actual app's model preference code."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, DEVELOPER_DIR="/Library/Developer/CommandLineTools",
           SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / ".build/ModuleCache"),
           CLANG_MODULE_CACHE_PATH=str(ROOT / ".build/ModuleCache"))


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, env=ENV, check=True, timeout=180, **kwargs)


def main():
    run(["swift", "run", "--disable-sandbox", "Gate0ATests"])
    run(["swift", "build", "--disable-sandbox", "--product", "PapertrailApp"])
    binary = Path(run(["swift", "build", "--disable-sandbox", "--show-bin-path"],
                      capture_output=True, text=True).stdout.strip())
    objects = (binary / "PapertrailApp.product/Objects.LinkFileList").read_text().splitlines()
    objects = [path for path in objects if "/PapertrailCore.build/" in path or
               "/PPRProcessSupervisor.build/" in path]
    assert objects, "Missing core linker inputs"
    output = ROOT / ".build/codex-model-tests/CodexModelSelectionTests"
    output.parent.mkdir(parents=True, exist_ok=True)
    run(["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path",
         str(ROOT / ".build/ModuleCache"), "-I", str(binary / "Modules"), "-I",
         str(binary / "PPRProcessSupervisor.build"), "Sources/PapertrailApp/CodexModelSelection.swift",
         "Tests/CodexModelSelectionTests.swift", *objects, "-o", str(output)])
    run([str(output), *sys.argv[1:]])


if __name__ == "__main__":
    main()
