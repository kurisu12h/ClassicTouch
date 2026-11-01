#!/bin/bash
# 第二阶段第 5 项：iPod touch 2 代用占位 SecureROM 时的长待机测试，在第二台模拟器「ClassicTouch Standby」里跑，
# 不占手机，也不和 sim-boot.sh 抢同一台模拟器。
#   1. 冷启动 n72ap-7E18（JIT，模拟器里不用调试器），开本机 TCP 的 QMP 口取证。
#   2. OCR 看到锁屏后完全不碰，每 60 秒记一次：CPU%、背光、帧编号，以及 QMP 里 CPU 的 PC 和状态。
#      占位 bootrom 在地址 0 上是一条「b .」：唤醒若走了 bootrom，PC 会停在 0 附近原地打转、CPU 满载、没有新帧。
#   3. 待机 STANDBY 分钟（默认 35）后按 Home，30 秒后再看；再滑动解锁，看能否回到主屏。
# 用法：scripts/ios/sim-standby.sh   结果：work/ios/runs/standby-<运行目录名>.log
set -euo pipefail
STANDBY="${STANDBY:-35}"
PORT="${PORT:-4455}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
DEVICE=n72ap-7E18
OCR="$ROOT/work/tools/ocr/ocr"
QMP="python3 -I $ROOT/scripts/ios/qmp.py 127.0.0.1:$PORT"
UDID="$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name=="ClassicTouch Standby") | .udid' | head -1)"
C="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
D="$C/Documents/devices/$DEVICE"

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
rm -rf "$D/state" "$C/Documents/control"
mkdir -p "$C/Documents/control"
before="$(ls "$C/Documents/logs" 2>/dev/null || true)"
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 10 \
    -qemuargs "-qmp tcp:127.0.0.1:$PORT,server=on,wait=off" >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "App 没有建运行目录" >&2; exit 1; }
OUT="$ROOT/work/ios/runs/standby-$(basename "$R").log"
mkdir -p "$ROOT/work/ios/runs"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT"; }
probe() {   # 一行：App 时间、CPU%、背光、帧编号、PC、CPU 状态
    local stat pc cpus
    stat="$(tail -1 "$R/stats.csv")"
    pc="$($QMP hmp 'info registers' 2>/dev/null | grep -o 'R15=[0-9a-f]*' | head -1 || true)"
    cpus="$($QMP hmp 'info cpus' 2>/dev/null | tr -s ' \r\n' ' ' || true)"
    say "stats[$stat] $pc cpus[$cpus]"
}
say "运行目录 $R，待机 $STANDBY 分钟"

lock=""
for _ in $(seq 120); do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        if "$OCR" "$R/$f" 2>/dev/null | jq -r .text | grep -qi 'slide to unlock'; then lock="$f"; break; fi
    done
    [ -n "$lock" ] && break
    sleep 2
done
[ -n "$lock" ] || { say "没等到锁屏"; exit 1; }
say "锁屏：$lock，开始待机，不碰"

end=$(($(date +%s) + STANDBY * 60))
while [ "$(date +%s)" -lt "$end" ]; do
    probe
    sleep 60
done

say "按 Home"
touch "$C/Documents/control/home"
for _ in 1 2 3; do sleep 10; probe; done
say "滑动解锁"
touch "$C/Documents/control/unlock"
sleep 30
probe
last="$(ls "$R" | grep '^guest-' | sort | tail -1)"
say "最后一张客体截图 $last：$("$OCR" "$R/$last" 2>/dev/null | jq -r .text | tr '\n' '|')"
cp "$R/$last" "$ROOT/work/ios/runs/standby-last-guest.png"
say "事件：$(tr '\n' ';' < "$R/events.log")"
