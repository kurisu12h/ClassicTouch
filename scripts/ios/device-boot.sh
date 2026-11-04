#!/bin/bash
# E1/E2: cold-boot a device on a real phone and time it, the same way as sim-boot.sh, only through devicectl:
#   1. devicectl process launch starts the app: -device <id> -tcg <backend> -guestpng 1 -resetstate YES (every run
#      cold-boots from a fresh state; the 3GS clones the golden-state shipped in its pack).
#   2. JIT (E2): the app starts with -waitdebugger, and scripts/ios/lldb_jit_runner.py (LLDB's SB API, synchronous
#      mode) attaches and answers region.c's brk #0x69 so the debugger "prepares" the code region as executable; the
#      signals QEMU uses are passed straight through. It stays attached until the measurement ends.
#   3. Every 2 seconds, copy the app's run directory back to work/ios/runs/device/ and OCR each guest screenshot: on
#      "slide to unlock", record the lock screen and drop a command file in Documents/control/unlock so the app
#      unlocks; on the home screen, record it, and after IDLE more seconds of idle, control/quit.
#   4. Summary as in sim-boot.sh, plus the lowest os_proc_available_memory().
#
# Usage: scripts/ios/device-boot.sh <device id> interp|jit [maximum seconds, default 900]
# Environment: PHONE (a device name or UDID that devicectl accepts; read from work/ios/phone-udid by default),
#              IDLE (default 20), TBSIZE (TCG code buffer in MB; the app's default of 256 when unset),
#              JITPROTO (legacy for the old protocol),
#              JIT_TOUCH (how the debugger prepares the code region: bulk writes zeros over the whole block, the
#              default; page writes 1 byte per page; none only allocates),
#              STIK=1 (stage 3: StikDebug on the phone provides JIT with universal.js instead of LLDB on the Mac),
#              OPENSETTINGS=1 (in STIK mode, after the idle stretch the app opens Settings, then presses Home to get
#              back to the home screen; step 4),
#              USBKBD=1 (attach a USB keyboard on machines with a USB host port; off by default: iOS 7 shows an alert
#              that blocks touches),
#              SWIPETEST=1 (lock-screen and home-screen swipe tests in STIK mode, with frames and CPU recorded per
#              segment; summarized by summarize-swipe.py),
#              PERF=1 (QEMU logs the time spent in the GL bridge, the display and frame publishing every second,
#              IT_PERF=1),
#              QEMUENV (extra environment variables for QEMU, a JSON object, for example {"IT_GLES_STRICT": "0"})
#              FILES (afc or devicectl: how files in the app container are moved; AFC by default when idevice-tools
#              is there, devicectl otherwise; see devfiles.sh),
#              AUTODRIVE (1 makes the app recognize the lock and home screens itself; default 1 in StikDebug mode and
#              with devicectl),
#              LLDB_PACKET_LOG (LLDB's packet log while attaching for JIT; written next to the lldb log by default,
#              none turns it off)
set -euo pipefail
DEVICE="${1:?usage: device-boot.sh <device id> interp|jit [maximum seconds]}"
TCG="${2:?}"
LIMIT="${3:-900}"
IDLE="${IDLE:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # the phone's UDID lives in work/ios/phone-udid, not in the repository
BUNDLE=org.classictouch.app
STIK_BUNDLE=org.classictouch.dev.stikdebug
OCR="$ROOT/work/tools/ocr/ocr"
LOCAL="$ROOT/work/ios/runs/device"
CTL=(--device "$PHONE" --domain-type appDataContainer --domain-identifier "$BUNDLE")
mkdir -p "$LOCAL"
# Only one instance at a time: both instances launch the app with --terminate-existing and kill each other's app
# (in stage 2 a series of attach failures was an old instance that had not exited fighting the new one)
LOCK="$LOCAL/.device-boot.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "A device-boot.sh is already running (PID $other); stop it first" >&2
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
    # Clean up only the debugger we started, by PID. It is usually blocked in SBProcess.Continue(), and Python's
    # SIGTERM handler runs only after that returns, so SIGKILL it if it is still there after 2 seconds
    if [ -n "$LLDB_PID" ]; then
        kill "$LLDB_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$LLDB_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# File operations (dls, dget, dput): AFC with idevice-tools, devicectl without; FILES= picks one (scripts/ios/devfiles.sh)
