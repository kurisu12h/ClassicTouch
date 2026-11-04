#!/bin/bash
# n78_diskfix.sh DISK.img: the edits a two-partition USB disk needs, after the NAND format boot, to boot to the lock
# screen on n78 (report 3.13 to 3.17). Edits the image in place: run it on an APFS clone. The build is read from the
# system volume's SystemVersion.plist; 11D257 (7.1.2, volumes from FirmwareKit) and 13G36 (9.3.5, n78_volumes.py).
#   both, system volume (s1): /etc/fstab on disk1 (the NAND's FTL disk is disk0); local activation (n78_activate.py);
#     the two compass HID plugins moved to HIDPlugins.disabled (on 7.1.2 backboardd crashes in them on about half
#     the boots, NULL + 0xc; the iPod touch 5 has no compass; cause not found, report 3.15).
#   11D257: activation in lockdownd; data volume (s2): /private/var/.it_sealed (FirmwareKit's it_seal otherwise
#     halts the first boot) and the Setup Assistant steps an iPhone 4 walk does not have (Siri, Activation Lock,
#     iCloud Keychain, email updates) on top of FirmwareKit's seed; DeviceOMatic (com.apple.device-o-matic,
#     launched on any removable IOUSBDevice: our USB root disk) disabled in launchd's overrides.plist (owner root):
#     it posts "Cannot Use Device / QEMU USB HARDDRIVE: The connected device is not supported." over the lock
#     screen, which on a phone took five unlock tries (docs/reports/ios-device-14pro.md 7).
#   13G36: activation in mobileactivationd (8.x moved it there); the shared cache marked development
#     (n78_devcache.py) so dyld-390 loads the GL front end, $GLES (default work/a5/guest/OpenGLES, contrib/gles-public
#     with the 9.x color formats), as OpenGLES.framework/OpenGLES, owned by root; data volume: Setup's finished state
#     (n78_setupdone.py: nothing seeded it).
#   14G61 (10.3.4, the iPhone 5, n41): as 13G36 (the armv7s cache; dyld-433.8 tests the same), and since 10.x's
#     AMFI runs nothing whose CDHash no trust cache holds, the patched mobileactivationd is signed again (ad hoc,
#     its own entitlements) and the three CDHashes (daemon, cache, GL front end) are written to DISK.img.trust
#     for n78_kboot.py N78_TRUST (docs/reports/a6-step1.md 9). Data volume: CommCenter disabled in launchd's
#     db/com.apple.xpc.launchd/disabled.plist (owner root): without the baseband (hidden) it segfaults at
#     every launch, and SpringBoard's main thread waits on it and never shows the lock screen (13.3); and
#     com.apple.mobile.storage_mounter, launched on a block device under a removable USB device (our USB root
#     disk), which fails to mount it and posts "Contents not Available / Cannot read the connected storage
#     media" (MobileStorage's MOUNT_FAILURE): on the lock screen, or as an alert over the home screen that eats
#     the first taps (15.3). DeviceOMatic (com.apple.device-o-matic, on any IOUSBHostDevice) has the same
#     strings and A5's "Cannot Use Device" ones: off too. And SpringBoard's wallpaper cache
#     (mobile/Library/Caches/MappedImageCache/Wallpaper) is dropped: GL draws it and reads it back, so a boot
#     under an earlier front end that lost that readback cached opaque black, which every later boot shows (17).
set -eu
IMG=$1; HERE="$(cd "$(dirname "$0")" && pwd)"
GLES=${GLES:-$HERE/../../work/a5/guest/OpenGLES}
D=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" 2>/dev/null | head -1 | awk '{print $1}')
M=$(mktemp -d)
trap 'umount "$M" 2>/dev/null || true; hdiutil detach "$D" >/dev/null 2>&1 || true; rmdir "$M"' EXIT
mount -t hfs -o noowners "${D}s1" "$M"          # in-place writes keep root's ownership
BUILD=$(plutil -extract ProductBuildVersion raw "$M/System/Library/CoreServices/SystemVersion.plist")
case $BUILD in
11D257) ACT=usr/libexec/lockdownd ;;
13G36) ACT=usr/libexec/mobileactivationd CACHE=dyld_shared_cache_armv7 ;;
14G61) ACT=usr/libexec/mobileactivationd CACHE=dyld_shared_cache_armv7s ;;
*) echo "n78_diskfix: build $BUILD not handled" >&2; exit 1 ;;
esac
printf '/dev/disk1s1 / hfs ro 0 1\n/dev/disk1s2 /private/var hfs rw,nosuid,nodev 0 2\n' > "$M/etc/fstab"
python3 -I -B "$HERE/n78_activate.py" "$M/$ACT"
if [ "$BUILD" = 14G61 ]; then
    S=$(mktemp -d)
    cp "$M/$ACT" "$S/bin" && ldid -e "$S/bin" > "$S/ent" && ldid -S"$S/ent" "$S/bin"
    cp "$S/bin" "$M/$ACT"                        # into the existing file: root stays its owner
    rm -rf "$S"
    python3 -I -B "$HERE/cdhash.py" "$M/$ACT" > "$IMG.trust"
