# Putting the app on the iPhone 14 Pro

**Latest conclusions (section 7):** the app is installed and opens, and both packs were transferred and imported. JIT from tethered lldb: with the packet log on by default, all 5 attaches succeeded on the first attempt; without it, all 9 failed, root cause not found. All 5 runs reached the lock screen (9.3.5 at 128 to 133 seconds, 7.1.2 at 78 to 80 seconds), but only 1 reached the home screen; the others got stuck on the app's own slide to unlock. The "Cannot Use Device" on the 7.1.2 lock screen was traced to DeviceOMatic and is now disabled. The problem of the app unpacking a pack before its transfer finished is also fixed. Sections 0 to 6 are the earlier record.

- Date: 2026-11-04
- Execution session: a5-nand. The user's words (relayed by the decision session): "Now put the app on the iPhone 14 pro".
- Phone: iPhone 14 Pro (iPhone15,2, iOS 27.0.1, 24A446), connected by cable, devicectl shows it as paired. Signing uses the only Apple Development certificate on the Mac (the user's own paid team); registering this phone with the team is required by the user's request.
- Not done: no commit, no push; the iPhone 18 Pro not touched; no phone settings changed; UDIDs, team ID and pairing files stay out of the repository.

## 0. Conclusions

1. **Everything that could be done first is built**, all with the current patch set (the four iOS patches, `a5-n78-skeleton.patch` with 18 files, `a5-n78-ios-ui.patch`):
   - the device dependency sysroot (`work/ios/sysroot-iphoneos-arm64`, 7 static libraries);
   - the device QEMU and dylib, one each for JIT and the interpreter: `libqemu-arm-jit.dylib` (35.9 MB), `libqemu-arm-interp.dylib` (35.9 MB), each exporting 58 `qemu_ios_*` symbols, platform iOS, minimum 16.0;
   - the Debug-iphoneos app (`work/ios/DerivedData-tl/Build/Products/Debug-iphoneos/ClassicTouch.app`, which is the path `device-install.sh` looks for by default), with both dylibs embedded and the signature verified;
   - the simulator QEMU, dylib and app were also rebuilt with the new patches.
2. **Both packs work in the simulator, so the golden state does not need redoing**: 9.3.5 lock screen at 103 seconds, home screen at 113 seconds; 7.1.2 lock screen at 41 seconds, home screen at 49 seconds (last round 66 to 104 seconds and 37 seconds). The new QEMU handshakes normally with the old front end on the packs' disks (protocol 1, name table ad3b3412, 329 slots recognized). **[verified: the summaries and QEMU logs of the two `sim-boot.sh` runs]**
3. **Stuck on signing; the user needs to do one thing on the Mac (still the case after a retry with Developer Mode on, see section 5)**: Xcode **is not signed in to any Apple account** (`xcodebuild` reports `No Accounts`), so it cannot automatically register the 14 Pro with the team or generate a new provisioning profile. The locally cached "iOS Team Provisioning Profile: *" (valid until 2027-10-18) lists 4 devices, **not including the 14 Pro**, so an app signed with it cannot be installed on this phone. The user needs to sign in with the paid team's Apple ID in Xcode → Settings → Accounts; after that I rerun the build with `-allowProvisioningDeviceRegistration`, and Xcode registers the phone and regenerates the provisioning profile. **[verified: `work/ios/xcodebuild-os-14pro.log`; the provisioning profile checked item by item]**
4. **What to ask about after installing**: under `work/ios/` this Mac has **no StikDebug source or build, no `idevice-tools`, and no pairing file** (M1 kept them in `work/ios/stikdebug/`, `work/ios/tools/idevice-tools-0.1.68/` and `work/ios/secrets/`; none of them are there now). The pack transfer and log retrieval in `device-install.sh` and `device-boot.sh` all go through the AFC of `idevice-tools`. Whether StikDebug is on the phone can only be seen once Developer Mode is on.
5. Developer Mode: the decision session has asked the user to turn it on; I did not touch the phone's settings.

## 1. Switching patches in the iOS working tree

- `work/ios/qemu-ios` still had the old patches from the previous round (a5-app). `build-qemu.sh` only accepts two states, "pristine upstream" or "current patch set applied", so I first backed up the 21 files it had changed into `work/ios/qemu-ios-oldpatches.tar`, then restored it to pristine upstream (`git checkout` plus deleting the 7 files the patches had created) and handed it to `build-qemu.sh`.
- The first build (simulator JIT) applied the six patches `ios-eagl-es2`, `ios-gles-perf`, `ios-host-gles-option`, `ios-txm-jit-protocol`, `a5-n78-skeleton` and `a5-n78-ios-ui` in order, and later builds all judged the tree "already applied". **[verified: `work/ios/build-qemu-sim-jit-a6.log`]**

## 2. What was built

| Item | Command | Result | Log |
|---|---|---|---|
| Simulator QEMU (JIT) | `TCG=jit scripts/ios/build-qemu.sh iphonesimulator` | Built | `work/ios/build-qemu-sim-jit-a6.log` |
| Simulator dylib | `TCG=jit scripts/ios/make-dylib.sh iphonesimulator` | 36 MB, 58 exports | `make-dylib-sim-jit-a6.log` |
| Simulator app | `xcodebuild … -sdk iphonesimulator -derivedDataPath work/ios/DerivedData-a5` | BUILD SUCCEEDED, 1 dylib embedded | `xcodebuild-sim-a6.log` |
| Device dependencies | `scripts/ios/build-deps.sh iphoneos` | 7 libraries | `build-deps-os.log` |
| Device QEMU (JIT, interpreter) | With `TCG=jit` and with `TCG=interp`, run `build-qemu.sh iphoneos` once each | Both built | `build-qemu-os-jit.log`, `build-qemu-os-interp.log` |
| Device dylib | With `TCG=jit` and with `TCG=interp`, run `make-dylib.sh iphoneos` once each | 35.9 MB each, 58 exports | `make-dylib-os-*.log` |
| Device app (target 14 Pro) | `xcodebuild … -destination id=<14 Pro> -allowProvisioningUpdates -allowProvisioningDeviceRegistration` | **Failed**: `No Accounts`; the provisioning profile does not include this phone | `xcodebuild-os-14pro.log` |
| Device app (generic) | `xcodebuild … -destination generic/platform=iOS` | BUILD SUCCEEDED, 2 dylibs embedded, signed with the existing local wildcard provisioning profile | `xcodebuild-os-generic.log` |

- The source tarballs for the build were downloaded in the previous round; nothing was downloaded this round.
- The build logs contain the team ID and the phone's UDID; they are all in `work/` and stay out of the repository. The 14 Pro's UDID is stored in `work/ios/phone14-udid` (600, ignored by git); this Mac never had a `work/ios/phone-udid`, and it was left alone.

## 3. Simulator check

Simulator "ClassicTouch iPhone 18 Pro" (iOS 27.2), with the new app installed, using the two devices imported from packs into the container last round; `sim-boot.sh` cold boots from the device's base image each time (that is, the disk and NAND from the pack). During the 9.3.5 run the device QEMU was being built at the same time and took part of the CPU.

| Run | System | Lock screen | Home screen | Idle home screen CPU | Max footprint |
|---|---|---:|---:|---:|---:|
| `20261104-205533-n78ap-13G36-jit` | 9.3.5 | 103 s | 113 s | 107% | 1143 MB |
| `20261104-205806-n78ap-11D257-jit` | 7.1.2 | 41 s | 49 s | 47% | 1029 MB |

- Both exited normally (`qemu_exit status=0`), and the run directories were copied back to `work/ios/runs/`.
- The GL front end on the packs' disks was built last round (without this round's TLS slot change and the 4 extra words reserved before the macro context). The new QEMU handshakes with it normally: `protocol 1, name table ad3b3412 (host: 1, ad3b3412)`, `1035 slots, 329 named`. So the packs do not need redoing. These two front-end changes only take effect on iOS 10 (Darwin 16) and have little effect on 9.3.5 and 7.1.2 anyway. **[verified: the QEMU log in the 9.3.5 run directory]**
- The simulator was shut down.

