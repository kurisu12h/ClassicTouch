#!/bin/bash
# M2 app prototype: run a real user's flow through once on the phone (no autodrive; the app has no test switches at all):
#   1. Stop the app and open it with -select <first device>, as if the user tapped it in the list. The app has no JIT,
#      so it records which device to open, opens stikjit:// and quits itself; StikDebug launches a new process with the
#      debugger attached, and the new process boots with JIT right away.
#   2. At the lock screen, unlock through Documents/control/unlock and wait until a devicectl screenshot shows the home
#      screen.
#   3. Background test: devicectl brings the system Settings to the foreground, waits AWAY seconds (default 15), then
#      brings this app back to the foreground; check that the process ID and the run directory did not change, that
#      events.log has vm_pause reason=background and vm_resume, and that the frame number keeps rising after coming
#      back.
#   4. Switch systems: write the second device to control/select; the app lets QEMU quit cleanly and goes through
#      StikDebug again, and the new process boots the second device; unlock to the home screen.
#   5. control/quit, then stop the app.
# Each step saves a devicectl screenshot (the phone's full screen) to work/ios/runs/device/flow-<time>/.
#
# Usage: scripts/ios/device-app-flow.sh [first device, default n88ap-10B500] [second device, default n90ap-11D257]
# Environment: PHONE (read from work/ios/phone-udid by default), AWAY (default 15), SKIP_SWITCH=1 (skip step 4)
# Requires: the phone unlocked, the cable plugged in (files go through AFC), LocalDevVPN on, StikDebug installed
# (org.classictouch.dev.stikdebug).
set -euo pipefail
FIRST="${1:-n88ap-10B500}"
SECOND="${2:-n90ap-11D257}"
AWAY="${AWAY:-15}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHONE="${PHONE:-$(cat "$ROOT/work/ios/phone-udid" 2>/dev/null)}"  # the phone's UDID lives in work/ios/phone-udid, not in the repository
BUNDLE=org.classictouch.app
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
OCR="$ROOT/work/tools/ocr/ocr"
OUT="$ROOT/work/ios/runs/device/flow-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
T0=$(date +%s)
say() { echo "[$(($(date +%s) - T0)) s] $*" | tee -a "$OUT/flow.log"; }

afc() { { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; } || true; }
fetch() {
    if "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download "$1" "$2.part" >/dev/null 2>&1; then mv "$2.part" "$2"; else rm -f "$2.part"; fi
}
runs() { afc list /Documents/logs | grep -o '"20[0-9-]*-[^"]*"' | tr -d '"' || true; }
control() {   # COMMAND [CONTENT]: write different content each time, so it is not skipped as an unchanged file
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
shot() {   # NAME: save a full-screen screenshot of the phone and print the OCR text (separated by vertical bars)
    xcrun devicectl device capture screenshot --device "$PHONE" --destination "$OUT/$1.png" --quiet >/dev/null 2>&1 || true
    [ -f "$OUT/$1.png" ] && "$OCR" "$OUT/$1.png" 2>/dev/null | jq -r .text | tr '\n' '|' || true
}
is_home() { ! grep -qi 'slide to' <<<"$1" && grep -Eq 'Safari|App Store|Calendar|Photos|Messages|Weather|Clock' <<<"$1"; }

# Wait for a new run directory of a device to appear and print its name
wait_run() {
    local dev="$1" before="$2" new
    for _ in $(seq 90); do
        new="$(comm -13 <(echo "$before" | sort) <(runs | sort) | grep -- "-$dev-" | tail -1 || true)"
        [ -n "$new" ] && { echo "$new"; return; }
        sleep 1
    done
}

# Unlock to the home screen after booting: send unlock every 15 seconds (the lock screen goes dark after a few seconds;
# unlock presses Home first to wake it), at most 8 times
boot_to_home() {
    local name="$1" text
    for i in $(seq 8); do
        sleep 15
        text="$(shot "$name-try$i")"
        if is_home "$text"; then
            say "$name: already on the home screen at check $i"
            cp "$OUT/$name-try$i.png" "$OUT/$name-home.png"
            return 0
        fi
        control unlock
    done
    say "$name: home screen not recognized within 120 seconds"
    return 1
}

say "1. Stop the app and open it with -select $FIRST (as if the user tapped it)"
for p in $(app_pids); do xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true; done
afc remove /Documents/autostart.json >/dev/null
before="$(runs)"
first_pid="$(xcrun devicectl device process launch --device "$PHONE" --activate --json-output /dev/stdout --quiet "$BUNDLE" -- -select "$FIRST" \
    | jq -r '.result.process.processIdentifier')"
say "List process PID $first_pid"
R1="$(wait_run "$FIRST" "$before")"
[ -n "$R1" ] || { say "No run directory for $FIRST after 90 seconds (did StikDebug not launch it?)"; exit 1; }
pid1="$(app_pids | head -1)"
fetch "/Documents/logs/$R1/events.log" "$OUT/events-1.log"
say "Run directory $R1, boot process PID $pid1: $(head -1 "$OUT/events-1.log" | grep -o 'backend=[a-z]* .*debugger=[a-z]*' || true)"
boot_to_home first || true

say "3. Background test: system Settings in the foreground for $AWAY seconds"
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
say "Process IDs: before the background $pid1, in the background $pid_away, after coming back $pid_back; $n_runs run directories for $FIRST"
say "Before the background (s,frame) $before_frame; 10 seconds after coming back $after_frame; screen after coming back: $(is_home "$text" && echo home screen || echo not the home screen)"
grep -E 'vm_pause|vm_resume' "$OUT/events-1.log" | tail -4 | sed 's/^/  /' | tee -a "$OUT/flow.log"
sleep 5
fetch "/Documents/logs/$R1/stats.csv" "$OUT/stats-after.csv"
say "5 seconds later: $(tail -1 "$OUT/stats-after.csv" | cut -d, -f1,6)"

if [ "${SKIP_SWITCH:-0}" != 1 ]; then
    say "4. Switch systems: control/select $SECOND"
    before="$(runs)"
    control select "$SECOND"
    R2="$(wait_run "$SECOND" "$before")"
    [ -n "$R2" ] || { say "No run directory for $SECOND after 90 seconds"; exit 1; }
    pid2="$(app_pids | head -1)"
    fetch "/Documents/logs/$R1/events.log" "$OUT/events-1.log"
    fetch "/Documents/logs/$R2/events.log" "$OUT/events-2.log"
    say "Last lines of the old run: $(tail -2 "$OUT/events-1.log" | tr '\n' ' ')"
    say "Run directory $R2, new process PID $pid2: $(head -1 "$OUT/events-2.log" | grep -o 'backend=[a-z]* .*debugger=[a-z]*' || true)"
    sleep 15
    boot_to_home second || true
    R_LAST="$R2"
else
    R_LAST="$R1"
fi

say "5. Quit"
control quit
sleep 4
for f in events.log stats.csv qemu.log; do fetch "/Documents/logs/$R_LAST/$f" "$OUT/last-$f"; done
[ -n "${R2:-}" ] && for f in stats.csv qemu.log; do fetch "/Documents/logs/$R1/$f" "$OUT/first-$f"; done
for p in $(app_pids); do
    xcrun devicectl device process signal --device "$PHONE" --pid "$p" --signal SIGKILL --quiet >/dev/null 2>&1 || true
    say "Stopped the app (PID $p)"
done
grep -h 'prepared in' "$OUT"/*qemu.log 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/flow.log" || true
say "Records in $OUT"
