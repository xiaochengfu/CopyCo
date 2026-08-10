#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$project_root/build/CopyCo.app"
if [[ "$#" -gt 0 ]]; then app_bundle="$1"; fi

test -f "$app_bundle/Contents/Resources/CopyCo.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_bundle/Contents/Info.plist")" = "CopyCo.icns"
test ! -e "$app_bundle/Contents/Resources/CopyCo-AppLogo-1024.png"
if find "$app_bundle/Contents/Resources" -name '*.iconset' -print -quit | grep -q .; then
    exit 1
fi

icon_size="$(stat -f '%z' "$app_bundle/Contents/Resources/CopyCo.icns")"
test "$icon_size" -gt 0
printf 'verified app icon: %s bytes\n' "$icon_size"
