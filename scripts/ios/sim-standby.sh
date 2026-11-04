#!/bin/bash
# Stage 2 item 5: long standby test of the iPod touch 2G with the placeholder SecureROM, run in a second simulator,
# "ClassicTouch Standby", so it neither occupies the phone nor fights sim-boot.sh for the same simulator.
#   1. Cold-boot n72ap-7E18 (JIT; no debugger needed in the Simulator) with a local TCP QMP port for evidence.
#   2. Once OCR sees the lock screen, touch nothing and record every 60 seconds: CPU%, backlight, frame number, and the
#      CPU's PC and state from QMP. The placeholder bootrom is a "b ." at address 0: if waking went through the
#      bootrom, the PC would sit spinning near 0, with the CPU at full load and no new frames.
#   3. After STANDBY minutes of standby (default 35), press Home and look again 30 seconds later; then swipe to unlock
#      and see whether it gets back to the home screen.
# Usage: scripts/ios/sim-standby.sh   Results: work/ios/runs/standby-<run directory name>.log
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
[ -n "$R" ] || { echo "The app did not create a run directory" >&2; exit 1; }
OUT="$ROOT/work/ios/runs/standby-$(basename "$R").log"
mkdir -p "$ROOT/work/ios/runs"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT"; }
probe() {   # one line: app time, CPU%, backlight, frame number, PC, CPU state
    local stat pc cpus
    stat="$(tail -1 "$R/stats.csv")"
    pc="$($QMP hmp 'info registers' 2>/dev/null | grep -o 'R15=[0-9a-f]*' | head -1 || true)"
    cpus="$($QMP hmp 'info cpus' 2>/dev/null | tr -s ' \r\n' ' ' || true)"
    say "stats[$stat] $pc cpus[$cpus]"
}
say "Run directory $R, standby $STANDBY minutes"

lock=""
for _ in $(seq 120); do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        if "$OCR" "$R/$f" 2>/dev/null | jq -r .text | grep -qi 'slide to unlock'; then lock="$f"; break; fi
    done
    [ -n "$lock" ] && break
    sleep 2
done
[ -n "$lock" ] || { say "The lock screen never came"; exit 1; }
say "Lock screen: $lock; starting standby, hands off"

end=$(($(date +%s) + STANDBY * 60))
while [ "$(date +%s)" -lt "$end" ]; do
    probe
    sleep 60
done

say "Pressing Home"
touch "$C/Documents/control/home"
for _ in 1 2 3; do sleep 10; probe; done
say "Swiping to unlock"
touch "$C/Documents/control/unlock"
sleep 30
probe
last="$(ls "$R" | grep '^guest-' | sort | tail -1)"
say "Last guest screenshot $last: $("$OCR" "$R/$last" 2>/dev/null | jq -r .text | tr '\n' '|')"
cp "$R/$last" "$ROOT/work/ios/runs/standby-last-guest.png"
say "Events: $(tr '\n' ';' < "$R/events.log")"
