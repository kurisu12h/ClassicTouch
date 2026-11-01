#!/bin/bash
# E1/E2：在真机上冷启动一台设备并计时，做法和 sim-boot.sh 一样，只是经 devicectl 走：
#   1. devicectl process launch 启动 App：-device <id> -tcg <后端> -guestpng 1 -resetstate YES（每次从全新状态冷启动，
#      3GS 从包里带的 golden-state 克隆）。
#   2. JIT（E2）：App 带 -waitdebugger 启动，scripts/ios/lldb_jit_runner.py（LLDB 的 SB API，同步模式）挂上去，
#      应答 region.c 的 brk #0x69，让调试器把代码区「准备」成可执行；QEMU 用到的信号直接放行。一直挂到测量结束。
#   3. 每 2 秒把 App 的运行目录 copy from 回 work/ios/runs/device/，逐张 OCR 客体截图：看到「slide to unlock」记锁屏，
#      往 Documents/control/unlock 放命令文件让 App 解锁；看到主屏记主屏，再空闲 IDLE 秒后 control/quit。
#   4. 汇总同 sim-boot.sh，另记最低 os_proc_available_memory()。
#
# 用法：scripts/ios/device-boot.sh <设备id> interp|jit [最长秒数，默认 900]
# 环境变量：PHONE（devicectl 能认的设备名或 UDID，默认读 work/ios/phone-udid）、IDLE（默认 20）、
#          TBSIZE（TCG 代码缓冲 MB，不设就用 App 的默认 256）、JITPROTO（legacy 用旧协议）、
#          JIT_TOUCH（调试器准备代码区的方式：bulk 整块写零，默认；page 逐页写 1 字节；none 只分配）、
#          STIK=1（第三阶段：不用 Mac 上的 LLDB，由手机上的 StikDebug 用 universal.js 给 JIT）、
#          OPENSETTINGS=1（STIK 模式下待机结束后让 App 点开「设置」再按 Home 回主屏，第四步）、
#          USBKBD=1（有 USB 主机口的机型挂 USB 键盘，默认不挂：iOS 7 会弹提示挡住触摸）、
#          SWIPETEST=1（STIK 模式下锁屏和主屏的滑动测试，分段记帧数和 CPU，汇总见 summarize-swipe.py）、
#          PERF=1（QEMU 每秒记 GL 桥、显示、发布帧的耗时，IT_PERF=1）、
#          QEMUENV（给 QEMU 的额外环境变量，JSON 对象，例如 {"IT_GLES_STRICT": "0"}）
set -euo pipefail
DEVICE="${1:?用法：device-boot.sh <设备id> interp|jit [最长秒数]}"
TCG="${2:?}"
LIMIT="${3:-900}"
IDLE="${IDLE:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # 手机 UDID 放在 work/ios/phone-udid，不进仓库
BUNDLE=org.classictouch.app
STIK_BUNDLE=org.classictouch.dev.stikdebug
OCR="$ROOT/work/tools/ocr/ocr"
LOCAL="$ROOT/work/ios/runs/device"
CTL=(--device "$PHONE" --domain-type appDataContainer --domain-identifier "$BUNDLE")
mkdir -p "$LOCAL"
# 同一时间只能有一个实例：两个实例都用 --terminate-existing 启动 App，会互相把对方的 App 杀掉
# （第二阶段有一段挂载连续失败，就是一个没退出的旧实例和新实例在打架）
LOCK="$LOCAL/.device-boot.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "已经有一个 device-boot.sh 在跑（PID $other），先结束它" >&2
        exit 2
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
EMPTY="$(mktemp)"
LLDB_PID=""
cleanup() {
    rm -f "$EMPTY"
    rm -rf "$LOCK"
    # 只按 PID 收拾自己起的调试器。它多半阻塞在 SBProcess.Continue() 里，Python 的 SIGTERM 处理要等它返回才跑，
    # 所以 2 秒后还在就直接 SIGKILL
    if [ -n "$LLDB_PID" ]; then
        kill "$LLDB_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$LLDB_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 文件操作走 AFC（idevice 工具包的 afc --documents，经 usbmuxd，要插着线），不用 devicectl copy：
# 第三阶段开着 LocalDevVPN 时 CoreDevice 的文件服务先是在 Wi-Fi 下变慢，被中断几次后整个卡死（插拔线也不恢复），
# 而 AFC 不受影响、一秒内返回。
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
# idevice-tools 偶尔会崩（Abort trap，多半是赶上正在写的文件）：失败不让脚本退出，下一轮再来
afc() { { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; } || true; }
fetch() {   # 远端路径 本地路径：先下到临时文件，成功才改名，免得留下半截文件
    if "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download "$1" "$2.part" >/dev/null 2>&1; then
        mv "$2.part" "$2"
    else
        rm -f "$2.part"
    fi
}
runs() {
    afc list /Documents/logs | grep -o '"20[0-9-]*-[^"]*"' | tr -d '"' || true
}
# 把运行目录同步回 $L：三个会变的文本每次都拿，截图只拿新的
sync_run() {
    mkdir -p "$L"
    local f
    for f in $(afc list "/Documents/logs/$R" | grep -o '"[^"]*\.[a-z]*"' | tr -d '"'); do
        case "$f" in
            events.log|stats.csv|qemu.log|serial-0.log) fetch "/Documents/logs/$R/$f" "$L/$f" ;;
            *) [ -f "$L/$f" ] || fetch "/Documents/logs/$R/$f" "$L/$f" ;;
        esac
    done
}
control() {
    # 每次写进不同的内容：devicectl copy 会跳过它认为没变过的文件，同一个空文件第二次拷就送不到了
    echo "$(date +%s) $RANDOM" > "$EMPTY"
    afc mkdir /Documents/control >/dev/null
    afc upload "$EMPTY" "/Documents/control/$1" >/dev/null
}

