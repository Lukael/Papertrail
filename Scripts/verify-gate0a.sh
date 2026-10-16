#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
evidence_root="$repo_root/.build/gate0a-evidence"
claude_path=${CLAUDE_PATH:-$(command -v claude)}

case "$claude_path" in
  /*) ;;
  *) printf '%s\n' "FAIL: CLAUDE_PATH must resolve to one absolute executable" >&2; exit 1 ;;
esac
test -x "$claude_path"

mkdir -p "$module_cache" "$evidence_root"
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift run --disable-sandbox --package-path "$repo_root" Gate0ATests

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  "$repo_root/Scripts/build-gate0a-app.sh"

app_path="$repo_root/.build/gate0a-app/Gate0AHarness.app"
/usr/bin/codesign --verify --deep --strict "$app_path"
"$app_path/Contents/MacOS/Gate0AHarness" \
  --claude "$claude_path" \
  --workspace "$evidence_root" \
  --output "$evidence_root/capability.json"
grep -Fq '"status" : "usable"' "$evidence_root/capability.json"
reported_claude=$(/usr/bin/plutil -extract capability.executablePath raw \
  "$evidence_root/capability.json")
test "$reported_claude" = "$claude_path"

printf '%s\n' "PASS: Gate 0A reproducible local verification"
printf '%s\n' "Exact Claude Code executable: $claude_path"
printf '%s\n' "Current derived evidence: $evidence_root/capability.json"
