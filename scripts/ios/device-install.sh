#!/bin/bash
# 一键装机（m2-timeline）：把新编的 App 和新做的设备包装进手机，再每台用 StikDebug 的 JIT 开一次计时。
#   1. 检查：App 在、包在、手机经 USB 能连上 AFC，手机剩余空间够（包的总大小 + 2 GB 解包余量）。
#   2. devicectl 装 App。同一个 bundle ID 是覆盖安装，App 的 Documents 留着：手机上已有的设备不动、不重传。
#   3. 经 AFC 把包传进 App 的 Documents/import/（传的时候 App 不用开着）。
#   4. 打开 App（列表页），等它把包一个个解开：logs/import.log 每个包多一行「解包」，失败的那行带「导入失败」。
#   5. 每台 STIK=1 scripts/ios/device-boot.sh <id> jit：StikDebug 给 JIT，App 从包里的黄金状态冷启动，自己认锁屏和
#      主屏（1.0、2.2.1 不经过锁屏，只记主屏）、解锁、待机 IDLE 秒后退出，记录取回 work/ios/runs/device/。
#   6. 列出每台的锁屏、主屏、主屏静止 CPU。
#
# 用法：scripts/ios/device-install.sh [包 ...]（默认 work/ios/packs/ 下年表补全的 4 个）
# 环境变量：PHONE（devicectl 能认的设备名或 UDID，默认读 work/ios/phone-udid）、
#          APP（默认 work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app）、
#          IDLE（主屏待机秒数，默认 30）、SKIP_INSTALL=1、SKIP_UPLOAD=1、SKIP_BOOT=1（跳过对应的步骤）
# 前提：手机解锁、插着数据线（AFC 走 USB）、LocalDevVPN 开着、没开 iPhone 镜像；跑的时候别碰手机屏幕。
# 传包约 3 分钟里 App 不在前台，手机可能自动锁屏：要启动 App 时会每 5 秒重试 2 分钟，这时解锁手机就行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # 手机 UDID 不进仓库
[ -n "$PHONE" ] || { echo "没有手机 UDID：设 PHONE 或写 work/ios/phone-udid" >&2; exit 1; }
APP="${APP:-$ROOT/work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app}"
IDLE="${IDLE:-30}"
BUNDLE=org.classictouch.app
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
if [ $# -gt 0 ]; then
    PACKS=("$@")
else
    PACKS=()
    for id in n72ap-5H11a m68ap-1A543a n90ap-8L1 n90ap-9B206; do PACKS+=("$ROOT/work/ios/packs/$id.ctpack"); done
fi
OUT="$ROOT/work/ios/runs/device/install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/install.log"; }
afc() { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
t_start=$(date +%s)

# 1. 检查
for p in "${PACKS[@]}"; do [ -f "$p" ] || { echo "没有包 $p" >&2; exit 1; }; done
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
    [ -d "$APP" ] || { echo "没有 App：$APP（先编真机版）" >&2; exit 1; }
    codesign --verify --deep "$APP" || { echo "App 签名校验没过：$APP" >&2; exit 1; }
fi
info="$("$IDT" --udid "$PHONE" afc device_info 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
echo "$info" > "$OUT/device_info.txt"
# 输出里是 free_bytes（idevice 的 DeviceInfo），老版本的 AFC 字段名是 FSFreeBytes，两个都认
free="$(grep -Eio '(FSFreeBytes|free_bytes)[^0-9]*[0-9]+' <<<"$info" | grep -Eo '[0-9]+$' | head -1 || true)"
if [ -z "$free" ]; then
    say "AFC 读不到手机信息（没插线？没信任这台 Mac？），停下：$(head -c 300 <<<"$info")"
    exit 1
fi
need=2147483648
for p in "${PACKS[@]}"; do need=$((need + $(stat -f %z "$p"))); done
say "手机剩余 $((free / 1048576)) MB，这次要约 $((need / 1048576)) MB"
if [ "${SKIP_UPLOAD:-0}" != 1 ] && [ "$free" -lt "$need" ]; then
    say "空间不够，停下"
    exit 1
fi

# 要启动 App 时手机可能锁着：每 5 秒重试，最多 2 分钟
launch_list() {
    for _ in $(seq 24); do
        if xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet "$BUNDLE" \
            >> "$OUT/devicectl.log" 2>&1; then
            return 0
        fi
        say "打不开 App（手机锁着？），请解锁手机，5 秒后重试"
        sleep 5
    done
    return 1
}

# 2. 装 App
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
    say "装 App：$APP"
    xcrun devicectl device install app --device "$PHONE" "$APP" >> "$OUT/devicectl.log" 2>&1
    say "装好了"
fi

# 3. 传包（App 不用开着）
if [ "${SKIP_UPLOAD:-0}" != 1 ]; then
    afc mkdir /Documents/import > /dev/null || true
    for p in "${PACKS[@]}"; do
        name="$(basename "$p")"
        t=$(date +%s)
        say "传 $name（$(( $(stat -f %z "$p") / 1048576 )) MB）"
        afc upload "$p" "/Documents/import/$name" >> "$OUT/afc.log"
        say "传完 $name，用了 $(( $(date +%s) - t )) 秒"
    done

    # 4. 打开 App 让它解包，等 import.log 里每个包都有结果
    count() { grep -c -- "$1" "$OUT/import.log" 2>/dev/null || true; }
    "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download /Documents/logs/import.log "$OUT/import.log" \
        > /dev/null 2>&1 || : > "$OUT/import.log"
    base=()  # 导入前每个包在 import.log 里已有几行（/bin/bash 3.2 没有关联数组，按 PACKS 的下标对应）
    for p in "${PACKS[@]}"; do base+=("$(count "$(basename "$p")")"); done
    launch_list || { say "一直打不开 App，停下"; exit 1; }
    say "App 已打开，等它导入"
    t=$(date +%s)
    while :; do
        sleep 3
        "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download /Documents/logs/import.log "$OUT/import.log.part" \
            > /dev/null 2>&1 && mv "$OUT/import.log.part" "$OUT/import.log"
        done_all=1
        for i in "${!PACKS[@]}"; do
            [ "$(count "$(basename "${PACKS[$i]}")")" -gt "${base[$i]}" ] || done_all=0
        done
        [ "$done_all" = 1 ] && break
        if [ $(($(date +%s) - t)) -gt 600 ]; then
            say "10 分钟还没导入完，停下（看手机上 App 首页的提示）"
            exit 1
        fi
    done
    say "导入完，用了 $(( $(date +%s) - t )) 秒："
    for p in "${PACKS[@]}"; do grep -- "$(basename "$p")" "$OUT/import.log" | tail -1 | tee -a "$OUT/install.log"; done
    if grep -q "失败" <(for p in "${PACKS[@]}"; do grep -- "$(basename "$p")" "$OUT/import.log" | tail -1; done); then
        say "有包导入失败，停下"
        exit 1
    fi
fi

# 5. 每台开一次（device-boot.sh 会先结束 App，再经 StikDebug 拉起）
if [ "${SKIP_BOOT:-0}" != 1 ]; then
    for p in "${PACKS[@]}"; do
        id="$(basename "$p" .ctpack)"
        say "开 $id"
        STIK=1 IDLE="$IDLE" PHONE="$PHONE" "$ROOT/scripts/ios/device-boot.sh" "$id" jit 600 > "$OUT/boot-$id.log" 2>&1 \
            || say "$id 的 device-boot.sh 出错退出（看 $OUT/boot-$id.log）"
        grep -E '^(run|lock_s|lock |home_s|home |home_idle_cpu_pct|锁屏)' "$OUT/boot-$id.log" | tee -a "$OUT/install.log" || true
        sleep 3
    done
fi
say "全部做完，用了 $(( $(date +%s) - t_start )) 秒。记录在 $OUT"