source "$ROOT/scripts/ios/devfiles.sh"
fetch() { dget "$@"; }
runs() {
    dls /Documents/logs | grep '^20[0-9-]*-' || true
}
# Sync the run directory back to $L: the three text files that change are fetched every time, screenshots only when new
sync_run() {
    mkdir -p "$L"
    local f
    for f in $(dls "/Documents/logs/$R" | grep '\.[a-z]*$'); do
        case "$f" in
            events.log|stats.csv|qemu.log|serial-0.log) fetch "/Documents/logs/$R/$f" "$L/$f" ;;
            *) [ -f "$L/$f" ] || fetch "/Documents/logs/$R/$f" "$L/$f" ;;
        esac
    done
}
control() {
    # Write different content each time: devicectl copy skips files it considers unchanged, so the same empty file
    # would not get through the second time
    echo "$(date +%s) $RANDOM" > "$EMPTY"
    dput "$EMPTY" "/Documents/control/$1"
}

before="$(runs)"
MAC_LOAD_START="$(sysctl -n vm.loadavg)"
LOG=""
# AUTODRIVE=1: the app recognizes the lock and home screens itself, unlocks, and quits after the idle stretch
# (EmulatorViewController.autodrive); here we only poll events.log. 0: a guest screenshot every second, fetched to the
# Mac for OCR. Default 1 in StikDebug mode and when files go through devicectl: devicectl takes about a second per
# file, far too slow for one screenshot a second (on the 14 Pro only 37 files came back in 400 seconds,
# docs/reports/ios-device-14pro.md section 7)
AUTO="${AUTODRIVE:-}"
if [ -z "$AUTO" ]; then
    if [ "${STIK:-0}" = 1 ] || [ "$FILES" = devicectl ]; then AUTO=1; else AUTO=0; fi
fi
if [ "$AUTO" = 1 ]; then
    args=(-device "$DEVICE" -tcg "$TCG" -guestpng 5 -resetstate YES -autodrive YES -idle "$IDLE")
    if [ "${OPENSETTINGS:-0}" = 1 ]; then args+=(-opensettings YES); fi
else
    args=(-device "$DEVICE" -tcg "$TCG" -guestpng 1 -resetstate YES)
