# Boot scripts for A5 (iPod touch 5, n78) and A6 (iPhone 5, n41)

The two scripts used in step 1 of the iOS 8 to 10 track. The report is `docs/reports/a5-step1.md`.

## Setup (in the project root)

```bash
# 1. Upstream and the A5 working tree (qemu-ios with patches/a5-n78-skeleton.patch applied)
git clone https://github.com/samhenrigold/qemu-ios upstream/qemu-ios && git -C upstream/qemu-ios checkout b225694505
git -C upstream/qemu-ios worktree add -b a5-n78 ../../work/a5/qemu-ios b225694505
git -C work/a5/qemu-ios apply ../../../patches/a5-n78-skeleton.patch

# 2. imgtools, which the two scripts depend on (the version before upstream 22f4f72746 deleted it, GPL-2)
git -C upstream/qemu-ios archive 22f4f72746^ imgtools | tar -x -C work/a5/

# 3. Build QEMU (configure arguments as in M0 report section 3)
mkdir -p work/a5/build && cd work/a5/build && ../qemu-ios/configure --target-list=arm-softmmu \
  --disable-sdl --disable-sdl-image --disable-capstone --disable-pie --disable-fuse \
  --extra-cflags="-I/opt/homebrew/opt/openssl@3/include -mmacosx-version-min=12.0" \
  --extra-ldflags="-L/opt/homebrew/opt/openssl@3/lib -lcrypto -mmacosx-version-min=12.0" \
  --python=/opt/homebrew/opt/python@3.12/libexec/bin/python3 && ninja qemu-system-arm && cd ../../..
```

Firmware (from Apple's servers; downloading needs the user's approval): `iPod5,1_9.3.5_13G36_Restore.ipsw`, `iPod5,1_7.1.2_11D257_Restore.ipsw`, placed in `work/firmware/`, with sha1 values from ipsw.me.

## Unpack the firmware, make the boot bundle, boot

```bash
curl -fsS https://api.ipsw.me/v4/keys/ipsw/iPod5,1/13G36 -o work/a5/keys/13G36.json
python3 -I tools/a5/n78_unpack.py work/firmware/iPod5,1_9.3.5_13G36_Restore.ipsw work/a5/keys/13G36.json work/a5/dec/13G36
python3 -I tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-13G36.bin -display none \
  -serial file:work/a5/runs/13G36-serial.log -monitor none -d unimp,guest_errors -D work/a5/runs/13G36-q.log
```

`n78_unpack.py` only extracts the kernel, device tree and iBoot (the root file system and ramdisk come later). `n78_kboot.py` reuses `ipad1_kboot.py` and only replaces the parts that differ on the A5; what it changes is described at its top and in report section 2.

QEMU catches `SIGALRM`, so time-limited runs need `kill -9` (the report uses a one-line perl: fork, wait N seconds, `kill 9`).

## Ramdisk as root (report sections 3.8, 3.9)

```bash
N78_RAMDISK=work/a5/dec/13G36/RestoreRamDisk.dmg python3 -I tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-rd.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-13G36-rd.bin -display none \
  -serial file:work/a5/runs/13G36-rd-serial.log -monitor none -d unimp,guest_errors,int -D work/a5/runs/13G36-rd-q.log
```

In the `-d int` log, the number of `from EL0` lines is the number of user-space exceptions, and `Taking exception 6` is a timer FIQ.

## Debugging tools

`kexts.py`, `mkelf.py` and `xref.py` must be in the same directory as `imgtools/`; copy them to `work/a5/` before use.

```bash
# Which kext an address is in (without an address, lists all kexts)
python3 -I work/a5/kexts.py work/a5/dec/11D257/kernelcache.mach 804236d8
# Wrap as an ELF, then disassemble an address range (works for kexts too; for ARM-mode code replace thumbv7 with armv7)
python3 -I work/a5/mkelf.py work/a5/dec/11D257/kernelcache.mach work/a5/dis/11D257.elf
/opt/homebrew/opt/llvm/bin/llvm-objdump -d --triple=thumbv7 --start-address=0x804235ac --stop-address=0x804237a8 work/a5/dis/11D257.elf
```