## 4. Steps once the user has acted

1. **The user signs in to Xcode with the team's Apple ID** (Xcode → Settings → Accounts), and turns on Developer Mode on the phone (the phone restarts after that, and it has to be confirmed on the phone).
2. I rerun the device build (target 14 Pro, `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`) and check that the new provisioning profile includes this phone.
3. Install the app: `PHONE=$(cat work/ios/phone14-udid) SKIP_UPLOAD=1 SKIP_BOOT=1 scripts/ios/device-install.sh`, or directly `xcrun devicectl device install app`. The first time a development app is opened, the phone may require trusting the developer in "Settings → General → VPN & Device Management".
4. Check StikDebug: whether it is installed on the phone, and which version. If not, the source has to be downloaded again (StikDebug 3.2.0 on GitHub, plus CodeEditorView and Rearrange pulled by SPM), rebuilt and re-signed.
5. Transferring packs first needs `idevice-tools` (M1 used `idevice-tools-macos-arm-v0.1.68.zip` from idevice's official release page, about 5 MB). It is also possible to skip the download and transfer into the app container with `devicectl device copy to` (the two packs total 5.5 GB), but M1 noted that devicectl's file service hangs while LocalDevVPN is on, and the scripts would need changing too.
6. Generate the RemotePairing pairing file StikDebug needs (over USB, `idevice-tools remotepairing_lockdown pair`) and put it in `work/ios/secrets/`.
7. Check the phone's free space (the two packs are 5.5 GB, plus 2 GB of headroom for unpacking), transfer the 9.3.5 and 7.1.2 packs, and boot each once with `STIK=1 device-boot.sh` for timing.

Step 1 is for the user; steps 4 to 6 involve downloads and pairing files, so, as the decision session asked, I ask first.

## 5. After Developer Mode was turned on (same day, second round)

The decision session relayed: the user has turned on Developer Mode on the 14 Pro (devicectl shows `Developer Mode Status: Enabled`); the phone has no StikDebug and no ClassicTouch, and has the App Store version of LocalDevVPN 1.3.0. The user decided "test tethered first, the rest later": JIT only from lldb on the Mac, no StikDebug install, no pairing files.

- **Still cannot install.** Rerunning the build targeting the 14 Pro still reports `No Accounts` and "the provisioning profile does not include this phone" (`work/ios/xcodebuild-os-14pro-2.log`). Trying to install the generic build (signed with the existing local wildcard provisioning profile), the phone refuses: `Failed to install embedded profile … 0xe8008012 (This provisioning profile cannot be installed on this device.)`, `ApplicationVerificationFailed` (`work/ios/devicectl-install-14pro.log`). The failed install attempt changed nothing on the phone. **[verified]**
- So no pack was transferred or imported, and tethered JIT was not started. **The only blocker is that Xcode has no Apple account for the team**: once the user signs in under Xcode → Settings → Accounts, I rerun the build, Xcode registers this phone and generates a provisioning profile that includes it, and then the app can be installed.
- After installing there are two more things to ask about first:
  - Both modes of `device-boot.sh` (tethered lldb, StikDebug) transfer files and fetch logs through the AFC of `work/ios/tools/idevice-tools-0.1.68`, which this Mac does not have. Either download this tool (`idevice-tools-macos-arm-v0.1.68.zip` from idevice's official release page, about 5 MB), or skip the download and change the scripts' file operations to `devicectl device copy`, which the two packs (5.5 GB in total) would also go through.
  - When lldb attaches to a process on iOS 27.0.1, Xcode may need to prepare debugging support for this version (this Mac only has the one for iPhone19,2 27.2). If a download is needed, stop and report.

## 6. After the user signed in to Xcode: installed, imported, tethered JIT boot (same day, third round)

The user signed in to Xcode with the team's Apple ID.

**Signing and installation**
- Rerunning the build targeting the 14 Pro (`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`) succeeded; Xcode registered the phone with the team, and the new "iOS Team Provisioning Profile: *" is valid until 2027-11-04 and includes the 14 Pro. **[verified: the embedded provisioning profile checked item by item]**
- The first incremental build replaced the provisioning profile, resources and dylibs but did not re-sign the app itself (not a single `CodeSign` line in the log), and `codesign --verify` reported modified sealed resources. After deleting `ClassicTouch.app` from the build products and rebuilding, the signature verified.
- Installed with `devicectl device install app` and opened with `devicectl device process launch`; the home page came up, and the phone did not ask to trust the developer separately. **[verified: `work/ios/devicectl-install-14pro-2.log`, `devicectl-launch-14pro.log`]**

**Pack transfer and import** (`idevice-tools` was not downloaded; `devicectl device copy to` into the app's `Documents/import/` was used instead)
- 9.3.5 (2.6 GB) in 86 seconds, 7.1.2 (2.9 GB) in 97 seconds, about 30 MB/s. devicectl only reports the total capacity (1 TB) and cannot read free space, so space was not checked before transferring.
- Import: 9.3.5 unpacked in 5.5 seconds, 7.1.2 in 6.1 seconds. The first line of `import.log` is "n78ap-13G36.ctpack failed: ctpack ended early": the app was already open during the transfer and tried to unpack the pack before the transfer finished; after reopening the app, unpacking succeeded. The app should skip files that are still being written, or the transfer should use a temporary name and rename when done; this was not changed here. **[verified: the retrieved `import.log`]**

**Tethered JIT boot** (on the Mac, `lldb_jit_runner.py` attaches over USB, answers the `brk #0xf00d` with which QEMU prepares the code buffer, writes the 256 MB page by page, then detaches; the app uses `-autodrive YES -idle 20` to recognize the lock screen, unlock, idle and exit on its own)
- File operations in both modes of `device-boot.sh` go through `idevice-tools`, so I wrote a variant `devboot14.sh` in the session's temporary directory: the attach part copied as is, the file operations changed to `devicectl device info files` and `device copy from`; it is not in the repository.
- **In the first 9.3.5 invocation (`boot-13G36-1.log`) all three attach attempts failed**: lldb attached, but when stopped no thread had a stop reason, every "continue" reported `Resume timed out`, it gave up after 3 in a row, and QEMU never reached the `brk`. The second invocation right after it (with `LLDB_PACKET_LOG`) attached on the first attempt; 7.1.2 also succeeded on the first attempt. The cause of the failures was not found. A comment in `device-boot.sh` had noted this happening about once every 4 to 5 attaches; this time it was 3 out of 5. The packet logs are in the session's temporary directory.
- Every time, `device select <CoreDevice identifier>` in the script reported failure, but attaching still succeeded. When lldb is run on its own, `device select` succeeds, and in lldb's device list only the 14 Pro is connected (the 18 Pro shows as disconnected), so it was the 14 Pro that was attached to. **[verified: `device list` in `xcrun lldb`]**
- Neither Xcode nor lldb asked to download device symbols for 27.0.1, and there was no prompt about a personalized developer disk image; lldb only reads the modules' segment information (`memory-module-load-level minimal` in the script).

| Run (`work/ios/runs/device14/`) | System | Code buffer prepared | First frame | Lock screen | Home screen | Unlock attempts | Idle home screen CPU | Max footprint | Min available memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `20261104-211018-n78ap-13G36-jit` | 9.3.5 | 44.7 s | 45.5 s | 123 s | 141 s | 2 | 104% | 1204 MB | 1868 MB |
| `20261104-211336-n78ap-11D257-jit` | 7.1.2 | 40.3 s | 41.0 s | 82 s | 142 s | 5 | 43% | 1096 MB | 1976 MB |

- Times are counted from when the app calls `qemu_ios_main`; the first 40-odd seconds are lldb writing the 256 MB code buffer page by page over USB (StikDebug does the same thing locally on the 18 Pro in 0.7 to 0.85 seconds, M1 stage 3). Without that part, 9.3.5 reaches the lock screen in about 78 seconds and 7.1.2 in about 41 seconds. Both exited normally (`auto_quit`, `qemu_exit status=0`).
- The 7.1.2 lock screen carried a "Cannot Use Device: QEMU USB HARDDRIVE: The connected device is not supported." notification (DeviceOMatic treats the USB root disk as an external device; for 10.3.4 it is disabled in the disk fix-up, but not in the 7.1.2 pack), overlapping the big clock, and unlocking took 5 tries to reach the home screen; in the simulator it took one. The reason was not looked into closely.
- Screenshots (all guest frames, no personal information):
  - 9.3.5: `docs/reports/img/ios14pro-935-lock.png` (at 123 seconds), `ios14pro-935-home.png` (at 145 seconds), `ios14pro-935-window.png` (at 155 seconds, the app window);
  - 7.1.2: `ios14pro-712-lock.png` (at 110 seconds, with that notification), `ios14pro-712-home.png` (at 149 seconds).
- At wrap-up there was still a ClassicTouch process on the phone (PID 729, newer than the one the script ended; where it came from was not investigated); it was ended. No debugger or devicectl was left running on the Mac.

**Not done yet**: the interpreter was not tested; StikDebug was not installed (the user decided "test tethered first, the rest later"); the phone's free space was not checked; the temporary scripts for the pack transfer and boot are not in the repository.

## 7. Fourth round: scripts without idevice-tools, import fix, attach statistics, the 7.1.2 notification

The user said "keep going". This round cleans up the problems section 6 exposed; nothing was downloaded, and the 18 Pro was not touched.

### 7.1 Scripts use devicectl when idevice-tools is missing

- New file `scripts/ios/devfiles.sh`: file operations in the app container (Documents), providing three functions (list a directory, fetch a file, put a file), with two backends.
  - With `work/ios/tools/idevice-tools-0.1.68` present, AFC as before;
  - Without it (or with `FILES=devicectl`), `devicectl device info files`, `copy from` and `copy to`. `copy to` creates directories automatically.
- `device-boot.sh` and `device-install.sh` now use these three functions. The AFC path only switched to the shared functions and its logic is unchanged, but this Mac does not have the tool, so it could not be tested. `devicectl` cannot read free space (`device info details` only has the total capacity), so on that path `device-install.sh` only prints a note and does not check space.
- `device-app-flow.sh` was not changed and still only works over AFC.
- Measured: `device-install.sh` (over `devicectl`) transferred the new 7.1.2 pack in 82 seconds and the app unpacked it in 6.3 seconds, 96 seconds in all. **[verified: `work/ios/runs/device/install-20261104-221242`]**
- `devicectl` has no delete command. The experiments left two small files in the app's `Documents/probe-dir/` (17 bytes and 6 bytes; the second was originally a 2.5 GB test file, overwritten with a small one); they do not affect the app.

### 7.2 The app unpacked a pack before its transfer finished (fixed)

- Transferring a 2.5 GB file with `devicectl` while polling its size on the phone (`work/ios/runs/device14/copy-size-probe.txt`) shows three phases:
  - it first creates a 0-byte file and waits about 5 seconds before writing;
  - then it grows by about 40 MB per second, with the modification time changing along with it;
  - when done, it sets the modification time back to that of the original file on the Mac.
- The app's old rule was "if the modification time has not changed for 3 seconds, the copy is done"; those first 5 seconds met it exactly, so it unpacked an empty file and reported "ctpack ended early". After an unpack failure it only retried once the file's size or modification time changed, but a growing file does not trigger a directory event, so nothing scanned again, and it had to wait for the next time the app was opened.
- Fix (`app/ClassicTouch/ImportManager.swift`):
  - 0-byte packs are not unpacked;
  - for each pack it records since when the size has stopped changing, and unpacks only when both the size and the modification time have not changed for 3 seconds;
  - while the directory still has packs that failed to unpack, it rescans every 3 seconds.
- Check: with `import/` emptied first, the 7.1.2 pack was transferred while the app was open (82 seconds) and unpacked successfully on the first try (5.9 seconds), with no failure line. **[verified: the retrieved `import-4.log`]** The first check did not exercise this path: the complete pack left by the failure in the previous round was still in `import/`, and `devicectl` saw the same file and skipped it in 1 second.

### 7.3 Tethered lldb attach: reliable only with the packet log on

- **Behavior**: attaching succeeds, but when stopped no thread has a stop reason, and every following "continue" gives `Resume timed out`; QEMU never reaches the `brk` that prepares JIT.
- **Counts**:
  - Without the packet log: 3 invocations, and all 9 attach attempts failed this way (one invocation in section 6, two with the repository script);
  - With the packet log (`LLDB_PACKET_LOG`): all 8 invocations attached on the first attempt.
  - **[inferred]** Logging slows LLDB down and sidesteps a timing problem; root cause not found.
  - The packet log of a successful run: after attaching, the process receives several SIGSTOPs in a row (`T11`), LLDB itself sends `c` to continue, and only then come QEMU's SIGUSR2 and the `brk`. In between there is a line `failed to get mutex, not sending packet 'jThreadsInfo'`.
- **What was done**: `device-boot.sh` turns the packet log on by default for tethered JIT, written next to the lldb log (`lldb-*-packets.log`, about 9000 lines each time); `LLDB_PACKET_LOG=none` turns it off. Along the way I tried changing the wait after "no stop reason" from 0.5 seconds to 3 seconds; it never got tested, so it was reverted (those three runs were stopped by the phone lock check below and never attached).
- **Phone lock**:
  - When the phone auto-locked midway, `device select` reported "Device needs to be unlocked."
  - The runner's old log did not show this message, and it attached anyway after device selection failed. Now that the 18 Pro is also connected, attaching to the other phone is a real risk.
  - Change (`scripts/ios/lldb_jit_runner.py`): print the error text as is; on "needs to be unlocked" retry every 2 seconds for up to 2 minutes; on other errors do not attach; an error with no text counts as selected (this is always the case on the 14 Pro, and attaching works).
  - `device-boot.sh` also checks once with `devicectl device info lockState` before booting; if the phone is locked, it says so and waits up to 2 minutes.
  - However, the phone was not locked during the 9 earlier failures (the error was empty), so the lock was not the cause of those 9 failures.
- `device-boot.sh` used to not exit when all three attach attempts failed, and it would wait idly until the time limit (600 seconds); now it exits right away.
- **How the lock screen is recognized**: `device-boot.sh` used to fetch one guest screenshot per second on the Mac for OCR; over `devicectl` one file takes about a second, so only 37 files came back in 400 seconds and the lock screen was never recognized.
  - Now `AUTODRIVE=1` is the default in StikDebug mode and when files go over `devicectl`: the app itself recognizes the lock screen, unlocks, idles and exits, taking a screenshot every 5 seconds, and the Mac only polls `events.log`.

### 7.4 Statistics (14 Pro, repository scripts, tethered JIT, packet log on by default)

| Run (`work/ios/runs/device/`) | System | Attach | Code buffer prepared | Lock screen | Home screen | Auto-unlock attempts |
|---|---|---|---:|---:|---:|---:|
| `20261104-215054-n78ap-13G36-jit` | 9.3.5 | 1st attempt | 42.7 s | 128 s | 187 s | 5 |
| `20261104-215443-n78ap-13G36-jit` | 9.3.5 | 1st attempt | 41.1 s | 133 s | Not reached | 12 (all failed) |
| `20261104-220158-n78ap-13G36-jit` | 9.3.5 | 1st attempt | 40.8 s | 131 s | Not reached | 12 (all failed) |
| `20261104-221426-n78ap-11D257-jit` | 7.1.2 (new pack) | 1st attempt | 40.6 s | 80 s | Not reached | 12 (all failed) |
| `20261104-222137-n78ap-11D257-jit` | 7.1.2 (new pack) | 1st attempt | 40.6 s | 78 s | Not reached | 12 (all failed) |

- **5 of 5 attaches succeeded on the first attempt, 5 of 5 reached the lock screen**; **only 1 of 5 reached the home screen**.
- Stuck on the app's own unlock: press Home, then 5 seconds later swipe from 18% to 92% of the screen width (at 90% of the height, 600 milliseconds in 20 steps). In the failed runs the guest screen stayed on the lock screen with the clock still running, as if the swipe was never received.
  - The two runs in section 6 unlocked after 2 and 5 tries respectively; in the simulator it takes 1 to 3.
  - No touch-related errors in the QEMU and serial logs.
  - Cause not investigated. **[inferred]** The guest runs slowly on the phone (the idle home screen takes a full core), so the synthetic swipe is too fast to be recognized as a swipe; it may also be related to the A5's vertical touch offset of about 100 pixels (a5-app.md 2.1). This is the next step.

### 7.5 "Cannot Use Device" on the 7.1.2 lock screen (fixed)

- The text comes from DeviceOMatic (`UNSUPPORTED_FAILURE_TITLE`/`BODY` in `DeviceOMatic.app`), not from MobileStorageMounter as a5-step1.md section 3.15 says (a correction has been added there). Its launchd configuration launches it when a removable `IOUSBDevice` is attached, which is exactly the USB disk we mount root from. The 9.3.5 lock screen does not have this notification.
- The 11D257 branch of `tools/a5/n78_diskfix.sh`: writes `Disabled = true` for `com.apple.device-o-matic` into `db/launchd.db/com.apple.launchd/overrides.plist` on the data volume. This file already exists in FirmwareKit's seed (0 bytes, owned by root); writing into the existing file keeps its owner. `build_nand.set_owner` was checked and needs no change.
- The golden disk the 7.1.2 pack uses (`work/ios/devices/n78ap-11D257/disk.img`) got only this step (a clone of the original disk is kept at `work/ios/devices/n78ap-11D257-disk-before-dom.img`), and was repacked into `work/ios/packs/n78ap-11D257.ctpack` (the old pack kept as `n78ap-11D257-before-dom.ctpack.old`).
- Checks:
  - booting the modified golden disk on the Mac (`work/a5/runs/dom712g`): lock screen throughout 38 to 54 seconds, no such notification, no panic;
  - on the phone, 105 screenshots from two boots of the new pack, and OCR never found this notification. **[verified]**
- One thing not investigated: the 7.1.2 lock screen sometimes does not draw the clock and date (both this round's Mac screenshot and last round's simulator screenshot show this); it is unrelated to this change.

### 7.6 Documents and wrap-up

- Changed:
  - `scripts/ios/devfiles.sh` (new file), `device-boot.sh`, `device-install.sh`, `lldb_jit_runner.py`;
  - `app/ClassicTouch/ImportManager.swift`;
  - `tools/a5/n78_diskfix.sh`, `tools/a5/README.md`;
  - `docs/reports/a5-step1.md` got a one-sentence correction.
- At the end the app on the phone had been ended, and no debugger or script was left on the Mac. Not committed.
