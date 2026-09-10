#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
output_root="$repo_root/.build/gate0c-app"
app_path="$output_root/Papertrail.app"
contents="$app_path/Contents"

swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" --product PapertrailApp
bin_path=$(swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" --show-bin-path)

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_path/PapertrailApp" "$contents/MacOS/PapertrailApp"
rm -rf "$contents/Resources/Papertrail_PapertrailCore.bundle"
cp -R "$bin_path/Papertrail_PapertrailCore.bundle" "$contents/Resources/"
cp "$repo_root/Sources/PapertrailApp/Info.plist" "$contents/Info.plist"
cp "$repo_root/Sources/PapertrailApp/Resources/Papertrail.icns" "$contents/Resources/Papertrail.icns"
chmod 755 "$contents/MacOS/PapertrailApp"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