`gdbtrace.py` connects to QEMU's gdb stub (start QEMU with `-gdb tcp::1234 -S`; it only starts running once the script connects):

```bash
# Break on thread_block_reason for 200 seconds and list the call chain of each kernel stack's last sleep (7.1.2)
python3 -I tools/a5/gdbtrace.py work/a5/dec/11D257/kernelcache.mach 1234 200 800bf190
# Log every hit in order (here 9.3.5's cpu_signal, signal handling, rtclock_intr, setting the countdown)
python3 -I tools/a5/gdbtrace.py work/a5/dec/13G36/kernelcache.mach 1234 50 --log 800bd7b4 800bd874 800cb74c 800c8c20
# Interrupt and sample the current call chain 20 times
python3 -I tools/a5/gdbtrace.py work/a5/dec/11D257/kernelcache.mach 1234 20 --sample
```

## Screenshots and display registers (report section 3.10)

The boot bundle has to carry the Apple logo: first extract `AppleLogo.bin` with the new `n78_unpack.py`, then remake the boot bundle. Boot with `-qmp unix:SOCK,server,nowait` added, then:

```bash
# Screenshots at seconds 2 and 6 (saved as shot-2.png, shot-6.png), with pipeline 0 and the H4P page table recorded in pipe.txt
python3 -I tools/a5/qmon.py work/a5/runs/x/qmp.sock work/a5/runs/x 2 6
# Find references to an error string in a kext's disassembly (pcrefs.py also has to be in the same directory as imgtools/)
python3 -I work/a5/pcrefs.py work/a5/dec/11D257/kernelcache.mach work/a5/dis/11D257-h4p.txt "input width(%d) or height(%d)"
```

## USB and mounting root from a USB disk (report section 3.11)

```bash
# Decrypt the rootfs (the key is in ipsw.me's key table, the RootFS entry), then make it into a GPT disk: partition 1 is the system volume
KEY=$(python3 -I -c "import json;print(next(k['key'] for k in json.load(open('work/a5/keys/11D257.json'))['keys'] if k['image']=='RootFS'))")
unzip -o -q work/firmware/iPod5,1_7.1.2_11D257_Restore.ipsw 058-4385-009.dmg -d work/a5/rootfs
python3 -I work/a5/imgtools/vfdecrypt.py work/a5/rootfs/058-4385-009.dmg work/a5/rootfs/11D257-rootfs.dmg $KEY
python3 -I tools/a5/n78_usbroot.py work/a5/rootfs/11D257-rootfs.dmg work/a5/disks/11D257-usbroot.img
# Boot bundle without a ramdisk + USB disk (snapshot=on does not write to the image)
python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257.bin
work/a5/build/qemu-system-arm -M iPod-Touch-5G,kboot=work/a5/kboot/n78-11D257.bin -display none \
  -serial file:work/a5/runs/usbroot-serial.log -monitor none \
  -drive if=none,id=root,file=work/a5/disks/11D257-usbroot.img,format=raw,snapshot=on -device usb-storage,bus=ehci.0,drive=root
```

To watch USB enumeration: add `-trace usb_set_addr -trace scsi_req_parsed -D trace.log`.

## Full system disk (report section 3.12)

