#!/bin/bash
# M2 performance: run one swipe test in the iOS Simulator (the app's -autodrive -swipetest, see
# EmulatorViewController.swipeLock/swipeHome).
# Resets the device state as sim-boot.sh does and boots with -perf (IT_PERF=1); the app recognizes the lock screen, runs
# the lock-screen segment, unlocks, runs the home-screen segment, idles and quits on its own;
# here we only wait for it to quit, copy the run directory to work/ios/runs/sim/ and summarize it with
# summarize-swipe.py.
# Note: the Simulator's OpenGLES renders in software on the CPU, so the GL times are nothing like a phone GPU's; this
# only checks the feature and the way of measuring.
# Usage: scripts/ios/sim-swipe.sh <device id> [maximum seconds, default 400]
# Environment: QEMUENV="A=1 B=2" (extra environment variables for QEMU)
set -euo pipefail
DEVICE="${1:?usage: sim-swipe.sh <device id> [maximum seconds]}"
LIMIT="${2:-400}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
UDID="${SIM_UDID:-$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name=="ClassicTouch iPhone 18 Pro") | .udid' | head -1)}"
C="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
D="$C/Documents/devices/$DEVICE"
[ -f "$D/device.lock.json" ] || { echo "No device $DEVICE in the app container" >&2; exit 1; }

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
[ -n "$R" ] || { echo "The app did not create a run directory" >&2; exit 1; }
echo "Run directory: $R"
t0=$(date +%s)
until grep -q 'qemu_exit\|boot_failed' "$R/events.log" 2>/dev/null; do
    if [ $(($(date +%s) - t0)) -ge "$LIMIT" ]; then
        echo "Still running after $LIMIT seconds; sending quit"
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
