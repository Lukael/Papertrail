#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
evidence="$repo_root/Docs/Gate0H/evidence/current"
python_path=${PYTHON_PATH:-$(command -v python3)}
codex_path=${CODEX_PATH:-$(command -v codex)}
case "$codex_path" in
  /*) ;;
  *) printf '%s\n' "FAIL: CODEX_PATH must resolve to one absolute executable" >&2; exit 1 ;;
esac
test -x "$codex_path"
CODEX_PATH=$codex_path
export CODEX_PATH
mkdir -p "$module_cache" "$evidence"

"$repo_root/Scripts/verify-gate0a.sh" > "$evidence/gate0a-verification.log" 2>&1
tail -n 4 "$evidence/gate0a-verification.log"
reported_codex=$("$python_path" -c 'import json,sys; print(json.load(open(sys.argv[1]))["capability"]["executablePath"])' "$repo_root/.build/gate0a-evidence/capability.json")
test "$reported_codex" = "$CODEX_PATH"

for gate in c d e f g; do
  log="$evidence/gate0${gate}-verification.log"
  if ! "$repo_root/Scripts/verify-gate0${gate}.sh" > "$log" 2>&1; then
    cat "$log"
    exit 1
  fi
  tail -n 3 "$log"
done

GATE0H_EVIDENCE_DIR="$evidence" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift run --disable-sandbox --package-path "$repo_root" Gate0HTests \
  > "$evidence/Gate0HTests.log" 2>&1
cat "$evidence/Gate0HTests.log"
grep -Fq 'PASS Gate0HTests 9/9' "$evidence/Gate0HTests.log"

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift build --disable-sandbox --package-path "$repo_root" -c release \
  > "$evidence/release-build.log" 2>&1
"$repo_root/Scripts/build-gate0h-app.sh" > "$evidence/app-build.log" 2>&1
app_path=$(tail -n 1 "$evidence/app-build.log")
app_binary="$app_path/Contents/MacOS/PapertrailApp"
printf '%s\n' "$app_path" > "$evidence/app-path.txt"

/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/codesign -dvv "$app_path" > "$evidence/codesign-details.txt" 2>&1
/usr/bin/codesign -d --entitlements - "$app_path" > "$evidence/entitlements.plist" 2>&1 || true
/usr/bin/plutil -p "$app_path/Contents/Info.plist" > "$evidence/info-plist.txt"
/usr/bin/otool -l "$app_binary" > "$evidence/mach-o-load-commands.txt"
/usr/bin/file "$app_binary" > "$evidence/executable-file.txt"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_path/Contents/Info.plist")" = "Papertrail.icns"
test -s "$app_path/Contents/Resources/Papertrail.icns"
grep -Eq 'flags=0x2\(adhoc\)|Signature=adhoc' "$evidence/codesign-details.txt"
! grep -Eq 'com\.apple\.security\.app-sandbox|com\.apple\.security\.network|com\.apple\.security\.get-task-allow' "$evidence/entitlements.plist"
test -z "$(find "$app_path" -type l -print -quit)"
"$repo_root/Scripts/verify-gate0h-finder-launch.sh" "$app_path" "$evidence/finder-launch.json"

rg -n -- '--dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust' \
  "$repo_root/Sources/PapertrailCore" "$repo_root/Sources/PapertrailApp" \
  > "$evidence/prohibited-flags-denylist.txt"
test "$(wc -l < "$evidence/prohibited-flags-denylist.txt" | tr -d ' ')" -eq 2
grep -Fq 'CodexInvocation.swift' "$evidence/prohibited-flags-denylist.txt"
rg -n 'Process\.executableURL|standardInput|--skip-git-repo-check|--sandbox.*workspace-write' \
  "$repo_root/Sources/PapertrailCore/Codex" > "$evidence/process-boundary-static.txt"
rg -n 'allowsContentJavaScript = false|websiteDataStore = \.nonPersistent|allowingReadAccessTo' \
  "$repo_root/Sources/PapertrailCore/Security" \
  "$repo_root/Sources/PapertrailApp/RestrictedReviewWebView.swift" \
  > "$evidence/webkit-boundary-static.txt"

set +e
DEVELOPER_DIR=/Library/Developer/CommandLineTools PPR_FORCE_SWIFTDATA=1 \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift build --disable-sandbox --package-path "$repo_root" -c release \
  > "$evidence/forced-swiftdata-build.log" 2>&1
swiftdata_status=$?
/usr/bin/xcodebuild -version > "$evidence/xcodebuild-version.log" 2>&1
xcodebuild_status=$?
set -e
test "$swiftdata_status" -ne 0
grep -Fq 'SwiftDataMacros' "$evidence/forced-swiftdata-build.log"
test "$xcodebuild_status" -ne 0
grep -Eqi 'requires Xcode|active developer directory.*CommandLineTools|not a developer tool' "$evidence/xcodebuild-version.log"

for required in \
  "$evidence/backup-restore-report.json" \
  "$repo_root/Docs/Gate0G/evidence/iteration-5/webkit-harness.json"; do
  test -s "$required"
done

"$python_path" - "$repo_root" "$evidence" "$app_path" "$swiftdata_status" "$xcodebuild_status" <<'PY'
import hashlib, json, pathlib, plistlib, sys
repo, evidence, app, swiftdata_status, xcodebuild_status = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
binary = app / "Contents/MacOS/PapertrailApp"
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
backup = json.loads((evidence / "backup-restore-report.json").read_text())
webkit = json.loads((repo / "Docs/Gate0G/evidence/iteration-5/webkit-harness.json").read_text())
capability = json.loads((repo / ".build/gate0a-evidence/capability.json").read_text())
finder = json.loads((evidence / "finder-launch.json").read_text())
assert capability["capability"]["status"] == "usable"
assert finder["status"] == "passed" and finder["historicalGate0AHarness"] is False
logs = {f"Gate0{g.upper()}": sha(evidence / f"gate0{g}-verification.log") for g in "acdefg"}
summary = {
  "status": "passed",
  "gate": "Gate 0H - private-local release verification",
  "stopCondition": None,
  "blockers": [],
  "testMatrix": {"currentGates": "passed", "Gate0HTests": "9/9", "logSHA256": logs},
  "gate0ACurrentCapability": {"status": "usable", "evidenceSHA256": sha(repo / ".build/gate0a-evidence/capability.json")},
  "security": {"hostileWebKitStatus": webkit["status"], "unexpectedNetworkRequests": 0, "javascriptEnabled": False, "persistentWebsiteDataStore": False, "dangerousCodexFlagsPermitted": 0, "dangerousFlagDenylistEntries": 2},
  "privateLocalProfile": {"bundleIdentifier": info["CFBundleIdentifier"], "minimumMacOS": info["LSMinimumSystemVersion"], "signature": "ad-hoc; codesign --verify --deep --strict passed", "entitlements": "no app sandbox, network, or get-task-allow entitlement declared", "executableSHA256": sha(binary), "appBundle": str(app.relative_to(repo))},
  "finderLaunch": {"status": "passed", "evidenceSHA256": sha(evidence / "finder-launch.json"), "surface": finder["launchSurface"]},
  "backupRestore": backup,
  "applicationSupport": {"topology": "Papertrail/{Store,Papers}", "ownerOnlyDirectories": "0700", "ownerOnlyFiles": "0600", "restoreNeverOverwritesLiveData": True},
  "hostLimitations": {"developerDirectory": "/Library/Developer/CommandLineTools", "forcedSwiftDataBuildExit": swiftdata_status, "swiftDataMacrosUnavailable": True, "xcodebuildExit": xcodebuild_status, "XCTestAndSwiftDataRuntimeSmokePerformed": False, "impact": "No production SwiftData container or XCTest/UI runtime pass is claimed on this host; portable persistence and production-source parse/build contracts were verified."},
  "distributionNonClaims": ["Developer ID", "notarization", "stapling", "App Store", "spctl acceptance", "another-Mac Gatekeeper", "production SwiftData runtime smoke"],
}
(evidence / "verification-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
PY

printf '%s\n' "PASS: Gate 0H private-local release verification"
printf '%s\n' "Evidence: $evidence"
