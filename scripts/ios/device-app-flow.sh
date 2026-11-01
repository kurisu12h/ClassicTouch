#!/bin/bash
# M2 App 雏形：在真机上把真实用户的流程串一遍（不用 autodrive，App 里没有任何测试开关）：
#   1. 结束 App，带 -select <第一台> 打开，相当于用户在列表里点了它。App 没有 JIT，记下要开的那台、打开 stikjit://、
#      自己退出；StikDebug 挂着调试器拉起新进程，新进程直接用 JIT 开机。
#   2. 到锁屏后经 Documents/control/unlock 解锁，等 devicectl 截图里认出主屏。
#   3. 后台测试：devicectl 把系统「设置」切到前台，停 AWAY 秒（默认 15），再把本 App 切回前台；
#      核对进程号没变、运行目录没变、events.log 有 vm_pause reason=background 和 vm_resume、回来后帧编号还在涨。
#   4. 换系统：往 control/select 写第二台，App 让 QEMU 正常退出后再走一次 StikDebug，新进程开第二台；解锁到主屏。
#   5. control/quit，结束 App。
# 每一步存一张 devicectl 截图（手机全屏）到 work/ios/runs/device/flow-<时间>/。
#
# 用法：scripts/ios/device-app-flow.sh [第一台，默认 n88ap-10B500] [第二台，默认 n90ap-11D257]
# 环境变量：PHONE（默认读 work/ios/phone-udid）、AWAY（默认 15）、SKIP_SWITCH=1（不做第 4 步）
# 前提：手机解锁、插线（文件走 AFC）、LocalDevVPN 开着、装着 StikDebug（org.classictouch.dev.stikdebug）。
set -euo pipefail
FIRST="${1:-n88ap-10B500}"
SECOND="${2:-n90ap-11D257}"
AWAY="${AWAY:-15}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # 手机 UDID 放在 work/ios/phone-udid，不进仓库
BUNDLE=org.classictouch.app
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
OCR="$ROOT/work/tools/ocr/ocr"
OUT="$ROOT/work/ios/runs/device/flow-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
T0=$(date +%s)
say() { echo "[$(($(date +%s) - T0)) 秒] $*" | tee -a "$OUT/flow.log"; }

