#!/bin/bash
# M2：在 iOS 模拟器里验证 App 进后台时不再调宿主 GL、回到前台后客体照常出画面。
#   1. 和 sim-boot.sh 一样重置设备状态，带 -autodrive 启动（App 自己认锁屏、解锁、认主屏），待机设得很长，不让它自己退出；
#   2. 认出主屏后再等 WAIT 秒，打开系统的「设置」App，把我们的 App 送到后台，停 AWAY 秒；
#   3. 再用 simctl launch 把 App 叫回前台（App 还在跑时不会重启），等 WAIT 秒，存一张客体截图；
#   4. 让 QEMU 退出，打出 qemu.log 里前后台的记录（gles_host_set_allowed：「foreground again: N GL calls refused
#      while away」）、帧编号在各段的变化，和 backboardd、SpringBoard 有没有重启。
# 用法：scripts/ios/sim-background.sh <设备id> [AWAY 秒，默认 15]
# 结果：App 容器里 Documents/logs/<时间>-<设备>-jit/，摘要打在标准输出。
set -euo pipefail
DEVICE="${1:?用法：sim-background.sh <设备id> [AWAY]}"
AWAY="${2:-15}"
WAIT="${WAIT:-10}"
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
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 5 -autodrive YES -idle 3600 >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-jit\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "App 没有建运行目录" >&2; exit 1; }
echo "运行目录：$R"
t0=$(date +%s)
until grep -q home_seen "$R/events.log" 2>/dev/null; do
    [ $(($(date +%s) - t0)) -lt 300 ] || { echo "300 秒没到主屏" >&2; exit 1; }
    sleep 1
done
sleep "$WAIT"
wall() { tail -1 "$R/stats.csv" | cut -d, -f1; }
frame() { tail -1 "$R/stats.csv" | cut -d, -f6; }
echo "进后台前：第 $(wall) 秒，帧编号 $(frame)"
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
sleep "$AWAY"
echo "后台 $AWAY 秒后：第 $(wall) 秒，帧编号 $(frame)"
pid_before="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v b="$BUNDLE" '$3 ~ b {print $1}' | head -1)"
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep "$WAIT"
echo "回前台 $WAIT 秒后：第 $(wall) 秒，帧编号 $(frame)；App 进程 $pid_before（回前台前）"
n_runs="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" | sort) | grep -c -- "-$DEVICE-jit\$" || true)"
[ "$n_runs" = 1 ] || echo "注意：回前台时 App 重新启动了（新运行目录 $n_runs 个）"
last="$(ls "$R" | grep '^guest-' | sort | tail -1)"
echo "最后一张客体截图：$R/$last"
echo "quit $(date +%s)" > "$C/Documents/control/quit"
for _ in $(seq 30); do grep -q qemu_exit "$R/events.log" && break; sleep 1; done
echo "--- events.log"
cat "$R/events.log"
echo "--- qemu.log 里前后台和拒绝的记录"
grep -E "foreground|still running|refus" "$R/qemu.log" || echo "（没有）"
echo "--- 串口里 backboardd、SpringBoard 的进程号"
grep -oE "(backboardd|SpringBoard)\[[0-9]+" "$R/serial-0.log" | sort -u
