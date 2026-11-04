#!/bin/bash
# One-step install (m2-timeline): install the freshly built app and the freshly made device packs on the phone, then
# boot each device once with JIT from StikDebug and time it.
#   1. Check: the app is there, the packs are there, AFC reaches the phone over USB, and the phone has enough free
#      space (the total pack size + 2 GB of room for unpacking).
#   2. devicectl installs the app. The same bundle ID makes it an in-place install that keeps the app's Documents:
#      devices already on the phone stay untouched and are not uploaded again.
#   3. Upload the packs into the app's Documents/import/ through AFC (the app does not have to be open meanwhile).
#   4. Open the app (the list page) and wait while it unpacks the packs one by one: logs/import.log gets one more line
#      per pack, and the line of a pack that failed to import says it failed.
#   5. For each device, STIK=1 scripts/ios/device-boot.sh <id> jit: StikDebug provides JIT, the app cold-boots from
#      the golden state in the pack, recognizes the lock and home screens itself (1.0 and 2.2.1 skip the lock screen
#      and record only the home screen), unlocks, quits after IDLE seconds of idle, and the records come back to
#      work/ios/runs/device/.
#   6. List each device's lock screen, home screen and home-screen idle CPU.
#
# Usage: scripts/ios/device-install.sh [PACK ...] (default: the 4 packs under work/ios/packs/ that fill in the
# timeline)
# Environment: PHONE (a device name or UDID that devicectl accepts; read from work/ios/phone-udid by default),
#              APP (default work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app),
#              IDLE (home-screen idle seconds, default 30), SKIP_INSTALL=1, SKIP_UPLOAD=1, SKIP_BOOT=1
#              (skip that step)
# Requires: the phone unlocked and on the data cable (AFC goes over USB), LocalDevVPN on, iPhone Mirroring not open;
#           do not touch the phone screen while it runs.
#           Files go through AFC with idevice-tools and through devicectl without (FILES= picks one, see
#           devfiles.sh; devicectl cannot read the free space).
# During the roughly 3 minutes of uploading the app is not in the foreground and the phone may lock itself: when the
# app has to start, it is retried every 5 seconds for 2 minutes, so just unlock the phone then.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # the phone's UDID stays out of the repository
[ -n "$PHONE" ] || { echo "No phone UDID: set PHONE or write work/ios/phone-udid" >&2; exit 1; }
APP="${APP:-$ROOT/work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app}"
IDLE="${IDLE:-30}"
BUNDLE=org.classictouch.app
# File operations (dls, dget, dput): AFC with idevice-tools, devicectl without; FILES= picks one (scripts/ios/devfiles.sh)
source "$ROOT/scripts/ios/devfiles.sh"
if [ $# -gt 0 ]; then
    PACKS=("$@")
else
    PACKS=()
    for id in n72ap-5H11a m68ap-1A543a n90ap-8L1 n90ap-9B206; do PACKS+=("$ROOT/work/ios/packs/$id.ctpack"); done
fi
OUT="$ROOT/work/ios/runs/device/install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/install.log"; }
t_start=$(date +%s)

# 1. Check
for p in "${PACKS[@]}"; do [ -f "$p" ] || { echo "Pack not found: $p" >&2; exit 1; }; done
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
    [ -d "$APP" ] || { echo "No app: $APP (build the device version first)" >&2; exit 1; }
    codesign --verify --deep "$APP" || { echo "App signature check failed: $APP" >&2; exit 1; }
fi
need=2147483648
for p in "${PACKS[@]}"; do need=$((need + $(stat -f %z "$p"))); done
if [ "$FILES" = afc ]; then
    info="$("$IDT" --udid "$PHONE" afc device_info 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
    echo "$info" > "$OUT/device_info.txt"
    # The output has free_bytes (idevice's DeviceInfo); older AFC versions call the field FSFreeBytes; accept both
    free="$(grep -Eio '(FSFreeBytes|free_bytes)[^0-9]*[0-9]+' <<<"$info" | grep -Eo '[0-9]+$' | head -1 || true)"
    if [ -z "$free" ]; then
        say "AFC cannot read the phone's info (cable not plugged in? this Mac not trusted?); stopping: $(head -c 300 <<<"$info")"
        exit 1
    fi
    say "The phone has $((free / 1048576)) MB free; this run needs about $((need / 1048576)) MB"
    if [ "${SKIP_UPLOAD:-0}" != 1 ] && [ "$free" -lt "$need" ]; then
        say "Not enough space; stopping"
        exit 1
    fi