```bash
# guest tools (M0 report section 4)
python3 tools/m0/make-substitute-sdk.py work/sdk-substitute/iPhoneOS-substitute.sdk
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk IPAD_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk \
  LDID=$(command -v ldid) upstream/qemu-ios/contrib/export-guest-artifacts.sh work/guest-artifacts
# Patch and build a FirmwareKit copy (dependencies from the local SwiftPM cache)
cp -R upstream/LightTouchMac work/a5/LightTouchMac   # or git worktree
git -C work/a5/LightTouchMac apply ../../../patches/a5-firmwarekit-n78-volumes.patch
swift build -c release --package-path work/a5/LightTouchMac/Packages/FirmwareKit --scratch-path work/a5/fk/build --product firmwarekit
# Entry and helper stand-in, volumes only, made into a two-partition USB disk
python3 -I tools/a5/n78_fkprep.py 11D257 work/a5/fk
work/a5/fk/build/release/firmwarekit create --entry work/a5/fk/n78ap-11D257.json \
  --ipsw work/firmware/iPod5,1_7.1.2_11D257_Restore.ipsw --out work/a5/fk/out/n78ap-11D257 --cache work/a5/fk/cache \
  --guest-tools work/guest-artifacts/ipad-guest-tools --helper work/a5/fk/helper/LightTouchDevice \
  --stop-after volumes --skip-setup --language en-US
python3 -I tools/a5/n78_usbroot.py work/a5/fk/out/n78ap-11D257/volumes/system.img work/a5/disks/11D257-full.img \
  work/a5/fk/out/n78ap-11D257/volumes/data.img
```

## NAND, effaceable storage, keybag (report section 3.13)

The high-level IOP model (`hw/arm/s5l8940_iop.c`) is in the patch. The boot bundle has to expose the IOP and the flash controller (`N78_SHOW`), and `fill_nand` in `n78_kboot.py` fills in the device tree from the model's PPN geometry. The NAND page store lives in a directory (`ce0.pages`, `ce0.boot`), given with `-global driver=s5l8940.iop,property=nand,value=DIR`; `IOP_TRACE=1` writes the IOP's commands and statistics into the `-D` log.

```bash
# 1. Helper program (armv7, substitute SDK, ldid signature)
mkdir -p work/a5/guest && bash -c 'export GUEST_ARCH=armv7 ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk
  . upstream/qemu-ios/contrib/armv6-toolchain/armv6.sh
  cc6 tools/a5/it_nandfmt.c work/a5/guest/it_nandfmt.o -isystem "$(xcrun clang -print-resource-dir)/include"
  link6 -execute work/a5/guest/it_nandfmt work/a5/guest/it_nandfmt.o && ldid -S work/a5/guest/it_nandfmt'
# 2. Restore ramdisk copy: grow it by 1 MiB, delete the original restored_external and put the helper in its place, change the owner to root offline
mkdir -p work/a5/nandfmt/mnt && cd work/a5/nandfmt && cp ../dec/11D257/RestoreRamDisk.dmg rd-11D257.dmg
hdiutil resize -sectors $((9940992/512)) -imagekey diskimage-class=CRawDiskImage rd-11D257.dmg
hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint mnt -nobrowse rd-11D257.dmg
rm mnt/usr/local/bin/restored_external && cp ../guest/it_nandfmt mnt/usr/local/bin/restored_external
chmod 755 mnt/usr/local/bin/restored_external && hdiutil detach mnt && cd ..
python3 -I -c "import sys,types; sys.path.insert(0,'imgtools'); sys.modules['mkpkg']=types.ModuleType('mkpkg')
import build_nand as bn; bn.set_owner('nandfmt/rd-11D257.dmg', ['usr/local/bin/restored_external'], 0, 0)"
cd ../..
# 3. Two boot bundles: one for formatting (ramdisk as root, FTL formats itself) and one for normal boots
N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a5/nandfmt/rd-11D257.dmg \
  python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257-nandfmt.bin "nand-enable-reformat=1"
N78_SHOW=arm-io/iop,arm-io/flash-controller0 python3 -I tools/a5/n78_kboot.py work/a5/dec/11D257 work/a5/kboot/n78-11D257-fmi.bin
# 4. Format boot (about 3 minutes; the kernel panic after the helper prints "system keybag created; halting" is normal): writes the disk clone and the NAND directory
cp -c work/a5/disks/11D257-full-noprot.img work/a5/nandfmt/disk.img
IOP_TRACE=1 DISK=work/a5/nandfmt/disk.img SNAP=off tools/a5/n78_run.sh work/a5/runs/fmt work/a5/kboot/n78-11D257-nandfmt.bin 300 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand -D work/a5/runs/fmt/q.log
```

