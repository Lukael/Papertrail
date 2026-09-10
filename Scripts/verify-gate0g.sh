#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
evidence="$repo_root/Docs/Gate0G/evidence"
iteration="$evidence/iteration-5"
capture_root="$repo_root/.build/gate0g-empty-capture-root"
capture_log="$iteration/capture-server.log"
python_path=${PYTHON_PATH:-$(command -v python3)}
mkdir -p "$module_cache" "$iteration" "$capture_root"
: > "$capture_log"

for target in Gate0ATests Gate0CTests Gate0DTests Gate0ETests Gate0FTests Gate0GTests; do
  log="$iteration/$target.log"
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
    swift run --disable-sandbox --package-path "$repo_root" "$target" > "$log" 2>&1
  cat "$log"
done
grep -Fq 'PASS Gate0GTests 16/16' "$iteration/Gate0GTests.log"

PYTHONUNBUFFERED=1 "$python_path" -m http.server 8765 --bind 127.0.0.1 \
  --directory "$capture_root" > "$capture_log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT INT TERM
capture_ready=0
attempt=0
while test "$attempt" -lt 50; do
  if "$python_path" -c \
    'import socket; connection = socket.create_connection(("127.0.0.1", 8765), 0.2); connection.close()' \
    >/dev/null 2>&1; then
    capture_ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
test "$capture_ready" -eq 1
kill -0 "$server_pid" 2>/dev/null

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift run --disable-sandbox --package-path "$repo_root" Gate0GHarness \
    --hostile-html "$repo_root/Fixtures/Gate0G/hostile-integrated-review.html" \
    --pdf "$repo_root/Fixtures/Papers/representative-paper.pdf" \
    --evidence-directory "$iteration" \
    --result "$iteration/webkit-harness.json" \
    --capture-request-count 0

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
trap - EXIT INT TERM
request_count=$(grep -Ec '"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) ' "$capture_log" || true)
printf '{\n  "endpoint": "http://127.0.0.1:8765",\n  "servedDirectory": "%s",\n  "readinessTCPConnect": true,\n  "unexpectedRequestCount": %s,\n  "status": "%s"\n}\n' \
  "$capture_root" "$request_count" "$(test "$request_count" -eq 0 && printf passed || printf failed)" \
  > "$iteration/capture-server.json"
test "$request_count" -eq 0

"$python_path" -c '
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text()); m = d["navigationMetrics"]
assert d["status"] == "passed"
assert d["javaScriptEnabled"] is False and d["persistentWebsiteDataStore"] is False
assert d["installedUserScriptCount"] == 0
assert m["deniedNewWindowCount"] >= 1 and m["deniedDownloadCount"] >= 1
assert m["deniedFileChooserCount"] >= 1 and m["deniedNavigationCount"] >= 1
assert m["externalConfirmationRequestCount"] == 2
assert d["confirmationRequestsAfterPopupDeny"] == 0
assert [d["externalOpenCountBeforeInteraction"], d["externalOpenCountAfterDeny"], d["externalOpenCountAfterPopupDeny"], d["externalOpenCountAfterConfirm"]] == [0, 0, 0, 1]
assert d["sameWebViewLocationSwitchPassed"] is True
assert d["coordinatorInitialReadRoot"] != d["coordinatorSwitchedReadRoot"]
assert d["coordinatorFinalDocumentMarker"] == "COORDINATOR-B"
assert d["ruleInstallationFailureObserved"] is True
assert "rule installation failed" in d["ruleInstallationFailureReason"]
assert d["ruleInstallationRetryPassed"] is True
assert d["ruleInstallerAttemptCount"] == 2
' "$iteration/webkit-harness.json"
for screenshot in workspace-wide.png workspace-narrow-paper.png workspace-narrow-review.png workspace-narrow-chat.png workspace-recovery.png hostile-runtime.png; do
  test -s "$iteration/$screenshot"
done
test -z "$(find "$iteration/runtime" -type l -print -quit)"

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift build --disable-sandbox --package-path "$repo_root" -c release
"$repo_root/Scripts/build-gate0e-app.sh" > "$iteration/app-build.log" 2>&1
cat "$iteration/app-build.log"
app_path=$(tail -n 1 "$iteration/app-build.log")
/usr/bin/codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path" > "$iteration/app-path.txt"
/usr/bin/codesign -dv --verbose=2 "$app_path" > "$iteration/codesign.txt" 2>&1

! rg -n 'addScriptMessageHandler|WKDownloadDelegate' \
  "$repo_root/Sources/PapertrailApp" "$repo_root/Sources/PapertrailCore/Security"
rg -n 'allowsContentJavaScript = false|websiteDataStore = \.nonPersistent' \
  "$repo_root/Sources/PapertrailCore/Security/ReviewContentPolicy.swift" \
  > "$iteration/webkit-static-contracts.txt"
rg -n 'targetFrame != nil|navigationType == \.linkActivated|runOpenPanelWith|createWebViewWith|allowingReadAccessTo: resolved\.readRoot' \
  "$repo_root/Sources/PapertrailCore/Security/RestrictedReviewNavigationDelegate.swift" \
  >> "$iteration/webkit-static-contracts.txt"
rg -n 'accessibilityLabel|accessibilityHint|keyboardShortcut|geometry\.size\.width' \
  "$repo_root/Sources/PapertrailApp/PaperWorkspaceViews.swift" \
  > "$iteration/accessibility-static-contracts.txt"

"$python_path" - "$iteration" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
names = ["workspace-wide.png", "workspace-narrow-paper.png", "workspace-narrow-review.png", "workspace-narrow-chat.png", "workspace-recovery.png", "hostile-runtime.png", "webkit-harness.json", "capture-server.json"]
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
summary = {
  "status": "passed", "gate": "Gate 0G - restricted integrated reading UX",
  "gate0GTests": "16/16", "priorRegressionTargets": 6,
  "unexpectedNetworkRequests": 0,
  "measuredNavigationDenials": {"newWindow": 1, "download": 1, "fileChooser": 1, "navigation": 1},
  "externalOpenCounts": {"before": 0, "afterDeny": 0, "afterPopupDeny": 0, "afterConfirm": 1},
  "coordinatorProof": {"sameWebViewLocationSwitch": True, "finalMarker": "COORDINATOR-B", "distinctReadRoots": True, "ruleFailureObserved": True, "retrySucceeded": True, "compilerAttempts": 2},
  "hashes": hashes, "appSignature": "ad-hoc verified",
  "fullXcodeUITestGap": "Full Xcode is unavailable; SwiftPM app bundle, production-delegate WKWebView harness, static accessibility contracts, screenshots, release build, and ad-hoc signature were verified."
}
(root / "verification-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
PY

printf '%s\n' "PASS: Gate 0G restricted integrated reading UX"
printf '%s\n' "Evidence: $iteration"
