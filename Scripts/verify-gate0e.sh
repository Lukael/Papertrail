#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
evidence="$repo_root/Docs/Gate0E/evidence"
codex_path=${CODEX_PATH:-$(command -v codex)}
mkdir -p "$module_cache" "$evidence"

for target in Gate0ATests Gate0CTests Gate0DTests Gate0ETests; do
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
    swift run --disable-sandbox --package-path "$repo_root" "$target"
done

if [ "${GATE0E_SKIP_LIVE:-0}" != "1" ]; then
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
    swift run --disable-sandbox --package-path "$repo_root" Gate0EHarness \
      --codex "$codex_path" --workspace "$repo_root" --output "$evidence/live-codex.json"
fi

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  "$repo_root/Scripts/build-gate0e-app.sh"
/usr/bin/codesign --verify --deep --strict "$repo_root/.build/gate0e-app/Papertrail.app"
printf '%s\n' "PASS: Gate 0E paper-scoped Codex chat"