before="$(runs)"
MAC_LOAD_START="$(sysctl -n vm.loadavg)"
LOG=""
args=(-device "$DEVICE" -tcg "$TCG" -guestpng 1 -resetstate YES)
# TCG 代码缓冲（MB）。真机 JIT 时调试器要把整块读出再写回，隔着 Wi-Fi 约 0.8 MB/s：256 MB 要 5 分多钟
if [ -n "${TBSIZE:-}" ]; then args+=(-tbsize "$TBSIZE"); fi
# JITPROTO=legacy：旧的 brk #0x69 协议（对照用）；JIT_TOUCH 由调试器脚本自己读
if [ -n "${JITPROTO:-}" ]; then args+=(-jitprotocol "$JITPROTO"); fi
if [ "${STIK:-0}" = 1 ]; then
    # E3：StikDebug 在手机本机应答新协议（universal.js）。它拉起 App 时没有启动参数，所以先把要开的东西写进
    # App 的 Documents/autostart.json；waitdebugger 让 App 万一比调试器先跑起来时先等一下。
    cfg="$(mktemp)"
    # autodrive：App 自己认锁屏和主屏、解锁、待机、退出（见 EmulatorViewController.autodrive）
    flag() { [ "${1:-0}" = 1 ] && echo true || echo false; }
    QEMUENV_JSON="${QEMUENV:-}"
    [ -n "$QEMUENV_JSON" ] || QEMUENV_JSON='{}'
    printf '{"device": "%s", "tcg": "%s", "tbsize": %s, "guestpng": 5, "resetstate": true, "waitdebugger": true, "autodrive": true, "idle": %s, "opensettings": %s, "usbkbd": %s, "swipetest": %s, "perf": %s, "qemuenv": %s}\n' \
        "$DEVICE" "$TCG" "${TBSIZE:-256}" "$IDLE" "$(flag "${OPENSETTINGS:-0}")" "$(flag "${USBKBD:-0}")" \
        "$(flag "${SWIPETEST:-0}")" "$(flag "${PERF:-0}")" "$QEMUENV_JSON" > "$cfg"
    afc upload "$cfg" /Documents/autostart.json >/dev/null
    rm -f "$cfg"
    # 还在跑的 App 先结束，StikDebug 才会重新拉起它
    for p in $(xcrun devicectl device info processes --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.runningProcesses[] | select((.executable // "") | contains("ClassicTouch.app")) | .processIdentifier'); do
        xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
    done
    xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet \
        --payload-url "stikjit://enable-jit?bundle-id=$BUNDLE&script-name=universal.js" "$STIK_BUNDLE" >/dev/null
    echo "StikDebug 已带 URL 拉起，等它启动 App"
elif [ "$TCG" = jit ]; then
    # LLDB 的 device select 认 CoreDevice 标识（devicectl list devices 的 identifier），不认 UDID
    core="$(xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null | jq -r --arg p "$PHONE" \
        '.result.devices[] | select(.hardwareProperties.udid == $p or .identifier == $p or .deviceProperties.name == $p)
         | .identifier' | head -1)"
    # 大约每 4 到 5 次挂载会有一次：挂上后第一次继续就「Resume timed out」，之后一直卡住（调大 gdb-remote 包超时
    # 也不管用）。90 秒内没等到 QEMU 的 brk、却出现 3 次以上这个错误，就结束调试器和 App 重来，最多 3 次。
    for attempt in 1 2 3; do
        # 不用 --start-stopped（会留一个挂起的 SIGSTOP，继续后进程又停在 dyld 入口、手机白屏）：App 正常启动，
        # -waitdebugger 让它在界面上等调试器，挂上后才起 QEMU。
        out="$(xcrun devicectl device process launch --device "$PHONE" --terminate-existing \
            --json-output /dev/stdout --quiet "$BUNDLE" -- "${args[@]}" -waitdebugger YES)"
        pid="$(jq -r '.result.process.processIdentifier' <<<"$out")"
        echo "App 在等调试器，PID $pid，LLDB 挂上去（第 $attempt 次）"
        LOG="$LOCAL/lldb-$(date +%Y%m%d-%H%M%S).log"
        xcrun python3 "$ROOT/scripts/ios/lldb_jit_runner.py" "$core" "$pid" > "$LOG" 2>&1 &
        LLDB_PID=$!
        ok=""
        for _ in $(seq 90); do
            if grep -q '停下：EXC_BREAKPOINT' "$LOG"; then ok=1; break; fi
            [ "$(grep -c 'Resume timed out' "$LOG")" -ge 3 ] && break
            kill -0 "$LLDB_PID" 2>/dev/null || break
            sleep 1
        done
        [ -n "$ok" ] && break
        echo "第 $attempt 次挂载卡住，结束调试器和 App 重来"
        kill -9 "$LLDB_PID" 2>/dev/null || true
        LLDB_PID=""
        xcrun devicectl device process signal --device "$PHONE" --pid "$pid" --signal SIGKILL --quiet >/dev/null 2>&1 || true
        sleep 2
    done
else
    xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet "$BUNDLE" -- "${args[@]}" >/dev/null
fi

R=""
for _ in $(seq 120); do
    new="$(comm -13 <(echo "$before" | sort) <(runs | sort) | grep -- "-$DEVICE-" | tail -1 || true)"
    [ -n "$new" ] && { R="$new"; break; }
    sleep 1
done
[ -n "$R" ] || { echo "App 没有建运行目录（可能还在导入设备包，或启动失败）" >&2; exit 1; }
echo "运行目录：$R"
L="$LOCAL/$R"

if [ "${STIK:-0}" = 1 ]; then
    # App 自己跑完整个测量；这里只每 3 秒取一次 events.log，等它退出后再取统计、日志和窗口截图
    mkdir -p "$L"
    t0=$(date +%s)
    while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
        fetch "/Documents/logs/$R/events.log" "$L/events.log"
        grep -q 'qemu_exit\|boot_failed' "$L/events.log" 2>/dev/null && break
        sleep 3
    done
    # 到时限还没退出（开不到主屏、autodrive 不会自己退）：让 QEMU 退出，别把手机上的 App 留在跑着的状态
    if ! grep -q 'qemu_exit\|boot_failed' "$L/events.log" 2>/dev/null; then
        echo "到了 $LIMIT 秒还没退出，发 quit"
        control quit
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 3
            fetch "/Documents/logs/$R/events.log" "$L/events.log"
            grep -q 'qemu_exit' "$L/events.log" 2>/dev/null && break
        done
    fi
    for f in stats.csv threads.csv qemu.log serial-0.log argv.json \
        $(afc list "/Documents/logs/$R" | grep -Eo '"(app|guest|settings|home-back)-[^"]*"' | tr -d '"'); do
        fetch "/Documents/logs/$R/$f" "$L/$f"
    done
    fetch /Documents/logs/import.log "$L/import.log"
    # 测完结束 App（约定：别把手机留在 App 跑着或冻住的状态）
    for p in $(xcrun devicectl device info processes --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.runningProcesses[] | select((.executable // "") | contains("ClassicTouch.app")) | .processIdentifier'); do
        xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
        echo "已结束 App（PID $p）"
    done
    lock="$(grep -o 'lock_seen [0-9.]*' "$L/events.log" | awk '{printf "%d", $2}' || true)"
    home="$(grep -o 'home_seen [0-9.]*' "$L/events.log" | awk '{printf "%d", $2}' || true)"
    echo "锁屏：${lock:-未到达} 秒；主屏：${home:-未到达} 秒"
    # OPENSETTINGS：点图标到认出设置页、按 Home 到认回主屏（含每秒一次识别的延迟，最多约 1 到 2 秒）
    awk '$2 == "tap_settings" { tap = $1 } $2 == "settings_seen" && tap { printf "设置：点图标后 %.1f 秒认出设置页\n", $1 - tap }
         $2 == "home_press" { press = $1 } $2 == "home_back" && press { printf "Home：按下后 %.1f 秒认回主屏\n", $1 - press }' \
        "$L/events.log" || true
else
lock="" home="" seen="" quit_at="" unlocks=0 last_unlock=0
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
    sync_run
    for f in $(ls "$L" 2>/dev/null | grep '^guest-' | sort); do
        case " $seen " in *" $f "*) continue ;; esac
        seen="$seen $f"
        t=$((10#$(echo "$f" | tr -dc 0-9)))
        text="$("$OCR" "$L/$f" 2>/dev/null | jq -r .text | tr '\n' '|')"
        if [ -z "$lock" ] && grep -qi 'slide to unlock' <<<"$text"; then
            lock=$t
            echo "锁屏：$t 秒"
            control unlock
            unlocks=1
            last_unlock=$(date +%s)
        elif [ -n "$lock" ] && [ -z "$home" ] && ! grep -qi 'slide to' <<<"$text" \
            && grep -Eq 'Settings|Safari|App Store|Calendar|Photos' <<<"$text"; then
            home=$t
            echo "主屏：$t 秒"
            quit_at=$(($(date +%s) + IDLE))
        fi
    done
    if [ -n "$lock" ] && [ -z "$home" ] && [ $(($(date +%s) - last_unlock)) -ge 25 ] && [ "$unlocks" -lt 8 ]; then
        control unlock
        unlocks=$((unlocks + 1))
        last_unlock=$(date +%s)
    fi
    if [ -n "$quit_at" ] && [ "$(date +%s)" -ge "$quit_at" ]; then
        control quit
        sleep 4
        sync_run
        break
    fi
    grep -q 'qemu_exit\|boot_failed' "$L/events.log" 2>/dev/null && break
    sleep 2
done

fi

SUMMARY="$LOCAL/$R.summary"
python3 -I "$ROOT/scripts/ios/summarize-run.py" "$L" "${lock:-}" "${home:-}" "$IDLE" > "$SUMMARY"
{
    echo "settings TBSIZE=${TBSIZE:-256} JITPROTO=${JITPROTO:-universal} JIT_TOUCH=${JIT_TOUCH:-bulk}"
    echo "iphone_mirroring_app $(pgrep -x 'iPhone Mirroring' >/dev/null && echo 开着 || echo 没开)"
    echo "mac_load $MAC_LOAD_START -> $(sysctl -n vm.loadavg)"
    if [ -n "$LOG" ]; then grep -h '代码区' "$LOG" | sed 's/^/debugger /'; fi
    echo "stikdebug ${STIK:-0} opensettings ${OPENSETTINGS:-0} usbkbd ${USBKBD:-0}"
    grep -h 'prepared in' "$L/qemu.log" 2>/dev/null | sed 's/^/qemu /' || true
} >> "$SUMMARY"
cat "$SUMMARY"
cat "$L/events.log"
