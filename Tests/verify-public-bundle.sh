#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$project_root/build/CopyCo.app"
if [[ "$#" -gt 0 ]]; then app_bundle="$1"; fi

app_binary="$app_bundle/Contents/MacOS/CopyCo"
test -x "$app_binary"

if grep -aFq "$project_root" "$app_binary"; then
    printf '%s\n' "Error: packaged binary exposes the local project path." >&2
    exit 1
fi

codesign_details="$(codesign -dv --verbose=4 "$app_bundle" 2>&1)"
if [[ -z "${COPYCO_SIGNING_IDENTITY:-}" ]] && grep -q '^Authority=' <<< "$codesign_details"; then
    printf '%s\n' "Error: packaged app exposes a code-signing identity." >&2
    exit 1
fi

printf '%s\n' "verified public bundle privacy"
