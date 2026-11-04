# M2 Timeline fill-in: four new devices

- Date: 2026-11-02
- Execution session: m2-timeline. Scope: download 4 firmware files, make 4 devices, boot them on the Mac through first-time setup and save golden states, build `.ctpack` packs, boot and time them with our app in the iOS Simulator, make the app support the original iPhone's boot method, and confirm the Timeline on the home page.
- Not done: the phone was not touched; `upstream/` was not changed (changes are in a clone under `work/`, patches go in `patches/`); no commit, no push, no issues or PRs filed upstream; nothing downloaded besides the 4 firmware files in the brief; files belonging to the UI session (`Theme.swift`, `EmulatorViewController.swift` and others) were not changed.
- This machine: M4 Max, macOS 27, Xcode 27.2. qemu-ios b225694505, LightTouchMac b06012fa4c.

## 0. Conclusions

1. **All 4 booted to the home screen both on the Mac and in the iOS Simulator**, and the Timeline on the app's home page now runs continuously from 2007 to 2013 (pictures in section 5):

   | Year | Device | Mac (native QEMU, JIT) | Simulator (app, JIT 256 MB) |
   |---|---|---|---|
   | 2007 | Original iPhone · iPhone OS 1.0 (1A543a) | Lock screen 46 s, home screen 51 s, idle CPU 4.5% | Straight to home screen in 41 s, idle CPU 15% |
   | 2008 | iPod touch 2nd gen · iPhone OS 2.2.1 (5H11a) | Straight to home screen in 8 s, idle CPU 11% | Straight to home screen in 8 s, idle CPU 18% |
   | 2010 | iPhone 4 · iOS 4.3.5 (8L1) | Lock screen 41 s | Lock screen 44 s, home screen 52 s, idle CPU 20% |
   | 2011 | iPhone 4 · iOS 5.1.1 (9B206) | Setup Assistant appears at 22 s, completed at 69 s | Lock screen 21 s, home screen 30 s, idle CPU 22% |

