#!/bin/zsh
# 把 mockups/ 里的样稿用无头 Chrome 截成 PNG，放到 docs/reports/img/ui-*.png。
# 手机屏按 402 × 874 pt、3 倍出图（1206 × 2622，和 iPhone 18 Pro 截图一样大）；总览图按 2 倍。
# 用法：docs/design/render.sh [名字…]，不带参数就全部重出。名字如 a-home、overview。
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
  if [[ $n == overview ]]; then size=1500,2060; scale=2; else size=402,874; scale=3; fi
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$profile" \
    --force-device-scale-factor=$scale --window-size=$size --virtual-time-budget=1500 \
    --allow-file-access-from-files --screenshot="$out/ui-$n.png" "file://$here/mockups/$n.html" 2>/dev/null
  echo "ui-$n.png"
done
