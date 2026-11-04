# Shared by the phone scripts in scripts/ios: file operations in the app container (Documents).
# Usage: PHONE=… BUNDLE=… ROOT=…; source devfiles.sh
# Remote paths are always written as /Documents/….
#   dls DIR           the names one level below DIR, one per line
#   dget REMOTE LOCAL download to a temporary file and rename it only on success, so no half file is left behind;
#                     failures are silent (the next round tries again)
#   dput LOCAL REMOTE upload, creating missing directories
# Two backends, chosen with FILES:
#   afc        afc --documents from the idevice tool kit (through usbmuxd, needs the cable). In M1 stage 3, with
#              LocalDevVPN on, the CoreDevice file service first slowed down and then hung while AFC was unaffected,
#              so it is the default when work/ios/tools/idevice-tools-0.1.68 exists.
#   devicectl xcrun devicectl device copy and device info files; nothing extra to install
#              (docs/reports/ios-device-14pro.md). The default without idevice-tools; it has no delete, and
#              `devicectl copy` cannot get the free space either.
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
if [ -z "${FILES:-}" ]; then
    if [ -x "$IDT" ]; then FILES=afc; else FILES=devicectl; fi
fi
case "$FILES" in
afc)
    # idevice-tools sometimes crashes (Abort trap, usually when it catches a file being written): a failure must not
    # exit the script
    afc() { { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; } || true; }
    dls() { afc list "$1" | grep -o '"[^"]*"' | tr -d '"' || true; }
    dget() {
        if "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download "$1" "$2.part" >/dev/null 2>&1; then
            mv "$2.part" "$2"
        else
            rm -f "$2.part"
        fi
    }
    dput() { afc mkdir "$(dirname "$2")" >/dev/null; afc upload "$1" "$2" >/dev/null; }
    ;;
devicectl)
    DC=(--device "$PHONE" --domain-type appDataContainer --domain-identifier "$BUNDLE")
    dls() {
        local j; j="$(mktemp)"
        xcrun devicectl device info files "${DC[@]}" --subdirectory "${1#/}" --json-output "$j" >/dev/null 2>&1 || true
        jq -r '.result.files[]?.relativePath // empty' "$j" 2>/dev/null | grep -v / || true
        rm -f "$j"
    }
    dget() {
        if xcrun devicectl device copy from "${DC[@]}" --source "${1#/}" --destination "$2.part" >/dev/null 2>&1; then
            mv "$2.part" "$2"
        else
            rm -f "$2.part"
        fi
    }
    dput() { xcrun devicectl device copy to "${DC[@]}" --source "$1" --destination "${2#/}" >/dev/null 2>&1 || true; }
    ;;
*) echo "FILES must be afc or devicectl" >&2; exit 2 ;;
esac
