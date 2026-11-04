#!/bin/bash
# E0: cold-boot a device in the iOS Simulator and time it.
#   1. Reset the device state: delete state/ in the app container; when work/ios/devices/<id>-golden/state exists (for
#      the 3GS, the state after M0 went through the setup assistant) clone it, otherwise the app clones it from the
#      device itself on first launch.
#   2. Start the app: -device <id> -tcg <backend> -guestpng 1 (saves a guest frame every second).
#   3. OCR each frame (M0's work/tools/ocr/ocr, Vision text recognition): the first "slide to unlock" counts as
#      reaching the lock screen, and Documents/control/unlock immediately makes the app press Home and then swipe;
#      after that, home-screen icon names (Settings, Safari...) count as reaching the home screen, then IDLE more idle
#      seconds (default 20) measure the home-screen idle CPU, and finally control/quit makes QEMU quit cleanly.
#      Recognizing three or more home-screen icon names without a lock screen first also counts as reaching the home
#      screen (the lock screen is then "not reached").
#   4. Summary: lock-screen and home-screen times, the CPU seconds and average CPU% (of one core) up to then,
#      footprint, home-screen idle CPU%.
# Times are wall-clock seconds in the app counted from the qemu_ios_main call (stats.csv, the numbers of guest-NNNN.png).
#
# Usage: scripts/ios/sim-boot.sh <device id> interp|jit [maximum seconds, default 900]
# Environment: IDLE (home-screen idle seconds, default 20), TBSIZE (TCG code buffer in MB; the app's default of 256
#              when unset),
#              USBKBD=1 (attach a USB keyboard on machines with a USB host port; off by default)
# Results: Documents/logs/<time>-<device>-<backend>/ in the app container; the summary is also saved as
# work/ios/runs/<same name>.summary
set -euo pipefail
DEVICE="${1:?usage: sim-boot.sh <device id> interp|jit [maximum seconds]}"
TCG="${2:?}"
LIMIT="${3:-900}"
IDLE="${IDLE:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
OCR="$ROOT/work/tools/ocr/ocr"
UDID="${SIM_UDID:-$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name=="ClassicTouch iPhone 18 Pro") | .udid' | head -1)}"
[ -n "$UDID" ] || { echo "No ClassicTouch iPhone 18 Pro simulator" >&2; exit 1; }
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
extra=()
if [ -n "${TBSIZE:-}" ]; then extra+=(-tbsize "$TBSIZE"); fi
if [ "${USBKBD:-0}" = 1 ]; then extra+=(-usbkbd YES); fi
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg "$TCG" -guestpng 1 ${extra[@]+"${extra[@]}"} >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-$TCG\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "The app did not create a run directory" >&2; exit 1; }
echo "Run directory: $R"

lock="" home="" seen="" quit_at=""
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        case " $seen " in *" $f "*) continue ;; esac
        seen="$seen $f"
        t=$((10#$(echo "$f" | tr -dc 0-9)))
        text="$("$OCR" "$R/$f" 2>/dev/null | jq -r .text | tr '\n' '|')"
        # iOS 9's "slide to unlock" has a shimmer, and OCR often reads it as "crae to unlotk" or the like, so "to unl"
        # counts too
        # iOS 10 has no slider: "Press home to open" (shown for a few seconds) or its date line "Wednesday, December 31"
        if [ -z "$lock" ] && grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text"; then
            lock=$t
            echo "Lock screen: $t s"
            touch "$C/Documents/control/unlock"
        elif [ -n "$lock" ] && [ -z "$home" ] && ! grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text" \
            && grep -Eq 'Settings|Safari|App Store|Calendar|Photos' <<<"$text"; then
            home=$t
            echo "Home screen: $t s"
            quit_at=$(($(date +%s) + IDLE))
        elif [ -z "$lock" ] && [ -z "$home" ] && ! grep -qi 'slide to' <<<"$text" \
            && [ "$(grep -Eo 'Settings|Safari|Calendar|Photos|Stocks|Maps|Mail|Phone|Notes' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            # iPhone OS 1.0 and 2.x sometimes go straight to the home screen without the lock screen (1.0 cold-booted
            # from the golden state, 2.x on its first boot after activation)
            home=$t
            echo "Home screen (no lock screen): $t s"
            quit_at=$(($(date +%s) + IDLE))
        fi
    done
    if [ -n "$lock" ] && [ -z "$home" ] && [ -z "$(ls "$C/Documents/control")" ]; then
        # The unlock may not have worked (swiped before the screen was on); try again every 20 seconds
        last=$(grep -c 'control unlock' "$R/events.log" || true)
        if [ $(($(date +%s) - $(stat -f %m "$R/events.log"))) -ge 20 ] && [ "$last" -lt 8 ]; then
            touch "$C/Documents/control/unlock"
        fi
    fi
    if [ -n "$quit_at" ] && [ "$(date +%s)" -ge "$quit_at" ]; then
        touch "$C/Documents/control/quit"
        sleep 3
        break
    fi
    grep -q 'qemu_exit\|boot_failed' "$R/events.log" && break
    sleep 1
done

mkdir -p "$ROOT/work/ios/runs"
SUMMARY="$ROOT/work/ios/runs/$(basename "$R").summary"
python3 -I "$ROOT/scripts/ios/summarize-run.py" "$R" "${lock:-}" "${home:-}" "$IDLE" > "$SUMMARY"
cat "$SUMMARY"
cat "$R/events.log"
