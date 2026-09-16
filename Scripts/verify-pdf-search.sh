#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_root/.build/pdf-search-tests"
module_cache="$repo_root/.build/PDFSearchModuleCache"
mkdir -p "$build_dir" "$module_cache"

sed 's/^private struct PDFViewRepresentable/struct PDFViewRepresentable/' \
  "$repo_root/Sources/PapertrailApp/PDFDocumentView.swift" > "$build_dir/PDFDocumentView.swift"

CLANG_MODULE_CACHE_PATH="$module_cache" \
  /Library/Developer/CommandLineTools/usr/bin/swiftc \
  -module-cache-path "$module_cache" \
  -swift-version 6 \
  -target arm64-apple-macosx14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  "$build_dir/PDFDocumentView.swift" "$repo_root/Tests/PDFSearchTests.swift" \
  -o "$build_dir/PDFSearchTests"

"$build_dir/PDFSearchTests" "$@"
