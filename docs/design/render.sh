#!/bin/zsh
# Screenshot the mockups in mockups/ to PNG with headless Chrome, into docs/reports/img/ui-*.png.
# Phone screens are rendered at 402 × 874 pt, 3x (1206 × 2622, the same size as an iPhone 18 Pro screenshot); the overview at 2x.
# Usage: docs/design/render.sh [name…]; with no arguments, regenerates all of them. Names are like a-home, overview.
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
here=${0:A:h}
out=${here:h}/reports/img
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
profile=${TMPDIR:-/tmp}/classic-touch-mockup-chrome
mkdir -p "$out" "$profile"

names=("$@")
(( ${#names} )) || names=(a-home a-run b-home b-run c-home c-run overview)

for n in $names; do
  if [[ $n == overview ]]; then size=1260,2110; scale=2; else size=402,874; scale=3; fi
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$profile" \
    --force-device-scale-factor=$scale --window-size=$size --virtual-time-budget=1500 \
    --allow-file-access-from-files --screenshot="$out/ui-$n.png" "file://$here/mockups/$n.html" 2>/dev/null
  echo "ui-$n.png"
done
