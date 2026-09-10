#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
output_root="$repo_root/.build/gate0a-app"
app_path="$output_root/Gate0AHarness.app"
contents="$app_path/Contents"

swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" \
  --product Gate0AHarness
bin_path=$(swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" \
  --show-bin-path)

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_path/Gate0AHarness" "$contents/MacOS/Gate0AHarness"
cp "$repo_root/Sources/Gate0AHarness/Info.plist" "$contents/Info.plist"
chmod 755 "$contents/MacOS/Gate0AHarness"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