5. Two manual changes on the disk clone (`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount`, `mount -t hfs -o noowners`): on partition 1, change `/etc/fstab` to `/dev/disk1s1`, `/dev/disk1s2` (the NAND's FTL disk takes disk0); on partition 2, put an empty file `.it_sealed` (otherwise FirmwareKit's `it_seal` halts the system 40 seconds into the first boot).
6. Normal boot: `DISK=FIXED_DISK tools/a5/n78_run.sh DIR work/a5/kboot/n78-11D257-fmi.bin 200 -global driver=s5l8940.iop,property=nand,value=CLONE_OF_FORMATTED_NAND_DIR`.

Decompilation helpers (all must be in the same directory as `imgtools/`; copy them to `work/a5/` when reproducing): `kextelf.py` wraps a given kext together with the kernel's exported symbols into an ELF for Ghidra (REA), `rawelf.py` wraps a raw image (IOP firmware, iBoot) into an ELF, `pcfix.py` and `fwfix.py` resolve string references in pseudocode, `kstr.py` lists the strings in an address range, and `kpers.py` lists a kext's matching conditions.

## GL bridge and screenshots (report section 3.14)

In the patch, n78 already registers `QEMU_CALL`, and the GL front end that FirmwareKit installs on the system volume is used directly, with no extra arguments (`-M iPod-Touch-5G,gl-renderer=angle` switches the renderer). Reading crash logs needs a writable boot: `cp -c` a disk clone, boot it with `SNAP=off`, and afterwards mount the clone's partition 2 (`mount -t hfs -o noowners`; a read-only mount fails when the volume was not cleanly unmounted); the logs are in `mobile/Library/Logs/CrashReporter/`. Screenshots:

```bash
cp -c work/a5/nandfmt/disk-n1.img work/a5/nandfmt/disk-c2.img; mkdir -p work/a5/nandfmt/nand-c2 && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-c2/
(DISK=work/a5/nandfmt/disk-c2.img SNAP=off tools/a5/n78_run.sh work/a5/runs/gl work/a5/kboot/n78-11D257-fmi.bin 200 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-c2 &)
sleep 3; python3 -I tools/a5/qmon.py work/a5/runs/gl/qmp.sock work/a5/runs/gl 60 120 180
```

## To the lock screen (report section 3.15)

