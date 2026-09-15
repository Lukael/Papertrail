#!/usr/bin/env python3
"""Run the production SwiftData query regression after building the release app."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")


def run(args, **kwargs):
    return subprocess.run(args, cwd=root, env=env, check=True, timeout=300, **kwargs)


run(["swift", "build", "--disable-sandbox", "-c", "release", "--product", "PapertrailApp"])
binary = Path(run(["swift", "build", "--disable-sandbox", "-c", "release", "--show-bin-path"],
                  capture_output=True, text=True).stdout.strip())
objects = [p for p in (binary / "PapertrailApp.product/Objects.LinkFileList").read_text().splitlines()
           if "/PapertrailCore.build/" in p or "/PPRProcessSupervisor.build/" in p]
output = root / ".build/scenarios/paper-sorting/ChatStoreQueryTests"
output.parent.mkdir(parents=True, exist_ok=True)
run(["swiftc", "-module-cache-path", ".build/ModuleCache", "-parse-as-library",
     "-I", str(binary / "Modules"), "-I", str(binary / "PPRProcessSupervisor.build"),
     "Tests/ChatStoreQueryTests.swift", *objects, "-o", str(output)])
run([str(output)])
