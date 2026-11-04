#!/bin/bash
# Boot a device in the app in the iOS Simulator, unlock at the lock screen, open Settings at the home screen, take a
# screenshot, then make QEMU quit cleanly.
# Like sim-boot.sh it relies on OCR (work/tools/ocr/ocr) to recognize the lock screen, the home screen and Settings;
# unlocking and taps go through the app's control channel (Documents/control/unlock, tap, see
# EmulatorViewController.pollControl), so no Simulator tapping tool is needed.
#
# Usage: scripts/ios/sim-settings.sh <device id> <normalized x,y of the Settings icon> [maximum seconds, default 400]
#   Pass the center of the Settings icon: 0.380,0.719 on 9.3.5, 0.128,0.735 on 7.1.2 (iPod touch 5), 0.619,0.722 on
#   10.3.4 (iPhone 5). The home screen sometimes first shows lockdownd's "Trust This Computer?" (modal, blocks taps);
#   once it is recognized, tap its "Don't Trust" first (TRUST_TAP, default 0.713,0.603, the button's center on 9.3.5).
#   Until 2026-11-05 taps on these machines landed above the aim and the coordinates here were moved down to make up
#   for it (docs/reports/touch-calibration.md).
# Environment: SIM_UDID (default work/ios/sim-udid). Results: the app's run directory is copied to
# work/ios/runs/<run directory name>/.
set -euo pipefail
DEVICE="${1:?usage: sim-settings.sh <device id> <x,y> [maximum seconds]}"
TAP="${2:?}"
LIMIT="${3:-400}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE=org.classictouch.app
OCR="$ROOT/work/tools/ocr/ocr"
UDID="${SIM_UDID:-$(cat "$ROOT/work/ios/sim-udid")}"
C="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
[ -f "$C/Documents/devices/$DEVICE/device.lock.json" ] || { echo "No device $DEVICE in the app container" >&2; exit 1; }

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
rm -rf "$C/Documents/control"
mkdir -p "$C/Documents/control"
before="$(ls "$C/Documents/logs" 2>/dev/null || true)"
xcrun simctl launch "$UDID" "$BUNDLE" -device "$DEVICE" -tcg jit -guestpng 1 >/dev/null
R=""
for _ in $(seq 40); do
    new="$(comm -13 <(echo "$before" | sort) <(ls "$C/Documents/logs" 2>/dev/null | sort) | grep -- "-$DEVICE-jit\$" | tail -1 || true)"
    [ -n "$new" ] && { R="$C/Documents/logs/$new"; break; }
    sleep 0.5
done
[ -n "$R" ] || { echo "The app did not create a run directory" >&2; exit 1; }
echo "Run directory: $R"

TRUST_TAP="${TRUST_TAP:-0.713,0.603}"
lock="" home="" tapped="" settings="" seen="" last_try=0 trust=""
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ] && [ -z "$settings" ]; do
    for f in $(ls "$R" | grep '^guest-' | sort); do
        case " $seen " in *" $f "*) continue ;; esac
        seen="$seen $f"
        t=$((10#$(echo "$f" | tr -dc 0-9)))
        text="$("$OCR" "$R/$f" 2>/dev/null | jq -r .text | tr '\n' '|')"
        if grep -qi 'Trust This Computer' <<<"$text"; then
            trust=$t
        elif [ -z "$home" ] && grep -Eqi 'slide to unlock|to unl|press home|day, *(january|february|march|april|may|june|july|august|september|october|november|december)' <<<"$text"; then   # iOS 10: "Press home to open" or the date line
            [ -n "$lock" ] || { lock=$t; echo "Lock screen: $t s"; }
        elif [ -z "$home" ] && [ "$(grep -Eo 'Settings|Safari|Calendar|Photos|Clock|Maps|Mail|Notes' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            home=$t
            echo "Home screen: $t s"
        elif [ -n "$tapped" ] && [ "$(grep -Eo 'Airplane Mode|Wi-Fi|Bluetooth|Notifications|Control Center|Do Not Disturb|General' <<<"$text" | sort -u | wc -l)" -ge 3 ]; then
            settings=$t
            echo "Settings: $t s ($f)"
        fi
    done
    now=$(date +%s)
    if [ -n "$lock" ] && [ -z "$home" ] && [ $((now - last_try)) -ge 20 ]; then
        touch "$C/Documents/control/unlock"
        last_try=$now
    fi
    if [ -n "$trust" ]; then
        echo "Trust This Computer? alert: $trust s, tapping Don't Trust"
        echo "$TRUST_TAP $now" > "$C/Documents/control/tap"
        trust=""
        last_try=$now
    elif [ -n "$home" ] && [ -z "$settings" ] && [ $((now - last_try)) -ge 15 ]; then
        echo "$TAP $now" > "$C/Documents/control/tap"
        tapped=1
        last_try=$now
    fi
    sleep 1
done
sleep 3
touch "$C/Documents/control/quit"
for _ in $(seq 20); do grep -q 'qemu_exit' "$R/events.log" && break; sleep 1; done
mkdir -p "$ROOT/work/ios/runs/$(basename "$R")"
cp -c -R "$R/." "$ROOT/work/ios/runs/$(basename "$R")/"
cat "$R/events.log"
[ -n "$settings" ]
