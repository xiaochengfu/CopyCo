#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$project_root/build/CopyCo.app"

"$project_root/scripts/build-app.sh"
open "$app_bundle"

cat <<'CHECKLIST'

CopyCo is running. First-run checklist:
  1. Open the CopyCo menu-bar item, then Settings.
  2. Select “Open Accessibility Settings”, enable CopyCo, then refresh permission status.
  3. Copy text in TextEdit, press Option-Command-C, and select the entry with Return.
  4. Confirm the text is pasted into the previously active app.
  5. Verify the menu works as a fallback if Option-Command-C is unavailable.

Stored history lives at ~/Library/Application Support/CopyCo/History.
CHECKLIST
