#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
evidence="$repo_root/Docs/Gate0F/evidence"
mkdir -p "$module_cache" "$evidence"

for target in Gate0ATests Gate0CTests Gate0DTests Gate0ETests Gate0FTests; do
  log="$evidence/$target.log"
  if ! SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
    swift run --disable-sandbox --package-path "$repo_root" "$target" > "$log" 2>&1
  then
    cat "$log"
    exit 1
  fi
  cat "$log"
done

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift build --disable-sandbox --package-path "$repo_root" -c release
xcrun swiftc -frontend -parse \
  "$repo_root/Sources/PapertrailCore/Models/SchemaV1.swift" \
  "$repo_root/Sources/PapertrailCore/Review/ReviewStateMachine.swift" \
  "$repo_root/Sources/PapertrailCore/Review/SwiftDataReviewGenerationStore.swift" \
  > "$evidence/swiftdata-parse.log" 2>&1
"$repo_root/Scripts/build-gate0e-app.sh" > "$evidence/app-path.txt"
/usr/bin/codesign --verify --deep --strict "$repo_root/.build/gate0e-app/Papertrail.app"

find "$repo_root/Sources/PapertrailCore/Review" -type l -print > "$evidence/symlinks.txt"
test ! -s "$evidence/symlinks.txt"
"$repo_root/Scripts/generate-gate0f-summary.sh" \
  "$repo_root" "$evidence/verification-summary.json"
printf '%s\n' "PASS: Gate 0F automatic review pipeline"
