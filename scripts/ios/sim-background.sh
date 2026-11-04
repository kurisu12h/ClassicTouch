#!/bin/bash
# M2: check in the iOS Simulator that the app stops calling host GL in the background and that the guest draws as
# usual after it returns to the foreground.
#   1. Reset the device state as sim-boot.sh does and start with -autodrive (the app recognizes the lock screen, unlocks
#      and recognizes the home screen itself), with a very long idle time so it does not quit on its own;
#   2. WAIT seconds after the home screen is recognized, open the system Settings app, which sends our app to the
#      background, for AWAY seconds;
#   3. Bring the app back to the foreground with simctl launch (it does not restart while it is still running), wait
#      WAIT seconds, and save a guest screenshot;
#   4. Make QEMU quit and print the foreground/background records in qemu.log (gles_host_set_allowed: "foreground
#      again: N GL calls refused while away"), how the frame number changed in each stretch, and whether backboardd
#      and SpringBoard restarted.
# Usage: scripts/ios/sim-background.sh <device id> [AWAY seconds, default 15]
# Results: Documents/logs/<time>-<device>-jit/ in the app container; the summary goes to standard output.
set -euo pipefail
DEVICE="${1:?usage: sim-background.sh <device id> [AWAY]}"
AWAY="${2:-15}"
WAIT="${WAIT:-10}"
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
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 5 -autodrive YES -idle 3600 >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-jit\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "The app did not create a run directory" >&2; exit 1; }
echo "Run directory: $R"
t0=$(date +%s)
until grep -q home_seen "$R/events.log" 2>/dev/null; do
    [ $(($(date +%s) - t0)) -lt 300 ] || { echo "No home screen after 300 seconds" >&2; exit 1; }
    sleep 1
done
sleep "$WAIT"
wall() { tail -1 "$R/stats.csv" | cut -d, -f1; }
frame() { tail -1 "$R/stats.csv" | cut -d, -f6; }
echo "Before the background: second $(wall), frame $(frame)"
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
sleep "$AWAY"
echo "After $AWAY seconds in the background: second $(wall), frame $(frame)"
pid_before="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v b="$BUNDLE" '$3 ~ b {print $1}' | head -1)"
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep "$WAIT"
echo "$WAIT seconds after returning to the foreground: second $(wall), frame $(frame); app process $pid_before (before returning)"
n_runs="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" | sort) | grep -c -- "-$DEVICE-jit\$" || true)"
[ "$n_runs" = 1 ] || echo "Note: the app restarted on returning to the foreground ($n_runs new run directories)"
last="$(ls "$R" | grep '^guest-' | sort | tail -1)"
echo "Last guest screenshot: $R/$last"
echo "quit $(date +%s)" > "$C/Documents/control/quit"
for _ in $(seq 30); do grep -q qemu_exit "$R/events.log" && break; sleep 1; done
echo "--- events.log"
cat "$R/events.log"
echo "--- foreground/background and refusal records in qemu.log"
grep -E "foreground|still running|refus" "$R/qemu.log" || echo "(none)"
echo "--- process IDs of backboardd and SpringBoard in the serial log"
grep -oE "(backboardd|SpringBoard)\[[0-9]+" "$R/serial-0.log" | sort -u
