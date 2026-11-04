#!/bin/bash
# 在 iOS 模拟器的 App 里开一台设备，到锁屏后解锁，到主屏后点开「设置」，截图后让 QEMU 正常退出。
# 和 sim-boot.sh 一样靠 OCR（work/tools/ocr/ocr）认锁屏、主屏和「设置」；解锁、点按走 App 的控制通道
# （Documents/control/unlock、tap，见 EmulatorViewController.pollControl），不需要模拟器的点屏工具。
#
# 用法：scripts/ios/sim-settings.sh <设备id> <「设置」图标的归一化坐标 x,y> [最长秒数，默认 400]
#   iPod touch 5 代：点按落点比瞄准点偏上约 100 像素（docs/reports/a5-app.md 2.1），坐标要往下多瞄这么多，
#   9.3.5 主屏的「设置」在 (244,830)，所以传 0.381,0.819。主屏有时会先弹 lockdownd 的「Trust This Computer?」
#   （模态，挡住点按），认出来就先点它的「Don't Trust」（同样往下多瞄：TRUST_TAP，默认 0.711,0.691）。
# 环境变量：SIM_UDID（默认 work/ios/sim-udid）。结果：App 的运行目录拷到 work/ios/runs/<运行目录名>/。
set -euo pipefail
DEVICE="${1:?用法：sim-settings.sh <设备id> <x,y> [最长秒数]}"
TAP="${2:?}"
LIMIT="${3:-400}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
OCR="$ROOT/work/tools/ocr/ocr"
UDID="${SIM_UDID:-$(cat "$ROOT/work/ios/sim-udid")}"
C="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
[ -f "$C/Documents/devices/$DEVICE/device.lock.json" ] || { echo "App 容器里没有设备 $DEVICE" >&2; exit 1; }

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
rm -rf "$C/Documents/control"
mkdir -p "$C/Documents/control"
before="$(ls "$C/Documents/logs" 2>/dev/null || true)"
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 1 >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-jit\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "App 没有建运行目录" >&2; exit 1; }
echo "运行目录：$R"

TRUST_TAP="${TRUST_TAP:-0.711,0.691}"
lock="" home="" tapped="" settings="" seen="" last_try=0 trust=""
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ] && [ -z "$settings" ]; do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        case " $seen " in *" $f "*) continue ;; esac
        seen="$seen $f"
        t=$((10#$(echo "$f" | tr -dc 0-9)))
        text="$("$OCR" "$R/$f" 2>/dev/null | jq -r .text | tr '\n' '|')"
        if grep -qi 'Trust This Computer' <<<"$text"; then
            trust=$t
        elif [ -z "$home" ] && grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text"; then   # iOS 10: "Press home to open" or the date line
            [ -n "$lock" ] || { lock=$t; echo "锁屏：$t 秒"; }
        elif [ -z "$home" ] && [ "$(grep -Eo 'Settings|Safari|Calendar|Photos|Clock|Maps|Mail|Notes' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            home=$t
            echo "主屏：$t 秒"
        elif [ -n "$tapped" ] && [ "$(grep -Eo 'Airplane Mode|Wi-Fi|Bluetooth|Notifications|Control Center|Do Not Disturb|General' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            settings=$t
            echo "「设置」：$t 秒（$f）"
        fi
    done
    now=$(date +%s)
    if [ -n "$lock" ] && [ -z "$home" ] && [ $((now - last_try)) -ge 20 ]; then
        touch "$C/Documents/control/unlock"
        last_try=$now
    fi
    if [ -n "$trust" ]; then
        echo "「Trust This Computer?」：$trust 秒，点 Don't Trust"
        echo "$TRUST_TAP $now" > "$C/Documents/control/tap"
        trust=""
        last_try=$now
    elif [ -n "$home" ] && [ -z "$settings" ] && [ $((now - last_try)) -ge 15 ]; then
        echo "$TAP $now" > "$C/Documents/control/tap"
        tapped=1
        last_try=$now
    fi
    sleep 1
done
sleep 3
touch "$C/Documents/control/quit"
for _ in $(seq 20); do grep -q 'qemu_exit' "$R/events.log" && break; sleep 1; done
mkdir -p "$ROOT/work/ios/runs/$(basename "$R")"
cp -c -R "$R/." "$ROOT/work/ios/runs/$(basename "$R")/"
cat "$R/events.log"
[ -n "$settings" ]
