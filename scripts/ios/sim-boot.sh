#!/bin/bash
# E0：在 iOS 模拟器里冷启动一台设备并计时。
#   1. 重置设备状态：删掉 App 容器里的 state/；work/ios/devices/<id>-golden/state 存在时（3GS 是 M0 走完设置向导的
#      状态）克隆它，否则 App 第一次启动时从设备本体克隆。
#   2. 启动 App：-device <id> -tcg <后端> -guestpng 1（每秒存一张客体画面）。
#   3. 逐张 OCR（M0 的 work/tools/ocr/ocr，Vision 文字识别）：第一次看到「slide to unlock」记为到锁屏，
#      立刻经 Documents/control/unlock 让 App 按 Home 再滑动；之后看到主屏图标名（Settings、Safari……）记为到主屏，
#      再空闲 IDLE 秒（默认 20）量主屏待机的 CPU，最后 control/quit 让 QEMU 正常退出。没出锁屏就直接认出三个以上
#      主屏图标名的，也记为到主屏（锁屏记「未到达」）。
#   4. 汇总：锁屏、主屏时间，这期间的 CPU 秒和平均 CPU%（占一个核），footprint，主屏待机 CPU%。
# 时间都是 App 里从调 qemu_ios_main 起算的墙钟秒（stats.csv、guest-NNNN.png 的编号）。
#
# 用法：scripts/ios/sim-boot.sh <设备id> interp|jit [最长秒数，默认 900]
# 环境变量：IDLE（主屏待机秒数，默认 20）、TBSIZE（TCG 代码缓冲 MB，不设就用 App 的默认 256）、
#          USBKBD=1（有 USB 主机口的机型挂 USB 键盘，默认不挂）
# 结果：App 容器里 Documents/logs/<时间>-<设备>-<后端>/，摘要另存 work/ios/runs/<同名>.summary
set -euo pipefail
DEVICE="${1:?用法：sim-boot.sh <设备id> interp|jit [最长秒数]}"
TCG="${2:?}"
LIMIT="${3:-900}"
IDLE="${IDLE:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
OCR="$ROOT/work/tools/ocr/ocr"
UDID="${SIM_UDID:-$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name=="ClassicTouch iPhone 18 Pro") | .udid' | head -1)}"
[ -n "$UDID" ] || { echo "没有 ClassicTouch iPhone 18 Pro 模拟器" >&2; exit 1; }
C="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
D="$C/Documents/devices/$DEVICE"
[ -f "$D/device.lock.json" ] || { echo "App 容器里没有设备 $DEVICE" >&2; exit 1; }

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
rm -rf "$D/state" "$C/Documents/control"
mkdir -p "$C/Documents/control"
if [ -d "$ROOT/work/ios/devices/$DEVICE-golden/state" ]; then
    cp -c -R "$ROOT/work/ios/devices/$DEVICE-golden/state" "$D/state"
fi
before="$(ls "$C/Documents/logs" 2>/dev/null || true)"
extra=()
if [ -n "${TBSIZE:-}" ]; then extra+=(-tbsize "$TBSIZE"); fi
if [ "${USBKBD:-0}" = 1 ]; then extra+=(-usbkbd YES); fi
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg "$TCG" -guestpng 1 ${extra[@]+"${extra[@]}"} >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-$TCG\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "App 没有建运行目录" >&2; exit 1; }
echo "运行目录：$R"

lock="" home="" seen="" quit_at=""
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        case " $seen " in *" $f "*) continue ;; esac
        seen="$seen $f"
        t=$((10#$(echo "$f" | tr -dc 0-9)))
        text="$("$OCR" "$R/$f" 2>/dev/null | jq -r .text | tr '\n' '|')"
        # iOS 9 的「slide to unlock」带流光，OCR 常读成「crae to unlotk」之类，所以也认「to unl」
        if [ -z "$lock" ] && grep -Eqi 'slide to unlock|to unl' <<<"$text"; then
            lock=$t
            echo "锁屏：$t 秒"
            touch "$C/Documents/control/unlock"
        elif [ -n "$lock" ] && [ -z "$home" ] && ! grep -Eqi 'slide to|to unl' <<<"$text" \
            && grep -Eq 'Settings|Safari|App Store|Calendar|Photos' <<<"$text"; then
            home=$t
            echo "主屏：$t 秒"
            quit_at=$(($(date +%s) + IDLE))
        elif [ -z "$lock" ] && [ -z "$home" ] && ! grep -qi 'slide to' <<<"$text" \
            && [ "$(grep -Eo 'Settings|Safari|Calendar|Photos|Stocks|Maps|Mail|Phone|Notes' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            # iPhone OS 1.0、2.x 有时不经过锁屏直接到主屏（从黄金状态冷启动的 1.0、激活后第一次开机的 2.x）
            home=$t
            echo "主屏（没经过锁屏）：$t 秒"
            quit_at=$(($(date +%s) + IDLE))
        fi
    done
    if [ -n "$lock" ] && [ -z "$home" ] && [ -z "$(ls "$C/Documents/control")" ]; then
        # 解锁可能没成（屏还没亮就滑了），每 20 秒再来一次
        last=$(grep -c 'control unlock' "$R/events.log" || true)
        if [ $(($(date +%s) - $(stat -f %m "$R/events.log"))) -ge 20 ] && [ "$last" -lt 8 ]; then
            touch "$C/Documents/control/unlock"
        fi
    fi
    if [ -n "$quit_at" ] && [ "$(date +%s)" -ge "$quit_at" ]; then
        touch "$C/Documents/control/quit"
        sleep 3
        break
    fi
    grep -q 'qemu_exit\|boot_failed' "$R/events.log" && break
    sleep 1
done

mkdir -p "$ROOT/work/ios/runs"
SUMMARY="$ROOT/work/ios/runs/$(basename "$R").summary"
python3 -I "$ROOT/scripts/ios/summarize-run.py" "$R" "${lock:-}" "${home:-}" "$IDLE" > "$SUMMARY"
cat "$SUMMARY"
cat "$R/events.log"
