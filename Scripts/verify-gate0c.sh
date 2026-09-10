#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
mkdir -p "$module_cache"

SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  swift run --disable-sandbox --package-path "$repo_root" Gate0CTests
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" CLANG_MODULE_CACHE_PATH="$module_cache" \
  "$repo_root/Scripts/build-gate0c-app.sh"
/usr/bin/codesign --verify --deep --strict "$repo_root/.build/gate0c-app/Papertrail.app"
printf '%s\n' "PASS: Gate 0C app foundation and durable schema"