After the format boot, run `tools/a5/n78_diskfix.sh` once on a clone of the formatted disk (it branches on the system volume's version number; for 9.3.5 see the last section). For 7.1.2 it changes fstab to disk1, puts `.it_sealed` on the data volume, applies the local activation patch to lockdownd (`n78_activate.py`, which recognizes the 11D257 lockdownd and the 13G36 mobileactivationd by hash), moves the two compass HID plug-ins to `HIDPlugins.disabled`, adds the four Setup Assistant completion markers for Siri and the others, and disables DeviceOMatic in launchd's `overrides.plist` (it treats the USB disk used for root as an external device and puts a "Cannot Use Device" notification on the lock screen, which is why unlocking takes extra tries on the phone, `docs/reports/ios-device-14pro.md` section 7). Then boot as in the "GL bridge and screenshots" section: the lock screen comes at about 100 seconds and the screen turns off about 20 seconds later, so take several screenshots between 95 and 120 seconds:

```bash
cp -c work/a5/nandfmt/disk-formatted.img work/a5/nandfmt/disk-ls.img && tools/a5/n78_diskfix.sh work/a5/nandfmt/disk-ls.img
mkdir -p work/a5/nandfmt/nand-ls && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-ls/
(DISK=work/a5/nandfmt/disk-ls.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ls work/a5/kboot/n78-11D257-fmi.bin 150 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-ls &)
sleep 3; python3 -I tools/a5/qmon.py work/a5/runs/ls/qmp.sock work/a5/runs/ls 95 100 105 110 115 120
```

## Touch, buttons, unlocking to the home screen (report section 3.16)

In the patch, n78 already has spi1 touch and GPIO buttons. `tools/a5/qinput.py SOCK OUTDIR ACTION...` injects input over QMP; the actions are `T:shot`, `T:key:h` (Home; l is the power button), `T:tap:X,Y[,MS]` and `T:swipe:X0,Y0,X1,Y1[,MS]`, with coordinates in 640×1136 screen pixels. Use a disk fixed as in section 3.15 (here a clone of `disk-fix-a.img`, which has been booted once):

```bash
cp -c work/a5/nandfmt/disk-fix-a.img work/a5/nandfmt/disk-ui.img
mkdir -p work/a5/nandfmt/nand-ui work/a5/runs/ui && cp -c work/a5/nandfmt/nand-formatted/* work/a5/nandfmt/nand-ui/
(DISK=work/a5/nandfmt/disk-ui.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ui work/a5/kboot/n78-11D257-fmi.bin 220 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-ui &)
sleep 3; python3 -I tools/a5/qinput.py work/a5/runs/ui/qmp.sock work/a5/runs/ui \
  148:key:h 151:shot 152:swipe:140,975,620,975,500 157:shot 160:tap:92,920,300 190:shot 200:key:h 205:shot
```

The vertical coordinates are not calibrated: taps land about 100 pixels above the aimed point, which is why the tap on Settings uses y=920.

## 9.3.5 (13G36): lock screen, home screen, Settings (report section 3.17)

`n78_kboot.py` now hides the two M2 scalers by default (`arm-io/scaler0`, `scaler1`); when a node under arm-io is hidden, its `device_type` is changed to `-` as well (IONameMatch also matches on it). The extra tools 9.3.5 needs beyond 7.1.2:

| File | Purpose |
|---|---|
| `n78_volumes.py ROOTFS.dmg OUTDIR [GROW_MiB] [DATA_MiB]` | System volume (cut out of the rootfs and enlarged) and data volume (sparse journaled HFSX, `/private/var` skeleton, owners, content protection), replacing FirmwareKit |
| `it_nandfmt.ent` | Entitlements for the format helper (the 9.x platform sandbox does not let processes without entitlements read the raw disk): `ldid -Stools/a5/it_nandfmt.ent` |
| `n78_devcache.py CACHE` | Changes the shared cache to development: header +0x68 set to 0, signature slot 0 recomputed; only then does dyld-390 let libraries on disk override the cache |
| `n78_setupdone.py VAR` | 9.x Setup Assistant completion state; the deciding key is `ForceNoBuddy` |
| `cacheinfo.py CACHE exports/binds/methods/selrefs` | Without extracting the cache, look up exports, who binds a symbol, an ObjC class's methods, who sends a selector |
| `cache2elf.py CACHE IMAGE OUT.elf` | Cuts one image out of the cache as an ELF for Ghidra (REA) |

```bash
# 1. Volumes and the two-partition disk (the rootfs is the one decrypted in section 3.11)
cd work/a5 && python3 -B ../../tools/a5/n78_volumes.py rootfs/13G36-rootfs.dmg vol-13G36 && cd ../..
python3 -I -B tools/a5/n78_usbroot.py work/a5/vol-13G36/system.img work/a5/disks/13G36-full.img work/a5/vol-13G36/data.img
# 2. Sign the helper with its entitlements, swap it into a copy of the 9.3.5 ramdisk (make the copy as in the "NAND" section, with 11D257 replaced by 13G36), and make the format boot bundle
bash -c 'export GUEST_ARCH=armv7 ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk
  . upstream/qemu-ios/contrib/armv6-toolchain/armv6.sh
  cc6 tools/a5/it_nandfmt.c work/a5/guest/it_nandfmt.o -isystem "$(xcrun clang -print-resource-dir)/include"
  link6 -execute work/a5/guest/it_nandfmt work/a5/guest/it_nandfmt.o && ldid -Stools/a5/it_nandfmt.ent work/a5/guest/it_nandfmt'
N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a5/nandfmt/rd-13G36.dmg \
  python3 -I -B tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-nandfmt.bin "nand-enable-reformat=1"
# 3. Format boot (end QEMU by PID about 15 seconds after the helper prints "system keybag created; halting")
cp -c work/a5/disks/13G36-full.img work/a5/nandfmt/disk-935-formatted.img && mkdir -p work/a5/nandfmt/nand-935-formatted
IOP_TRACE=1 DISK=work/a5/nandfmt/disk-935-formatted.img SNAP=off tools/a5/n78_run.sh work/a5/runs/fmt935 \
  work/a5/kboot/n78-13G36-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935-formatted \
  -D work/a5/runs/fmt935/q.log
# 4. GL front end (from the patched work/a5/qemu-ios: the 4 9.x exports, EAGLContext debugLabel and so on) and the changes on the disk
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk bash work/a5/qemu-ios/contrib/gles-public/build.sh $PWD/work/a5/guest/OpenGLES
cp -c work/a5/nandfmt/disk-935-formatted.img work/a5/nandfmt/disk-935.img && tools/a5/n78_diskfix.sh work/a5/nandfmt/disk-935.img
# 5. Normal boot. The first one takes about 100 extra seconds of data migration (Apple logo plus progress bar); booting this disk again afterwards reaches the lock screen in about 80 seconds, and the screen turns off right after
N78_SHOW=arm-io/iop,arm-io/flash-controller0 python3 -I -B tools/a5/n78_kboot.py work/a5/dec/13G36 work/a5/kboot/n78-13G36-fmi.bin
mkdir -p work/a5/nandfmt/nand-935 work/a5/runs/ui935 && cp -c work/a5/nandfmt/nand-935-formatted/* work/a5/nandfmt/nand-935/
(DISK=work/a5/nandfmt/disk-935.img SNAP=off tools/a5/n78_run.sh work/a5/runs/ui935 work/a5/kboot/n78-13G36-fmi.bin 330 \
  -global driver=s5l8940.iop,property=nand,value=work/a5/nandfmt/nand-935 &)
# After the lock screen appears (about 100 seconds on the second boot): Home to wake, slide to unlock, dismiss "Trust This Computer?", tap Settings
sleep 3; python3 -I -B tools/a5/qinput.py work/a5/runs/ui935/qmp.sock work/a5/runs/ui935 \
  105:key:h 108:shot 110:swipe:140,975,620,975,500 115:shot 120:tap:455,785 125:tap:244,930 140:shot
```

Adjust the times to the actual boot progress: the screen turns off about 20 seconds after the lock screen appears, and a Home press wakes it. The "Trust This Computer?" on the home screen is lockdownd's pairing prompt; tap "Don't Trust".

## In the iPhone app (report `docs/reports/a5-app.md`)

n78's boot strategy in the app is `n78` (`app/ClassicTouch/DeviceProfile.swift`). Device directory: `device.lock.json` (`board n78ap`, `boot_strategy n78`), `kboot.bin` (the normal boot bundle from `n78_kboot.py`), `disk.img` (two-partition disk), `nand/` (`ce0.pages`, `ce0.boot`). Preferably use a disk and NAND that have been booted once (so 9.3.5 skips the first-boot data migration).

```bash
# Device directory and pack (9.3.5 as the example; 7.1.2 likewise, with the kboot changed to 11D257)
D=work/ios/devices/n78ap-13G36 && mkdir -p $D/nand && cp work/a5/kboot/n78-13G36-fmi.bin $D/kboot.bin
cp -c DISK_BOOTED_ONCE.img $D/disk.img && cp -c MATCHING_NAND_DIR/* $D/nand/
echo '{"board":"n78ap","boot_strategy":"n78","product_version":"9.3.5","build":"13G36","machine":{}}' > $D/device.lock.json
python3 -I -B scripts/ios/pack-device.py work/ios/packs/n78ap-13G36.ctpack $D=devices/n78ap-13G36
# iOS Simulator version (download the dependency sources with fetch-sources.sh first)
scripts/ios/build-deps.sh iphonesimulator
TCG=jit scripts/ios/build-qemu.sh iphonesimulator && TCG=jit scripts/ios/make-dylib.sh iphonesimulator
# Put the pack in the app's Documents/import/ in the simulator and open the app, which imports it; then time the boot and open Settings
SIM_UDID=$(cat work/ios/sim-udid) scripts/ios/sim-boot.sh n78ap-13G36 jit 420
scripts/ios/sim-settings.sh n78ap-13G36 0.381,0.819     # 0.144,0.810 for 7.1.2
```

`build-qemu.sh` applies `patches/ios-*.patch`, `a5-n78-skeleton.patch` and `a5-n78-ios-ui.patch` in turn to the iOS working tree; the iOS working tree must first be cloned locally from `upstream/qemu-ios`, with the meson subprojects (berkeley-softfloat-3, berkeley-testfloat-3, dtc, keycodemapdb) copied in. Touch is about 100 pixels too high vertically; the tap coordinates in the scripts already compensate downward.

## A6: 10.3.4 (14G61) on the iPhone 5 (n41) (report `docs/reports/a6-step1.md`)

Machine `iPhone-5` (`n78_run.sh` uses `MACHINE=iPhone-5`) and CPU `apple-swift`, both in `a5-n78-skeleton.patch`. New tools for the A6:

| File | Purpose |
|---|---|
| `dtcmp.py A.bin B.bin [PREFIX]` | Compares two device trees node by node: compatible strings, first reg, interrupts |
| `cdhash.py FILE_OR_DIR…` | The CDHash of each Mach-O slice (the slot 0 code directory, which 10.3.4's AMFI accepts) |
| `n41_trustcache.py KERNEL OUTPUT HASHFILE… [--keep …]` | Swaps CDHashes into the 14G61 kernel's static trust cache; `N78_TRUST=` in `n78_kboot.py` calls it |
| `stacksym.py CACHE stacks+X.ips PROCESS…` | Names the all-thread stacks captured by the watchdog (bug_type 288) by shared cache image and exported symbol, to find who is blocking whom (report 13.2, 13.3) |

`n78_unpack.py` gained a board argument (one IPSW covers several boards), and images that are not encrypted need no key; `n78_volumes.py` accepts a GPT root file system; `n78_activate.py`, `n78_devcache.py` and `n78_diskfix.sh` gained 14G61 branches (for 14G61 it also disables CommCenter, storage_mounter and DeviceOMatic in launchd's `disabled.plist` on the data volume: without a baseband CommCenter crashes as soon as it starts, and SpringBoard's main thread keeps waiting for it; the latter two treat the USB root disk as external storage and put a "Cannot read the connected storage media" notification on the lock screen; it also deletes SpringBoard's wallpaper cache `MappedImageCache/Wallpaper/`, which is drawn with GL and then read back, and on disks booted with the old front end it is stored all black, report 17). For n41, `n78_kboot.py` fills the clock frequency table up to all 96 slots in the device tree (otherwise spi1's clock reads 0 and touch does not come up). On the QEMU side, n41 also has minimal replies for the lm3534 backlight (0x63 on i2c0) and the display model's `gamma-busy` (when the A6 display driver loads the gamma table it waits for 0x40 to clear, with no timeout, report 16.3); on 10.x the GL front end also puts the current context into TLS slot 30, which Apple's original gl* functions read, so the gl* calls that the images in the cache make directly can reach the front end (16.4). All of this is in `a5-n78-skeleton.patch`. `n78_run.sh` takes `QEMU=` to use a different qemu-system-arm (for old-versus-new comparisons). `T:chord:equal+minus+l` in `qinput.py` presses several keys at once.

```bash
# Firmware (approved by the user): iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw, sha1 2f88a216491667ce33e768ab54752d9d0f53dc20
python3 -I -B tools/a5/n78_unpack.py work/firmware/iPhone_4.0_32bit_10.3.4_14G61_Restore.ipsw - work/a6/dec/14G61-n41 n41ap
# 1. Volumes and the two-partition disk (the root file system is 058-74968-065.dmg, the largest file in the IPSW)
cd work/a5 && python3 -B ../../tools/a5/n78_volumes.py ../a6/rootfs/14G61-rootfs.dmg ../a6/vol-14G61 && cd ../..
python3 -I -B tools/a5/n78_usbroot.py work/a6/vol-14G61/system.img work/a6/disks/14G61-full.img work/a6/vol-14G61/data.img
# 2. Hashes the trust cache must keep: all Mach-O files in the root file system and the restore ramdisk
python3 -I -B tools/a5/cdhash.py MOUNTED_SYSTEM_VOLUME > work/a6/cdhash-rootfs.txt; python3 -I -B tools/a5/cdhash.py MOUNTED_RAMDISK > work/a6/cdhash-ramdisk.txt
# 3. Format boot: grow the ramdisk by 1 MiB and swap in it_nandfmt (as for A5); the helper's hash goes into the trust cache
N78_TRUST=work/a6/trust-ramdisk.txt N78_SHOW=arm-io/iop,arm-io/flash-controller0 N78_RAMDISK=work/a6/nandfmt/rd-14G61.dmg \
  python3 -I -B tools/a5/n78_kboot.py work/a6/dec/14G61-n41 work/a6/kboot/n41-14G61-nandfmt.bin "nand-enable-reformat=1"
cp -c work/a6/disks/14G61-full.img work/a6/nandfmt/disk-1034-formatted.img && mkdir -p work/a6/nandfmt/nand-1034-formatted
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-1034-formatted.img SNAP=off tools/a5/n78_run.sh work/a6/runs/fmt4 \
  work/a6/kboot/n41-14G61-nandfmt.bin 420 -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-1034-formatted
# When "system keybag created; halting" appears, end QEMU by PID (after that, shutdown timeouts panic over and over and the log balloons)
# 4. Disk fix-up (generates DISK.img.trust), then make the normal boot bundle with these hashes
cp -c work/a6/nandfmt/disk-1034-formatted.img work/a6/nandfmt/disk-n2.img && tools/a5/n78_diskfix.sh work/a6/nandfmt/disk-n2.img
N78_TRUST=work/a6/nandfmt/disk-n2.img.trust N78_SHOW=arm-io/iop,arm-io/flash-controller0 \
  python3 -I -B tools/a5/n78_kboot.py work/a6/dec/14G61-n41 work/a6/kboot/n41-14G61-n2.bin
# 5. Normal boot: the first one has about 260 seconds of data migration (Apple logo plus progress bar), and the screen turns off after migration; end it by PID
mkdir -p work/a6/nandfmt/nand-n2 && cp -c work/a6/nandfmt/nand-1034-formatted/* work/a6/nandfmt/nand-n2/
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-n2.img SNAP=off tools/a5/n78_run.sh work/a6/runs/n3 work/a6/kboot/n41-14G61-n2.bin 360 \
  -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-n2
# 6. Boot again from the migrated disk (snapshot mode, the disk stays unchanged): lock screen at about 100 seconds, Home to the home screen, tap Settings (report 15.2).
#    After screen-off, Home wakes it (report 16.4, 16.5); the lock screen and home screen have the wallpaper (17)
MACHINE=iPhone-5 DISK=work/a6/nandfmt/disk-n2.img tools/a5/n78_run.sh work/a6/runs/f2 work/a6/kboot/n41-14G61-n2.bin 230 \
  -global driver=s5l8940.iop,property=nand,value=work/a6/nandfmt/nand-n2 &
python3 -I -B tools/a5/qinput.py work/a6/runs/f2/qmp.sock work/a6/runs/f2 100:shot 120:key:h 128:shot \
  135:swipe:560,600,80,600 145:shot 150:swipe:80,600,560,600 170:tap:396,860 182:shot
```

