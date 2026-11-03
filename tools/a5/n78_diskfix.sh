#!/bin/bash
# n78_diskfix.sh DISK.img: the edits a 7.1.2 (11D257) two-partition USB disk needs, after the NAND format boot
# (report 3.13 to 3.15), to boot to the lock screen on n78. Edits the image in place: run it on an APFS clone.
#   system volume (s1): /etc/fstab on disk1 (the NAND's FTL disk is disk0); lockdownd's local activation
#     (n78_activate.py); the two compass HID plugins moved to HIDPlugins.disabled (backboardd crashes in them on
#     about half the boots, NULL + 0xc; the iPod touch 5 has no compass; cause not found, report 3.15).
#   data volume (s2): /private/var/.it_sealed (FirmwareKit's it_seal otherwise halts the first boot); the Setup
#     Assistant steps an iPhone 4 walk does not have (Siri, Activation Lock, iCloud Keychain, email updates).
set -eu
IMG=$1; HERE="$(cd "$(dirname "$0")" && pwd)"
D=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" 2>/dev/null | head -1 | awk '{print $1}')
M=$(mktemp -d)
trap 'umount "$M" 2>/dev/null || true; hdiutil detach "$D" >/dev/null 2>&1 || true; rmdir "$M"' EXIT
mount -t hfs -o noowners "${D}s1" "$M"          # in-place writes keep root's ownership
printf '/dev/disk1s1 / hfs ro 0 1\n/dev/disk1s2 /private/var hfs rw,nosuid,nodev 0 2\n' > "$M/etc/fstab"
python3 -I "$HERE/n78_activate.py" "$M/usr/libexec/lockdownd"
mkdir -p "$M/System/Library/HIDPlugins.disabled"
for p in CompassPlugIn CompassBacklightCompensation; do
    if [ -d "$M/System/Library/HIDPlugins/$p.plugin" ]; then
        mv "$M/System/Library/HIDPlugins/$p.plugin" "$M/System/Library/HIDPlugins.disabled/"
    fi
done
sync; umount "$M"
mount -t hfs "${D}s2" "$M"                       # owners honored: new files are the caller's (501, mobile)
touch "$M/.it_sealed"
for k in AssistantPresented ActivationLockPresented KeychainSyncPresented PBEmailUpdatesPresented; do
    plutil -replace "$k" -bool YES "$M/mobile/Library/Preferences/com.apple.purplebuddy.plist"
done
sync
echo "n78_diskfix: done"