fi
mkdir -p "$M/System/Library/HIDPlugins.disabled"
for p in CompassPlugIn CompassBacklightCompensation; do
    if [ -d "$M/System/Library/HIDPlugins/$p.plugin" ]; then
        mv "$M/System/Library/HIDPlugins/$p.plugin" "$M/System/Library/HIDPlugins.disabled/"
    fi
done
if [ "$BUILD" != 11D257 ]; then
    python3 -I -B "$HERE/n78_devcache.py" "$M/System/Library/Caches/com.apple.dyld/$CACHE" | tee "$M.cache"
    install -m 755 "$GLES" "$M/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    if [ "$BUILD" = 14G61 ]; then
        tail -1 "$M.cache" >> "$IMG.trust"
        python3 -I -B "$HERE/cdhash.py" "$M/System/Library/Frameworks/OpenGLES.framework/OpenGLES" >> "$IMG.trust"
    fi
    rm -f "$M.cache"
fi
sync; umount "$M"
if [ "$BUILD" != 11D257 ]; then
    # a file the noowners mount created is the caller's: put root back in the catalog (imgtools/build_nand.set_owner)
    python3 -I -B -c "import sys, types; sys.path.insert(0, sys.argv[1]); sys.modules['mkpkg'] = types.ModuleType('mkpkg')
import build_nand as bn; print('owner root:', bn.set_owner(sys.argv[2], ['System/Library/Frameworks/OpenGLES.framework/OpenGLES'], 0, 0), 'record')" \
        "$HERE/../../work/a5/imgtools" "${D}s1"
fi
mount -t hfs "${D}s2" "$M"                       # owners honored: new files are the caller's (501, mobile)
if [ "$BUILD" = 11D257 ]; then
    touch "$M/.it_sealed"
    for k in AssistantPresented ActivationLockPresented KeychainSyncPresented PBEmailUpdatesPresented; do
        plutil -replace "$k" -bool YES "$M/mobile/Library/Preferences/com.apple.purplebuddy.plist"
    done
else
    python3 -I -B "$HERE/n78_setupdone.py" "$M"
fi
if [ "$BUILD" = 11D257 ]; then
    sync; umount "$M"; mount -t hfs -o noowners "${D}s2" "$M"     # db/launchd.db is root's
    mkdir -p "$M/db/launchd.db/com.apple.launchd"
    python3 -I -B -c "import os, plistlib, sys
p = sys.argv[1]; raw = open(p, 'rb').read() if os.path.exists(p) else b''
d = plistlib.loads(raw) if raw.strip() else {}
d['com.apple.device-o-matic'] = {'Disabled': True}
b = plistlib.dumps(d); open(p, 'r+b' if os.path.exists(p) else 'wb').write(b); os.truncate(p, len(b))
print('launchd overrides:', d)" "$M/db/launchd.db/com.apple.launchd/overrides.plist"
    sync; umount "$M"
    python3 -I -B -c "import sys, types; sys.path.insert(0, sys.argv[1]); sys.modules['mkpkg'] = types.ModuleType('mkpkg')
import build_nand as bn; print('owner root:', bn.set_owner(sys.argv[2], ['db/launchd.db/com.apple.launchd/overrides.plist'], 0, 0), 'record')" \
        "$HERE/../../work/a5/imgtools" "${D}s2"
fi
if [ "$BUILD" = 14G61 ]; then
    rm -f "$M/mobile/Library/Caches/MappedImageCache/Wallpaper/"*        # SpringBoard draws it again
    sync; umount "$M"; mount -t hfs -o noowners "${D}s2" "$M"     # db/com.apple.xpc.launchd is root's, 755
    python3 -I -B -c "import os, plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, 'rb')) if os.path.exists(p) else {}
d['com.apple.CommCenter'] = True
d['com.apple.device-o-matic'] = True
d['com.apple.mobile.storage_mounter'] = True
open(p, 'r+b' if os.path.exists(p) else 'wb').write(plistlib.dumps(d)); os.truncate(p, len(plistlib.dumps(d)))
print('launchd disabled:', sorted(k for k, v in d.items() if v))" "$M/db/com.apple.xpc.launchd/disabled.plist"
    sync; umount "$M"
    python3 -I -B -c "import sys, types; sys.path.insert(0, sys.argv[1]); sys.modules['mkpkg'] = types.ModuleType('mkpkg')
import build_nand as bn; print('owner root:', bn.set_owner(sys.argv[2], ['db/com.apple.xpc.launchd/disabled.plist'], 0, 0), 'record')" \
        "$HERE/../../work/a5/imgtools" "${D}s2"
fi
sync
echo "n78_diskfix: $BUILD done"