2. **The original iPhone does not need Apple's SecureROM**: qemu-ios only places the S5L8900 ROM at 0x20000000 so iBoot can look up the jump table, and the machine itself points the two slots iBoot calls (8900 image verification, decryption) at stubs, so a placeholder file containing a single "b ." is enough to boot. The app gained a third boot method, `s5l8900` (NOR on pflash); only `DeviceProfile.swift` was changed.
3. **iPod touch 2nd gen 2.2.1 does not boot when made the stock way, and boots after one FirmwareKit patch**. Stock FirmwareKit gives 2.x the full chain "SecureROM → LLB in NOR → iBoot", and with the placeholder ROM the CPU stops at address 0; switching to jumping straight into the decrypted iBoot as for 3.x reaches SpringBoard, but it stops at "Connect to iTunes" (lockdownd's brick state, which on the iPod is cleared only when a paired host sets the time once over USB). The patch `patches/firmwarekit-n72-2x-direct-iboot.patch` makes 2.x also output iBoot.bin and boot straight into iBoot, and pre-writes `-BrickState = false` the way the 1.x recipe does. Details in section 3. **This is a change to Light Touch's device-making tool, and it must also be carried along when making devices on the phone later (M3).**
4. **Device language**: FirmwareKit defaults to the Mac's current language; this Mac is now in Simplified Chinese, so the first 4 devices made were all in Chinese. To match the three devices already in the app (made by M0, en-AU) and to let the scripts' English OCR work, I remade the 4 devices with `--language en-AU`. The Chinese versions are kept in `work/timeline/zh/` (for the Chinese 4.3.5 home screen see section 6). The guest language is for the user to decide.
5. **Preparation for installing on the phone is done** (section 11, second round): `Era.runnable` changed to `1...7`; autodrive recognizes "straight to the home screen without the lock screen"; the device build of the app is built (not installed); the one-step install script `scripts/ios/device-install.sh` is written, and everything that can be verified in the simulator has been. All that remains is one run on the phone, about 10 to 15 minutes.

## 1. Firmware and devices

| Device | Firmware | Source | sha1 (matches the firmware catalog) | Making |
|---|---|---|---|---|
| m68ap-1A543a | iPhone1,1_1.0_1A543a_Restore.ipsw (96 MB) | Apple servers | fb8bb3ee2e9a997affbb97868599f2995c78209c | 11 s |
| n72ap-5H11a | iPod2,1_2.2.1_5H11a_Restore.ipsw (291 MB) | Apple servers | 9af5625ea34acdd8abeb6fce71a72651d0c815d5 | 9 s (patched FirmwareKit) |
| n90ap-8L1 | iPhone3,1_4.3.5_8L1_Restore.ipsw (699 MB) | Apple servers | 7099307319c669356955e9aff11a3129d6b8d8b4 | 73 s (including two one-off boots) |
| n90ap-9B206 | iPhone3,1_5.1.1_9B206_Restore.ipsw (821 MB) | Apple servers | a03a29c4dd2016edb3da72c3e26e30fbf0f42b2f | 72 s |

All four were downloaded from Apple's servers in one go (1.9 GB in total, about 4 minutes), without needing a mirror. Firmware is in `work/firmware/`, devices in `work/devices/`, golden states in `work/states/`.

Boot method for each:

| Device | QEMU machine | Boot method (boot_strategy in the lock) | NAND |
|---|---|---|---|
| Original iPhone 1.0 | `iPhone-2G` | Not written (FirmwareKit does not write it for 1.x); the app treats it as `s5l8900` by machine type: `bootrom=placeholder,iboot=iBoot.bin`, NOR via `-drive if=pflash` | Image store (nand-xor-blank-v2), written in place to state/nand |
| iPod touch 2nd gen 2.2.1 | `iPod-Touch` | `iboot` (after the patch; stock is `bootrom`) | Image store, written in place to state/nand |
| iPhone 4 4.3.5, 5.1.1 | `iPhone-4` | `kboot`, same as 7.1.2 | Page overlay state/overlay |

## 2. Original iPhone (iPhone OS 1.0)

### 2.1 Boot method

Following Light Touch's `BootRecipe.iPod1G` and qemu-ios's `docs/m68/README.md`:

```
-M iPhone-2G,bootrom=<placeholder>,iboot=<device>/iBoot.bin,nand=<state>/nand,imei=…,wifi-mac=…
-drive if=pflash,format=raw,file=<state>/nor.bin
-netdev user,id=wifi0,restrict=on,lan=off -netdev user,id=cell0,restrict=on,lan=off
```

No `-m` (the machine defaults to 128 MB). `imei` and `wifi-mac` come from the lock's `machine`.

**SecureROM**: the comments in `hw/arm/ipod_touch_1g.c` make it clear: the public S5L8900 ROM lacks those two pieces of code anyway, the machine puts the ROM at 0x20000000 only so iBoot can look up the jump table, and on every reset the verification and decryption slots are repointed to stubs in the LLB window (`n45_stage_boot_chain`). In testing, a 4-byte "b ." boots to the home screen, on both the Mac and the simulator. In the app, `s5l8900Bootrom(beside:)` uses `Documents/bootrom/bootrom_s5l8900` if it exists, and otherwise writes a `placeholder-s5l8900-b-self.bin`. Apple's ROM is not in the repository and is not packaged.

**Deep sleep**: upstream does not emulate S5L8900 wake from deep sleep (`docs/ipod1g/README.md` debt item 9, unrelated to the ROM), so it is also marked "Experimental: may hang after the screen turns off" (`实验性：熄屏后可能卡住`) in the list, like the iPod touch 2nd gen. No long standby test was done.

### 2.2 App changes (only `app/ClassicTouch/DeviceProfile.swift`)

- `isS5L8900` (m68ap, n45ap); when the lock has no `boot_strategy`, these two machine types are treated as `s5l8900`, and the rest default to `kboot` as before.
- `boot()` gains `case "s5l8900"`, which builds the arguments above.
- `writesNANDInPlace` changed from "`bootStrategy == "iboot"`" to "iPod touch 2nd gen or S5L8900": both have NAND as an image store that QEMU writes in place, and on first boot the base image's chip files are cloned into `state/nand`. kboot machines are unchanged.
- `experimentalNote` now marks S5L8900 too.
- No new interface text was added (it reuses the existing "Experimental: may hang after the screen turns off"). In `EmulatorViewController`'s boot log, `bootrom=` still records the iPod 2nd gen placeholder file name; the file the original iPhone actually uses can be seen in `argv.json`. That file belongs to the UI session, so I did not touch it.

### 2.3 Observations

- First boot on the Mac: lock screen ("slide to unlock") at 46 seconds; after unlocking there is an "iPhone is activated" notice (mentioned in the upstream docs, first time only); home screen at 51 seconds; home screen idle CPU 4.5%; `system_powerdown` shut down cleanly in 29 seconds, and cold boots from this golden state afterwards work normally.
- Cold booting from the golden state in the simulator, no lock screen appears and it is directly at the home screen at 41 seconds (QEMU's own screen-on record is also 40.9 seconds). For this, `sim-boot.sh` gained "recognizing three or more home screen icon names without having passed the lock screen also counts as reaching the home screen". This measurement run was done before the script change, so the script did not recognize the home screen and ran the full 300 seconds; the numbers are computed from the app's per-second statistics for this run (`stats.csv`): home screen at 41 seconds, an average of 15% over the 30 seconds after the home screen (13% average from 60 to 300 seconds), about 700 MB used. Not remeasured.
- 1.0's SpringBoard icon names are just the `.app` directory names; the home screen and running view are in section 5.

## 3. iPod touch 2nd gen · iPhone OS 2.2.1

### 3.1 The stock approach gets stuck at the SecureROM

FirmwareKit's N72 recipe (`N72Recipe.swift`): for 3.x it outputs a decrypted iBoot.bin and boots straight into iBoot (`boot_strategy iboot`); for 2.x it does not output iBoot.bin and goes "SecureROM → LLB in NOR → iBoot" (`boot_strategy bootrom`). We only have the placeholder ROM, so the stock-made 2.2.1 stops in the ROM's infinite loop as soon as it boots: 60 seconds of black screen, not a single character on the serial port, the guest main core saturating one core, register R15=0 (`work/timeline/try/n72ap-5H11a-rom/setup.json`).

### 3.2 Booting straight into iBoot: reaches SpringBoard, stops at "Connect to iTunes"

QEMU's iPod 2nd gen machine supports `direct-iboot=` (that is how 3.x boots), with iBoot being the decrypted copy from the IPSW (already in FirmwareKit's decryption cache). In testing, iBoot-385.49 reads the DeviceTree from NOR and loads the kernel as usual, SpringBoard comes up and the GL context is created, but the screen shows "Connect to iTunes":

![](img/tl-mac-n72ap-5H11a-stock-connect-itunes.png)

For the cause, see "2.1.1 home screen: lockdownd's brick state" in qemu-ios's `docs/ipod/from-ipsw.md`: 2.x's lockdownd turns on BrickState at first boot, and on the iPod it is turned off only when a paired host sets `TimeIntervalSince1970` (which is what iTunes does on connecting); SpringBoard rereads it only on wake. Light Touch's approach is to set the time once after boot through its USB bridge (a qemu fork of usbmuxd plus libimobiledevice) (`LightTouchServices/Lockdown/lockdown-tz.c`). We have none of that, and should not download it for this. In testing, pressing Home every 15 seconds to wake it and swiping always gave "Connect to iTunes", and then the screen turned off.

### 3.3 Patch: FirmwareKit outputs iBoot.bin for 2.x and pre-writes BrickState

For 1.x (N45Recipe), FirmwareKit already pre-writes `-BrickState = false` into `private/var/root/Library/Lockdown/data_ark.plist` on the volume ("1G has no host USB yet"); for 2.x it does not. The patch `patches/firmwarekit-n72-2x-direct-iboot.patch` changes only `N72Recipe.swift`:

- 2.x also writes out iBoot.bin, and the lock records `boot_strategy iboot`, `direct_iboot true`;
- 2.x pre-writes the same `-BrickState = false` on the volume (owner root).

Method: `cp -c -R upstream/LightTouchMac work/timeline/fk-src`, apply the patch, `swift build -c release` (about 1 minute), and make the device with `work/timeline/fk-build/release/firmwarekit`. `upstream/` was not touched, and the patch passes `git apply --check` cleanly against upstream.

Result: the first boot is at the home screen at 8 seconds (after activation, the iPod's first boot skips the lock screen), and "Connect to iTunes" no longer appears; home screen idle CPU 11%; `system_powerdown` shut down cleanly in 16 seconds. Booting again from the golden state also goes straight to the home screen (8 seconds in the simulator). The upstream docs say the 2.x hold button is not wired up (the power-off gesture cannot be completed), yet this time `system_powerdown` did reach shutdown; not looked into further.

The app needs no code changes for it: the lock says `iboot`, so it takes the same path as 3.1.3 (this 2.x lock can only be produced with the patched FirmwareKit; for a `bootrom` device made with stock FirmwareKit the app still reports "boot_strategy=bootrom is not supported yet" (`还不支持 boot_strategy=bootrom`)). Waking from deep sleep has to go through the ROM, so it hangs just like 3.1.3, and the list already marks it "Experimental".

The 2.2.1 made with stock FirmwareKit (English) is kept in `work/timeline/stock/`.

## 4. iPhone 4 · iOS 4.3.5, 5.1.1

- kboot, like 7.1.2; neither the app nor M0's `bench.py` needs changes.
- **A bug in bench.py**: its `setup` also created a NAND clone in the overlay directory for "nand-xor-ff-v2" NAND like the iPhone 4's, and QEMU requires a v2 overlay to be empty, so it refused to start ("v2 requires an empty or explicitly v2 overlay"). M0's golden states at the time had no such directory, which means this condition was widened later. Changed to create the clone only for blank-v2 image stores like the iPod 2nd gen's (`tools/m0/bench.py`, 7 lines, written to a new file and then renamed).
- 4.3.5: no Setup Assistant (4.x activation goes through iTunes, and FirmwareKit has already written it in); it boots to the lock screen, and sliding it open gives the home screen. On the Mac the lock screen appears at 41 seconds (load about 6; `bench.py` asks the guest agent for the foreground once a second, so the granularity is about 1 second). At one point the first boot of a simulator I had just created pushed the load to 138; the Chinese version was running then (48 seconds), and it does not count. In the simulator: lock screen 44 seconds, home screen 52 seconds, twice as slow as 5.1.1: during boot there are two stretches (12 to 16 seconds and 23 to 37 seconds) where CPU drops to around 20% and the guest is waiting for something, about 20 seconds in total; the cause was not investigated.
- 5.1.1: has the full Setup Assistant, which `bench.py` completed via OCR (English, United States, location off, skip Wi-Fi, new iPhone, agree to the terms, don't send diagnostics; 69 seconds), without getting stuck on the Apple ID page (networking is restrict=on). In the simulator: lock screen 21 seconds, home screen 30 seconds.
- On both, `system_powerdown` stops at "slide to power off" and QMP quits after 120 seconds, the same as M0's iOS 7 (the golden state is equivalent to pulling the battery; HFS+ is journaled, and later boots are all normal).
- In the simulator the app does not attach usb-kbd by default, and no "Cannot Use Device" alert like iOS 7's was seen. On the Mac, bench.py attaches usb-kbd following Light Touch, and the OCR logs of both setups do not show this alert either (whether iOS 4 and 5 have a similar problem was not specifically tested).

## 5. The app in the iOS Simulator

A dedicated simulator, "ClassicTouch Timeline" (iPhone 18 Pro, iOS 27.2, UDID in `work/timeline/sim-udid`, now shut down); the app is built separately into `work/ios/DerivedData-tl` (Debug, including the `DeviceProfile.swift` changes and the UI session's latest code at the time; it compiles). Measured with `SIM_UDID=… IDLE=30 scripts/ios/sim-boot.sh <id> jit 300` (`sim-boot.sh` already had the `SIM_UDID` override; no new environment variable was added), one device after another, one run each, with load 3.4 to 5.4 at the start.

| Device | Lock screen | Home screen | QEMU screen on | Home screen idle CPU | Peak memory use |
|---|---:|---:|---:|---:|---:|
| Original iPhone 1.0 | No lock screen | 41 s | 40.9 s | 15% (30 s) | 709 MB |
| iPod touch 2nd gen 2.2.1 | No lock screen | 8 s | 7.4 s | 18% (26 s) | 577 MB |
| iPhone 4 4.3.5 | 44 s | 52 s | 0.8 s | 20% (26 s) | 785 MB |
| iPhone 4 5.1.1 | 21 s | 30 s | 0.8 s | 22% (26 s) | 860 MB |

For reference (earlier reports, same kind of simulator, JIT 256 MB): iPod 3.1.3 lock screen 10 seconds, home screen 19 seconds, idle CPU 17%; 3GS 6.1.6 lock screen 16 to 18 seconds, home screen 45 seconds, idle CPU 13% to 14%. The original iPhone's slow boot is mostly the system itself (per the upstream docs, SpringBoard comes up at about 100 seconds of guest time).

Home screens (guest screens saved by the app in the simulator):

| Original iPhone · 1.0 | iPod touch 2nd gen · 2.2.1 | iPhone 4 · 4.3.5 | iPhone 4 · 5.1.1 |
|---|---|---|---|
| ![](img/tl-sim-m68ap-1A543a-home.png) | ![](img/tl-sim-n72ap-5H11a-home.png) | ![](img/tl-sim-n90ap-8L1-home.png) | ![](img/tl-sim-n90ap-9B206-home.png) |

The app's running view (the UI session's new look is hooked up; the top shows "2007 · iPhone (original) · iPhone OS 1.0 · JIT") and the Timeline on the home page (7 devices placed in the simulator, app opened normally without test arguments):

| Running view | Timeline on the home page |
|---|---|
| ![](img/tl-sim-m68ap-1A543a-app.png) | ![](img/tl-sim-library.png) |

The Timeline is sorted correctly by year: 2007 original iPhone, 2008 iPod 2.2.1, 2009 iPod 3.1.3, 2010 iPhone 4 4.3.5, 2011 iPhone 4 5.1.1, 2012 3GS, 2013 iPhone 4 7.1.2; the 1.0, 2.2.1 and 3.1.3 rows carry "Experimental". With the original iPhone device imported, 2007 shows as a normal row; `Era.runnable = 2...7` only affects the label of the "not imported" cell (right now 2007 would be labeled "Later" (`以后`)). **Decision session, please pass this to the UI session: change it to `1...7`**, and the comment in `Theme.swift` ("iPhone OS 1 … needs pflash, not done yet") needs to be updated along with it.

Home screens on the Mac (copies of `work/states/<id>/home-after-setup.png`): `img/tl-mac-m68ap-1A543a-home.png`, `tl-mac-n72ap-5H11a-home.png`, `tl-mac-n90ap-8L1-home.png`, `tl-mac-n90ap-9B206-home.png`.

## 6. Language

FirmwareKit's `--language` and `--keyboards` default to the Mac's current settings. At M0's time the Mac was en-AU; this time the Mac is already `zh-Hans-US`, so the first 4 devices made were all in Chinese (the 4.3.5 home screen showed Messages, Calendar, Photos… in Chinese (`短信、日历、照片……`), and 1.0's Calendar showed Monday (`星期一`)). I remade the 4 devices with `--language en-AU --keyboards com.apple.keylayout.US`, because: it matches the three devices already in the app; the OCR in `sim-boot.sh` and `bench.py` recognizes only English ("slide to unlock", "Settings", the Setup Assistant button names), and the Chinese version cannot get through the 5.1.1 Setup Assistant. The Chinese versions are kept in `work/timeline/zh/` (4.4 GB, can be deleted if not wanted). For a Chinese guest, the scripts would first need a Chinese word list; that is for the user to decide.

## 7. Packs (for installing on the phone later)

`work/ios/packs/`; each contains the device base image and its golden state (`golden-state/`, used with `-resetstate`):

| Pack | Size |
|---|---:|
| m68ap-1A543a.ctpack | 1.11 GB |
| n72ap-5H11a.ctpack | 1.02 GB |
| n90ap-8L1.ctpack | 1.49 GB |
| n90ap-9B206.ctpack | 1.53 GB |

The NAND of 1.0 and 2.2.1 is an image store written in place, and the golden state is a whole copy of the NAND (APFS clones take no space on the Mac, but in a pack they become two copies), so these packs are twice the size of the base image alone; without the golden state each would be about 0.5 GB, and a user booting from the list boots from the base image anyway (1.0's first boot shows an extra "iPhone is activated" notice). The packs for the two new machine types were verified in the simulator with the app's import flow: put into `Documents/import/`, unpacked automatically on opening the app (1.3 seconds, 1.1 seconds), golden states present.

## 8. What is still missing before installing on the phone

The second round (section 11) has done the preparation for items 1 to 3; what remains:

1. Run `scripts/ios/device-install.sh` once on the phone (install the app, transfer the 4 packs of about 5.2 GB, boot each once), see section 11.4.
2. None of this has been tried on the phone yet: booting 1.0 and 2.2.1 with JIT (StikDebug), GL on iOS 4/5; going by the simulator numbers, all are expected to reach the home screen.
3. 1.0 and 2.2.1 may not wake after the screen turns off and they enter deep sleep (already marked "Experimental"); no long standby test was done.
4. When making devices on the phone later (M3), 2.x needs FirmwareKit with `firmwarekit-n72-2x-direct-iboot.patch` applied.
5. For the user to decide: guest language (section 6).

## 9. Reproduction

```bash
# firmware (URLs and sha1 from upstream/LightTouchMac/LightTouchMac/Resources/firmware-catalog.json, downloaded to work/firmware/)
# FirmwareKit (stock) makes 1.0, 4.3.5, 5.1.1
for id in m68ap-1A543a:iPhone1,1_1.0_1A543a n90ap-8L1:iPhone3,1_4.3.5_8L1 n90ap-9B206:iPhone3,1_5.1.1_9B206; do
  dev=${id%%:*}; ipsw=${id#*:}
  work/build-firmwarekit/release/firmwarekit create \
    --catalog upstream/LightTouchMac/LightTouchMac/Resources/firmware-catalog.json --id $dev \
    --ipsw work/firmware/${ipsw}_Restore.ipsw --out work/devices/$dev \
    --helper work/tools/helper-shim/LightTouchDevice --cache work/cache \
    --guest-tools work/guest-artifacts/ipad-guest-tools \
    --language en-AU --keyboards com.apple.keylayout.US \
    > work/devices/create-$dev.jsonl 2> work/devices/create-$dev.err
done
# patched FirmwareKit makes 2.2.1
cp -c -R upstream/LightTouchMac work/timeline/fk-src
(cd work/timeline/fk-src && git apply ../../../patches/firmwarekit-n72-2x-direct-iboot.patch)
swift build -c release -j 6 --package-path work/timeline/fk-src/Packages/FirmwareKit --scratch-path work/timeline/fk-build
work/timeline/fk-build/release/firmwarekit create … --id n72ap-5H11a --ipsw work/firmware/iPod2,1_2.2.1_5H11a_Restore.ipsw … (same as above)

# first boot and golden state on the Mac (tl.py for 1.x and 2.x; M0's bench.py for iOS 4 and 5)
python3 tools/timeline/tl.py setup --device work/devices/m68ap-1A543a --golden work/states/m68ap-1A543a
python3 tools/timeline/tl.py setup --device work/devices/n72ap-5H11a --golden work/states/n72ap-5H11a --wake-after 40 --powerdown 30
python3 tools/m0/bench.py setup --device work/devices/n90ap-8L1 --golden work/states/n90ap-8L1
python3 tools/m0/bench.py setup --device work/devices/n90ap-9B206 --golden work/states/n90ap-9B206

# simulator (first clone the device and golden state into work/ios/devices/<id>, <id>-golden/state and the app container's Documents/devices/)
SIM_UDID=$(cat work/timeline/sim-udid) IDLE=30 scripts/ios/sim-boot.sh m68ap-1A543a jit 300

# packs
python3 -I scripts/ios/pack-device.py work/ios/packs/m68ap-1A543a.ctpack \
  work/ios/devices/m68ap-1A543a=devices/m68ap-1A543a work/ios/devices/m68ap-1A543a-golden/state=devices/m68ap-1A543a/golden-state
```

`tools/timeline/tl.py`: for 1.x and 2.x, which have no guest agent; it does a screendump plus OCR every second to detect the lock screen and home screen (also recognizing "straight to the home screen"), and reuses `bench.py`'s `Machine` for machine control; `--direct-iboot`, `--wake-after` and `--reuse-state` were added while troubleshooting 2.2.1.

## 10. Changes and outputs

- In the repository (not committed):
  - `app/ClassicTouch/DeviceProfile.swift`: the `s5l8900` boot method, `s5l8900Bootrom`, the in-place NAND check, the experimental note (section 2.2)
  - `patches/firmwarekit-n72-2x-direct-iboot.patch` (new)
  - `tools/timeline/tl.py` (new)
  - `tools/m0/bench.py`: the NAND clone condition (section 4)
  - `scripts/ios/sim-boot.sh`: recognizes "straight to the home screen without the lock screen" (default behavior unchanged; written to a new file and then renamed)
  - This report and `docs/reports/img/tl-*.png` (11 images, all checked by eye)
- In `work/` (not committed): `work/firmware/` 4 IPSWs and download logs; `work/devices/` 4 devices; `work/states/` 4 golden states (including setup-run screenshots and logs); `work/ios/devices/` clones; `work/ios/packs/` 4 packs; `work/timeline/` (`logs/` per-step logs, `zh/` Chinese devices, `stock/` stock 2.2.1, `try/` 2.2.1 troubleshooting records, `fk-src/` and `fk-build/` patched FirmwareKit, `placeholder/` placeholder ROM).
- Simulator "ClassicTouch Timeline" (shut down); the app container has clones of 7 devices and the records of each run (`Documents/logs/`).

## 11. Second round: phone-free preparation before installing on the phone (2026-11-02)

A task forwarded by the decision session (approved by the user; this round does not touch the phone).

### 11.1 Changes

| File | What changed |
|---|---|
| `app/ClassicTouch/Theme.swift` | `Era.runnable` changed from `2...7` to `1...7`, and the comment above it corrected (iPhone OS 1 goes through DeviceProfile's s5l8900). Only these few lines touched |
| `app/ClassicTouch/GuestText.swift` | Home screen icon names extracted into `homeMarks`, added `homeMarkCount` (how many distinct icon names were recognized); `isHomeScreen` behavior unchanged |
| `app/ClassicTouch/EmulatorViewController.swift` | autodrive's home screen condition: previously the lock screen had to be recognized first; now, when no lock screen was recognized, recognizing three or more home screen icon names also counts as reaching the home screen (only `home_seen` is recorded, no `lock_seen`). 3 lines, nothing else touched |
| `scripts/ios/device-boot.sh` | The non-STIK branch (OCR on the Mac side) gets the same "straight to the home screen" check; the STIK branch already takes `lock_seen` and `home_seen` from events.log, and prints "Lock screen: not reached" (`锁屏：未到达`) when there is no lock screen. Written to a new file and then renamed |
| `scripts/ios/device-install.sh` | New: one-step install (section 11.3) |

The last two app files belong to the UI session; this time the decision session assigned the work, the changes are only for autodrive, and they have been verified in the simulator (11.2).

### 11.2 What was verified in the simulator (ClassicTouch Timeline, freshly built simulator build)

| Item | Result |
|---|---|
| Import all 4 packs at once with the app's import flow | Put into `Documents/import/`; after opening the app all were unpacked within 12 seconds (`import.log`: 2.4, 1.2, 2.1, 2.2 seconds), golden states all present |
| Home page, without the original iPhone imported | The 2007 cell is "iPhone OS 1 · Not imported yet" (`还没导入`), and only 2014–16 show "Later" (`img/tl-sim-library-no-1x.png`) |
| autodrive boots 1.0 (`-resetstate YES`, from the golden state, same parameters as real-device STIK mode) | `home_seen` at 43.6 seconds (no `lock_seen`), `auto_quit` after 20 seconds idle, QEMU exits cleanly |
| autodrive boots 2.2.1 | `home_seen` at 9.7 seconds, `auto_quit` after idle |
| List path: `-fakejit on -select m68ap-1A543a`, with state deleted first (equivalent to just imported, first boot from the base image), plus autodrive | `boot config=list`, lock screen recognized at 43.5 seconds and unlocked automatically, home screen at 51.6 seconds, exits after idle |

While these runs were going, another session was compiling QEMU, with load 20 to 44, so only function is assessed; the times don't count.

**"iPhone is activated"**: appears only on the first boot from the base image; it is a banner on the lock screen with no buttons (image below), gone after slide to unlock; it does not block autodrive and needs no tap. Real-device measurements boot from the golden state with `-resetstate`, so it never appears there.

![](img/tl-sim-m68ap-1A543a-activated.png)

### 11.3 Device build of the app

`xcodebuild … -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath work/ios/DerivedData-tl -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID>`: **BUILD SUCCEEDED**, signature verification passed. The team ID was read at build time from the previously signed app (`codesign -dv`) into a command-line variable and was not written into any file. Output: `work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app`, containing the two QEMU libraries (`work/ios/build-qemu-iphoneos-{jit,interp}`, with the iOS 7 optimization patches and the `iPhone-2G` machine). The code is everything as of now: the UI session's new look, the iOS 7 optimizations, `DeviceProfile.swift`, and this round's autodrive. Not installed.

### 11.4 One-step install

```bash
scripts/ios/device-install.sh
```

It does, in order:

1. Checks the app signature, that the 4 packs are present, that AFC can connect to the phone, and that the phone has enough free space (total pack size plus 2 GB, about 7.2 GB); stops if it cannot connect or there is not enough space.
2. `devicectl device install app` installs over the existing app (same bundle ID, Documents is kept, the three devices already on the phone are left alone and not re-sent).
3. Transfers the 4 packs over AFC into the app's `Documents/import/` (in the order 2.2.1, 1.0, 4.3.5, 5.1.1).
4. Opens the app and waits until every pack has a result in `import.log`; stops on any "failed" (`失败`). If the phone is locked and the app cannot be opened, it retries every 5 seconds for 2 minutes.
5. For each device, `STIK=1 IDLE=30 scripts/ios/device-boot.sh <id> jit 600`: StikDebug provides JIT, the app cold boots from the golden state, autodrive recognizes the lock screen and home screen, unlocks, idles for 30 seconds, and exits; screenshots (guest every 5 seconds, app window) and statistics are fetched to `work/ios/runs/device/<run>/`.
6. Each device's lock screen, home screen and idle CPU are printed to the screen and to `work/ios/runs/device/install-<time>/install.log`.

The check step was tried with a fake UDID (it stops when it cannot connect); the later steps need the phone and have not been run. `SKIP_INSTALL=1`, `SKIP_UPLOAD=1` and `SKIP_BOOT=1` run only some of the steps, and giving pack paths after the command installs only those packs.

**Estimated time**: installing the app, half a minute; transferring packs at the earlier AFC rate of about 34 MB/s, 2.5 to 3 minutes; import, under half a minute; booting the four devices, 1 to 2 minutes each (StikDebug handoff about 10 seconds, 10 to 50 seconds to the home screen, 30 seconds idle, a dozen or so seconds fetching files). **About 10 to 15 minutes in total.**

**What the user needs to do then**:

- Plug in the cable (AFC goes over USB), unlock the phone and keep the screen on; during the 3 minutes of pack transfer the app is not in the foreground and the phone may auto-lock; the script waits when it needs to open the app, so if you see it locked, unlock it (only unlock; don't tap anything in the app).
- Turn on LocalDevVPN (StikDebug needs it to provide JIT).
- Don't use iPhone Mirroring (while it is on, devicectl launches are refused).
- At least about 7.2 GB of free space on the phone.
- Don't touch the screen during the few minutes of booting.

**What you will see on the phone**: the app icon refreshes (new version installed); the app opens on its home page with "Importing" (`正在导入`) at the top, then four rows, 2007, 2008, 2010 and 2011, appear in the Timeline; then four times: StikDebug flashes briefly, back to the app, the screen shows the old system booting (black screen or Apple logo; 1.0 takes about 40 seconds), the two iPhone 4 devices slide open the lock screen by themselves, 1.0 and 2.2.1 go straight to the home screen, it stays there for 30 seconds, the app closes itself, and the next device follows. At the end the phone is left on its home screen (the app has exited).
