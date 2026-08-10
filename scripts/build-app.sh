#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$project_root/build/CopyCo.app"
contents_dir="$app_bundle/Contents"

cd "$project_root"
swift build -c release -Xswiftc -gnone

rm -rf "$app_bundle"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp ".build/release/CopyCo" "$contents_dir/MacOS/CopyCo"
cp "Resources/Info.plist" "$contents_dir/Info.plist"
if [[ ! -f "Resources/CopyCo.icns" ]]; then
    printf '%s\n' "Error: Resources/CopyCo.icns is missing." >&2
    exit 1
fi
cp "Resources/CopyCo.icns" "$contents_dir/Resources/CopyCo.icns"

signing_identity="${COPYCO_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --timestamp=none "$app_bundle"
if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' "Created an ad-hoc signed local build." >&2
else
    printf '%s\n' "Signed with the explicitly configured identity." >&2
fi
"$project_root/Tests/verify-public-bundle.sh" "$app_bundle"

printf '%s\n' "$app_bundle"
