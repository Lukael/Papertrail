#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache="$repo_root/.build/ModuleCache"
output_root="$repo_root"
app_path="$output_root/Papertrail.app"
staging_app="$output_root/.Papertrail.app.building"
contents="$staging_app/Contents"
configuration=${CONFIGURATION:-release}

if test -d /Applications/Xcode.app/Contents/Developer; then
  DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
  export DEVELOPER_DIR
fi
PPR_FORCE_SWIFTDATA=1
export PPR_FORCE_SWIFTDATA

rm -rf "$staging_app"
mkdir -p "$module_cache" "$contents/MacOS" "$contents/Resources"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" --product PapertrailApp
bin_path=$(swift build --disable-sandbox --package-path "$repo_root" -c "$configuration" --show-bin-path)
cp "$bin_path/PapertrailApp" "$contents/MacOS/PapertrailApp"
cp -R "$bin_path/Papertrail_PapertrailCore.bundle" "$contents/Resources/"
cp "$repo_root/Sources/PapertrailApp/Info.plist" "$contents/Info.plist"
cp "$repo_root/Sources/PapertrailApp/Resources/Papertrail.icns" "$contents/Resources/Papertrail.icns"
chmod 755 "$contents/MacOS/PapertrailApp"
find "$contents/Resources" -type d -exec chmod 755 {} +
find "$contents/Resources" -type f -exec chmod 644 {} +
/usr/bin/codesign --force --deep --sign - "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"
rm -rf "$app_path"
mv "$staging_app" "$app_path"
printf '%s\n' "$app_path"