fi
# TCG code buffer (MB). With JIT on a phone the debugger reads the whole block out and writes it back, about 0.8 MB/s
# over Wi-Fi: 256 MB takes more than 5 minutes
if [ -n "${TBSIZE:-}" ]; then args+=(-tbsize "$TBSIZE"); fi
# JITPROTO=legacy: the old brk #0x69 protocol (for comparison); the debugger script reads JIT_TOUCH itself
if [ -n "${JITPROTO:-}" ]; then args+=(-jitprotocol "$JITPROTO"); fi
if [ "${STIK:-0}" = 1 ]; then
    # E3: StikDebug answers the new protocol on the phone itself (universal.js). It launches the app without launch
    # arguments, so first write what to open into the app's Documents/autostart.json; waitdebugger makes the app wait
    # in case it starts before the debugger.
    cfg="$(mktemp)"
    # autodrive: the app recognizes the lock and home screens itself, unlocks, idles and quits (see
    # EmulatorViewController.autodrive)
    flag() { [ "${1:-0}" = 1 ] && echo true || echo false; }
    QEMUENV_JSON="${QEMUENV:-}"
    [ -n "$QEMUENV_JSON" ] || QEMUENV_JSON='{}'
    printf '{"device": "%s", "tcg": "%s", "tbsize": %s, "guestpng": 5, "resetstate": true, "waitdebugger": true, "autodrive": true, "idle": %s, "opensettings": %s, "usbkbd": %s, "swipetest": %s, "perf": %s, "qemuenv": %s}\n' \
        "$DEVICE" "$TCG" "${TBSIZE:-256}" "$IDLE" "$(flag "${OPENSETTINGS:-0}")" "$(flag "${USBKBD:-0}")" \
        "$(flag "${SWIPETEST:-0}")" "$(flag "${PERF:-0}")" "$QEMUENV_JSON" > "$cfg"
    dput "$cfg" /Documents/autostart.json
    rm -f "$cfg"
    # Stop the app if it is still running, so that StikDebug launches it again
    for p in $(xcrun devicectl device info processes --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.runningProcesses[] | select((.executable // "") | contains("ClassicTouch.app")) | .processIdentifier'); do
        xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
    done
    xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet \
        --payload-url "stikjit://enable-jit?bundle-id=$BUNDLE&script-name=universal.js" "$STIK_BUNDLE" >/dev/null
    echo "StikDebug launched with the URL; waiting for it to start the app"
elif [ "$TCG" = jit ]; then
    # LLDB's device select takes the CoreDevice identifier (the identifier in devicectl list devices), not the UDID
    core="$(xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null | jq -r --arg p "$PHONE" \
        '.result.devices[] | select(.hardwareProperties.udid == $p or .identifier == $p or .deviceProperties.name == $p)
         | .identifier' | head -1)"
    # About one attach in 4 or 5: the first continue after attaching gives "Resume timed out" and then it stays stuck
    # (a larger gdb-remote packet timeout does not help). If no brk from QEMU arrives within 90 seconds but this error
    # shows up 3 or more times, kill the debugger and the app and start over, at most 3 times.
    # While the phone is locked the debugger cannot select it, and after attaching it always gets Resume timed out
    # (docs/reports/ios-device-14pro.md section 7): wait for an unlock first
    locked() { xcrun devicectl device info lockState --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.passcodeRequired'; }
    for i in $(seq 60); do
        [ "$(locked)" = true ] || break
        [ "$i" = 1 ] && echo "The phone is locked; please unlock it (waiting up to 2 minutes)"
        sleep 2
    done
    [ "$(locked)" = true ] && { echo "The phone stayed locked; stopping" >&2; exit 1; }
    for attempt in 1 2 3; do
        # No --start-stopped (it leaves a pending SIGSTOP, and after continuing the process stops again at the dyld
        # entry with a white screen): the app starts normally, and -waitdebugger makes it wait for the debugger on
        # screen, starting QEMU only once it is attached.
        out="$(xcrun devicectl device process launch --device "$PHONE" --terminate-existing \
            --json-output /dev/stdout --quiet "$BUNDLE" -- "${args[@]}" -waitdebugger YES)"
        pid="$(jq -r '.result.process.processIdentifier' <<<"$out")"
        echo "App waiting for the debugger, PID $pid; attaching LLDB (attempt $attempt)"
        LOG="$LOCAL/lldb-$(date +%Y%m%d-%H%M%S).log"
        # The packet log is on by default: on the 14 Pro (iOS 27.0.1), with it off a dozen or so attaches all went
        # "stopped with no stop reason" followed by Resume timed out, while the few with it on all worked (logging
        # slows LLDB down and seems to dodge a timing problem; the root cause was not found,
        # docs/reports/ios-device-14pro.md section 7). LLDB_PACKET_LOG=none turns it off, or give it a path
        pkt="${LLDB_PACKET_LOG:-${LOG%.log}-packets.log}"
        [ "$pkt" = none ] && pkt=""
        LLDB_PACKET_LOG="$pkt" xcrun python3 "$ROOT/scripts/ios/lldb_jit_runner.py" "$core" "$pid" > "$LOG" 2>&1 &
        LLDB_PID=$!
        ok=""
        for _ in $(seq 90); do
            if grep -q 'stopped: EXC_BREAKPOINT' "$LOG"; then ok=1; break; fi
            [ "$(grep -c 'Resume timed out' "$LOG")" -ge 3 ] && break
            kill -0 "$LLDB_PID" 2>/dev/null || break
            sleep 1
        done
        [ -n "$ok" ] && break
        echo "Attach $attempt got stuck; killing the debugger and the app and starting over"
        kill -9 "$LLDB_PID" 2>/dev/null || true
        LLDB_PID=""
        xcrun devicectl device process signal --device "$PHONE" --pid "$pid" --signal SIGKILL --quiet >/dev/null 2>&1 || true
        sleep 2
    done
    # None of the three attaches worked: the app has already ended, so do not wait for its run directory until the
    # time limit
    [ -n "$ok" ] || { echo "None of three attaches got QEMU's brk; stopping" >&2; exit 1; }
else
    xcrun devicectl device process launch --device "$PHONE" --terminate-existing --quiet "$BUNDLE" -- "${args[@]}" >/dev/null
fi

R=""
for _ in $(seq 120); do
    new="$(comm -13 <(echo "$before" | sort) <(runs | sort) | grep -- "-$DEVICE-" | tail -1 || true)"
    [ -n "$new" ] && { R="$new"; break; }
    sleep 1
done
[ -n "$R" ] || { echo "The app did not create a run directory (it may still be importing a device pack, or it failed to start)" >&2; exit 1; }
echo "Run directory: $R"
L="$LOCAL/$R"

if [ "$AUTO" = 1 ]; then
    # The app runs the whole measurement itself; here we only fetch events.log every 3 seconds, and once it exits,
    # the stats, logs and window screenshots
    mkdir -p "$L"
    t0=$(date +%s)
    while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
        fetch "/Documents/logs/$R/events.log" "$L/events.log"
        grep -q 'qemu_exit\|boot_failed' "$L/events.log" 2>/dev/null && break
        sleep 3
    done
    # Still running at the time limit (it never got to the home screen, and autodrive does not quit on its own): make
    # QEMU quit rather than leave the app running on the phone
    if ! grep -q 'qemu_exit\|boot_failed' "$L/events.log" 2>/dev/null; then
        echo "Still running after $LIMIT seconds; sending quit"
        control quit
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 3
            fetch "/Documents/logs/$R/events.log" "$L/events.log"
            grep -q 'qemu_exit' "$L/events.log" 2>/dev/null && break
        done
    fi
    for f in stats.csv threads.csv qemu.log serial-0.log argv.json \
        $(dls "/Documents/logs/$R" | grep -E '^(app|guest|settings|home-back)-'); do
        fetch "/Documents/logs/$R/$f" "$L/$f"
    done
    fetch /Documents/logs/import.log "$L/import.log"
    # Stop the app after measuring (the rule: do not leave the phone with the app running or frozen)
    for p in $(xcrun devicectl device info processes --device "$PHONE" --json-output /dev/stdout --quiet 2>/dev/null \
        | jq -r '.result.runningProcesses[] | select((.executable // "") | contains("ClassicTouch.app")) | .processIdentifier'); do
        xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
        echo "Stopped the app (PID $p)"
    done
    # 1.0 and 2.x do not go through the lock screen; the app then logs only home_seen, and the lock screen is "not
    # reached"
    lock="$(grep -o 'lock_seen [0-9.]*' "$L/events.log" | awk '{printf "%d", $2}' || true)"
    home="$(grep -o 'home_seen [0-9.]*' "$L/events.log" | awk '{printf "%d", $2}' || true)"
    echo "Lock screen: ${lock:+$lock s}${lock:-not reached}; home screen: ${home:+$home s}${home:-not reached}"
    # OPENSETTINGS: from the icon tap to recognizing the Settings page, and from pressing Home to recognizing the home
    # screen again (including the delay of recognizing once a second, at most about 1 to 2 seconds)
    awk '$2 == "tap_settings" { tap = $1 } $2 == "settings_seen" && tap { printf "Settings: recognized the Settings page %.1f s after the icon tap\n", $1 - tap }
         $2 == "home_press" { press = $1 } $2 == "home_back" && press { printf "Home: recognized the home screen %.1f s after the press\n", $1 - press }' \
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
        if [ -z "$lock" ] && grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text"; then   # iOS 10: "Press home to open" or the date line
            lock=$t
            echo "Lock screen: $t s"
            control unlock
            unlocks=1
            last_unlock=$(date +%s)
        elif [ -n "$lock" ] && [ -z "$home" ] && ! grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text" \
            && grep -Eq 'Settings|Safari|App Store|Calendar|Photos' <<<"$text"; then
            home=$t
            echo "Home screen: $t s"
            quit_at=$(($(date +%s) + IDLE))
        elif [ -z "$lock" ] && [ -z "$home" ] && ! grep -qi 'slide to' <<<"$text" \
            && [ "$(grep -Eo 'Settings|Safari|Calendar|Photos|Stocks|Maps|Mail|Phone|Notes' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            # iPhone OS 1.0 and 2.x sometimes go straight to the home screen without the lock screen (as in sim-boot.sh)
            home=$t
            echo "Home screen (no lock screen): $t s"
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
    echo "iphone_mirroring_app $(pgrep -x 'iPhone Mirroring' >/dev/null && echo open || echo not open)"
    echo "mac_load $MAC_LOAD_START -> $(sysctl -n vm.loadavg)"
    if [ -n "$LOG" ]; then grep -h 'code region' "$LOG" | sed 's/^/debugger /'; fi
    echo "stikdebug ${STIK:-0} opensettings ${OPENSETTINGS:-0} usbkbd ${USBKBD:-0}"
    grep -h 'prepared in' "$L/qemu.log" 2>/dev/null | sed 's/^/qemu /' || true
} >> "$SUMMARY"
cat "$SUMMARY"
cat "$L/events.log"