else
    # devicectl cannot read the free space (device info details has only the total capacity): no check, just say so
    say "Files go through devicectl, which cannot read the phone's free space; not checked. This run needs about $((need / 1048576)) MB"
fi

# The phone may be locked when the app has to start: retry every 5 seconds, for at most 2 minutes
launch_list() {
    for _ in $(seq 24); do
        if xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet "$BUNDLE" \
            >> "$OUT/devicectl.log" 2>&1; then
            return 0
        fi
        say "Cannot open the app (is the phone locked?); please unlock the phone, retrying in 5 seconds"
        sleep 5
    done
    return 1
}

# 2. Install the app
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
    say "Installing the app: $APP"
    xcrun devicectl device install app --device "$PHONE" "$APP" >> "$OUT/devicectl.log" 2>&1
    say "Installed"
fi

# 3. Upload the packs (the app does not have to be open)
if [ "${SKIP_UPLOAD:-0}" != 1 ]; then
    for p in "${PACKS[@]}"; do
        name="$(basename "$p")"
        t=$(date +%s)
        say "Uploading $name ($(( $(stat -f %z "$p") / 1048576 )) MB)"
        dput "$p" "/Documents/import/$name"
        say "Uploaded $name in $(( $(date +%s) - t )) seconds"
    done

    # 4. Open the app so it unpacks, and wait until import.log has a result for every pack
    count() { grep -c -- "$1" "$OUT/import.log" 2>/dev/null || true; }
    dget /Documents/logs/import.log "$OUT/import.log"
    [ -f "$OUT/import.log" ] || : > "$OUT/import.log"
    base=()  # how many lines each pack already has in import.log before the import (/bin/bash 3.2 has no associative arrays, so the indexes follow PACKS)
    for p in "${PACKS[@]}"; do base+=("$(count "$(basename "$p")")"); done
    launch_list || { say "The app never opened; stopping"; exit 1; }
    say "The app is open; waiting for it to import"
    t=$(date +%s)
    while :; do
        sleep 3
        dget /Documents/logs/import.log "$OUT/import.log"
        done_all=1
        for i in "${!PACKS[@]}"; do
            [ "$(count "$(basename "${PACKS[$i]}")")" -gt "${base[$i]}" ] || done_all=0
        done
        [ "$done_all" = 1 ] && break
        if [ $(($(date +%s) - t)) -gt 600 ]; then
            say "Import not finished after 10 minutes; stopping (see the message on the app's home page on the phone)"
            exit 1
        fi
    done
    say "Import done in $(( $(date +%s) - t )) seconds:"
    for p in "${PACKS[@]}"; do grep -- "$(basename "$p")" "$OUT/import.log" | tail -1 | tee -a "$OUT/install.log"; done
    if grep -q " failed: " <(for p in "${PACKS[@]}"; do grep -- "$(basename "$p")" "$OUT/import.log" | tail -1; done); then
        say "A pack failed to import; stopping"
        exit 1
    fi
fi

# 5. Boot each one once (device-boot.sh first stops the app, then launches it through StikDebug)
if [ "${SKIP_BOOT:-0}" != 1 ]; then
    for p in "${PACKS[@]}"; do
        id="$(basename "$p" .ctpack)"
        say "Booting $id"
        STIK=1 IDLE="$IDLE" PHONE="$PHONE" "$ROOT/scripts/ios/device-boot.sh" "$id" jit 600 > "$OUT/boot-$id.log" 2>&1 \
            || say "device-boot.sh for $id exited with an error (see $OUT/boot-$id.log)"
        grep -E '^(run|lock_s|lock |home_s|home |home_idle_cpu_pct|Lock screen)' "$OUT/boot-$id.log" | tee -a "$OUT/install.log" || true
        sleep 3
    done
fi
say "All done in $(( $(date +%s) - t_start )) seconds. Records in $OUT"