afc() { { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; } || true; }
fetch() {
    if "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download "$1" "$2.part" >/dev/null 2>&1; then mv "$2.part" "$2"; else rm -f "$2.part"; fi
}
runs() { afc list /Documents/logs | grep -o '"20[0-9-]*-[^"]*"' | tr -d '"' || true; }
control() {   # 命令 [内容]：每次写不同的内容，免得被当成没变过的文件跳过
    local f
    f="$(mktemp)"
    echo "${2:-} $(date +%s) $RANDOM" > "$f"
    afc mkdir /Documents/control >/dev/null
    afc upload "$f" "/Documents/control/$1" >/dev/null
    rm -f "$f"
}
app_pids() {
    xcrun devicectl device info processes --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.runningProcesses[] | select((.executable // "") | contains("ClassicTouch.app")) | .processIdentifier'
}
shot() {   # 名字：存一张手机全屏截图，返回 OCR 出的文字（竖线分隔）
    xcrun devicectl device capture screenshot --device "$PHONE" --destination "$OUT/$1.png" --quiet >/dev/null 2>&1 || true
    [ -f "$OUT/$1.png" ] && "$OCR" "$OUT/$1.png" 2>/dev/null | jq -r .text | tr '\n' '|' || true
}
is_home() { ! grep -qi 'slide to' <<<"$1" && grep -Eq 'Safari|App Store|Calendar|Photos|Messages|Weather|Clock' <<<"$1"; }

# 等某台设备的新运行目录出现，打印目录名
wait_run() {
    local dev="$1" before="$2" new
    for _ in $(seq 90); do
        new="$(comm -13 <(echo "$before" | sort) <(runs | sort) | grep -- "-$dev-" | tail -1 || true)"
        [ -n "$new" ] && { echo "$new"; return; }
        sleep 1
    done
}

# 开机后解锁到主屏：每 15 秒发一次 unlock（锁屏几秒就熄屏，unlock 先按 Home 叫醒），最多 8 次
boot_to_home() {
    local name="$1" text
    for i in $(seq 8); do
        sleep 15
        text="$(shot "$name-try$i")"
        if is_home "$text"; then
            say "$name：第 $i 次查看时已在主屏"
            cp "$OUT/$name-try$i.png" "$OUT/$name-home.png"
            return 0
        fi
        control unlock
    done
    say "$name：120 秒内没认出主屏"
    return 1
}

say "1. 结束 App，带 -select $FIRST 打开（相当于用户点了它）"
for p in $(app_pids); do xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true; done
afc remove /Documents/autostart.json >/dev/null
before="$(runs)"
first_pid="$(xcrun devicectl device process launch --device "$PHONE" --activate --json-output /dev/stdout --quiet "$BUNDLE" -- -select "$FIRST" \
    | jq -r '.result.process.processIdentifier')"
say "列表进程 PID $first_pid"
R1="$(wait_run "$FIRST" "$before")"
[ -n "$R1" ] || { say "90 秒没等到 $FIRST 的运行目录（StikDebug 没拉起？）"; exit 1; }
pid1="$(app_pids | head -1)"
fetch "/Documents/logs/$R1/events.log" "$OUT/events-1.log"
say "运行目录 $R1，开机进程 PID $pid1：$(head -1 "$OUT/events-1.log" | grep -o 'backend=[a-z]* .*debugger=[a-z]*' || true)"
boot_to_home first || true

say "3. 后台测试：系统「设置」切到前台 $AWAY 秒"
fetch "/Documents/logs/$R1/stats.csv" "$OUT/stats-before.csv"
before_frame="$(tail -1 "$OUT/stats-before.csv" | cut -d, -f1,6)"
xcrun devicectl device process launch --device "$PHONE" --activate --quiet com.apple.Preferences >/dev/null
sleep 3
shot away >/dev/null
sleep $((AWAY - 3))
pid_away="$(app_pids | head -1)"
xcrun devicectl device process launch --device "$PHONE" --activate --quiet "$BUNDLE" >/dev/null
sleep 10
pid_back="$(app_pids | head -1)"
text="$(shot back)"
fetch "/Documents/logs/$R1/events.log" "$OUT/events-1.log"
fetch "/Documents/logs/$R1/stats.csv" "$OUT/stats-after.csv"
after_frame="$(tail -1 "$OUT/stats-after.csv" | cut -d, -f1,6)"
n_runs="$(comm -13 <(echo "$before" | sort) <(runs | sort) | grep -c -- "-$FIRST-" || true)"
say "进程号：后台前 $pid1，后台中 $pid_away，回来后 $pid_back；$FIRST 的运行目录 $n_runs 个"
say "后台前 秒,帧 $before_frame；回来 10 秒后 $after_frame；回来后画面$(is_home "$text" && echo 是主屏 || echo 不是主屏)"
grep -E 'vm_pause|vm_resume' "$OUT/events-1.log" | tail -4 | sed 's/^/  /' | tee -a "$OUT/flow.log"
sleep 5
fetch "/Documents/logs/$R1/stats.csv" "$OUT/stats-after.csv"
say "再过 5 秒：$(tail -1 "$OUT/stats-after.csv" | cut -d, -f1,6)"

if [ "${SKIP_SWITCH:-0}" != 1 ]; then
    say "4. 换系统：control/select $SECOND"
    before="$(runs)"
    control select "$SECOND"
    R2="$(wait_run "$SECOND" "$before")"
    [ -n "$R2" ] || { say "90 秒没等到 $SECOND 的运行目录"; exit 1; }
    pid2="$(app_pids | head -1)"
    fetch "/Documents/logs/$R1/events.log" "$OUT/events-1.log"
    fetch "/Documents/logs/$R2/events.log" "$OUT/events-2.log"
    say "旧运行最后几行：$(tail -2 "$OUT/events-1.log" | tr '\n' ' ')"
    say "运行目录 $R2，新进程 PID $pid2：$(head -1 "$OUT/events-2.log" | grep -o 'backend=[a-z]* .*debugger=[a-z]*' || true)"
    sleep 15
    boot_to_home second || true
    R_LAST="$R2"
else
    R_LAST="$R1"
fi

say "5. 退出"
control quit
sleep 4
for f in events.log stats.csv qemu.log; do fetch "/Documents/logs/$R_LAST/$f" "$OUT/last-$f"; done
[ -n "${R2:-}" ] && for f in stats.csv qemu.log; do fetch "/Documents/logs/$R1/$f" "$OUT/first-$f"; done
for p in $(app_pids); do
    xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
    say "已结束 App（PID $p）"
done
grep -h 'prepared in' "$OUT"/*qemu.log 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/flow.log" || true
say "记录在 $OUT"
