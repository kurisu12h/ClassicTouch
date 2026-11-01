#!/bin/bash
# M2 性能：在 iOS 模拟器里跑一次滑动测试（App 的 -autodrive -swipetest，见 EmulatorViewController.swipeLock/swipeHome）。
# 和 sim-boot.sh 一样重置设备状态，带 -perf（IT_PERF=1）开机，App 自己认锁屏、做锁屏段、解锁、做主屏段、待机后退出；
# 这里只等它退出，把运行目录拷到 work/ios/runs/sim/，再用 summarize-swipe.py 汇总。
# 注意：模拟器的 OpenGLES 是 CPU 上的软件渲染，GL 的耗时和手机 GPU 完全不同，这里只验证功能和测法。
# 用法：scripts/ios/sim-swipe.sh <设备id> [最长秒数，默认 400]
# 环境变量：QEMUENV="A=1 B=2"（给 QEMU 的额外环境变量）
set -euo pipefail
DEVICE="${1:?用法：sim-swipe.sh <设备id> [最长秒数]}"
LIMIT="${2:-400}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
UDID="${SIM_UDID:-$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name=="ClassicTouch iPhone 18 Pro") | .udid' | head -1)}"
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
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 5 -autodrive YES -swipetest YES \
    -perf YES -idle 40 ${QEMUENV:+-qemuenv "$QEMUENV"} >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-jit\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "App 没有建运行目录" >&2; exit 1; }
echo "运行目录：$R"
t0=$(date +%s)
until grep -q 'qemu_exit\|boot_failed' "$R/events.log" 2>/dev/null; do
    if [ $(($(date +%s) - t0)) -ge "$LIMIT" ]; then
        echo "到了 $LIMIT 秒还没退出，发 quit"
        echo "quit $(date +%s)" > "$C/Documents/control/quit"
        sleep 5
        break
    fi
    sleep 2
done
mkdir -p "$ROOT/work/ios/runs/sim"
cp -R "$R" "$ROOT/work/ios/runs/sim/"
L="$ROOT/work/ios/runs/sim/$(basename "$R")"
grep -E "lock_seen|home_seen|swipe_unlock|seg |auto_quit|qemu_exit" "$L/events.log"
python3 -I "$ROOT/scripts/ios/summarize-swipe.py" "$L"
