# M1 stage 1: cross-compiling, a minimal App shell, booting in the simulator and on the iPhone 18 Pro

- Date: 2026-11-01
- Execution session: M1 stage 1. The original scope was B1, C1 to C3, D1 and E0 (iOS simulator); midway the decision session added E1 (interpreter) and E2 (JIT via Xcode/LLDB) on the iPhone 18 Pro.
- Not done: no use of the iPhone 14 Pro, StikDebug not installed, no commit, nothing sent anywhere, M0's directories untouched (`work/devices/` and `work/states/` only cloned read-only).

## 0. Conclusions

1. **qemu-ios (QEMU 11.0.5, b225694505) builds into an iOS dylib almost unchanged.** The entire QEMU source got only one build switch patch (`patches/ios-host-gles-option.patch`, 8 lines, adding `-Dhost_gles=disabled` to meson), and not a single line of C was changed. The dependency sysroot takes about 1 minute per platform and QEMU about 36 seconds per build. Each of the four dylibs (iphoneos and iphonesimulator, each with an interpreter version and a JIT version) is about 34 MB and depends only on CoreFoundation, CoreMedia, CoreVideo, VideoToolbox and libz, libSystem, libresolv, libiconv, all present on iOS. Coroutines work with sigaltstack; libucontext is not needed.
2. **In the iOS simulator, both devices booted to the home screen with both backends**: iPod touch 2nd gen 3.1.3 (n72ap 7E18) and iPhone 3GS 6.1.6 (n88ap 10B500), with both the interpreter and the JIT versions. JIT in the simulator needs no debugger attached.
3. **Also booted to the home screen on the iPhone 18 Pro (iOS 27.2, 24B119)**, both devices with the interpreter version and with the JIT version (LLDB on the Mac attached over Wi-Fi). This is the technical part of M1's "first" milestone: qemu-ios running iPhone OS 3 and iOS 6 on an iPhone.
4. **The biggest bottleneck is "preparing" the JIT code region**: following upstream `lldb_jit.py`, the debugger has to read the whole code region and write it back. With the phone connected to the Mac over Wi-Fi, this measured about 0.8 MB/s: 256 MB takes 322 seconds, so the code region was shrunk to 32 MB for device measurements (38 to 46 seconds to prepare). With the smaller region, JIT has to flush and retranslate often, and the speedup drops to only 2 to 4 times (4 to 9 times in the simulator with 256 MB). See section 7 for the fix (plug in the cable; switch to the new protocol where the debugger allocates executable memory directly).
5. Interpreter version on the real device: iPod touch 2nd gen reaches the lock screen in 43 seconds, 3GS in 115 seconds; home screen idle CPU about 50% and 91% respectively (one core), footprint 380 to 560 MB; the App has about 3.0 GB of free memory, plenty.

## 1. Reproducible build commands

Prerequisites: Xcode 27.2, Homebrew meson 1.11, ninja, pkg-config, jq, `/opt/homebrew/opt/python@3.12` (the same one as M0), XcodeGen. Everything runs from the repository root.

```bash
# B1: download dependency sources (8 packages, 66 MB, sha256 checked one by one), then build a static library sysroot for each of the two platforms
scripts/ios/fetch-sources.sh
scripts/ios/build-deps.sh iphonesimulator     # about 1 minute → work/ios/sysroot-iphonesimulator-arm64
scripts/ios/build-deps.sh iphoneos            # about 1 minute → work/ios/sysroot-iphoneos-arm64

# C1: a separate work tree for qemu-ios (same commit); meson subprojects are copied locally from the upstream clone, no sources fetched from the network
git -C upstream/qemu-ios worktree add --detach "$PWD/work/ios/qemu-ios" b225694505
for d in dtc keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do cp -R upstream/qemu-ios/subprojects/$d work/ios/qemu-ios/subprojects/; done

# C2/C3: four QEMU builds and dylibs (build-qemu.sh applies patches/ios-*.patch automatically), about 36 seconds each
for p in iphonesimulator iphoneos; do for t in interp jit; do
  TCG=$t scripts/ios/build-qemu.sh $p && TCG=$t scripts/ios/make-dylib.sh $p
done; done
# Output: work/ios/build-qemu-<platform>-<backend>/libqemu-arm-<backend>.dylib

# D1: App shell (the embed phase copies the dylibs above into Frameworks and signs them)
(cd app && xcodegen generate)
xcodebuild -project app/ClassicTouch.xcodeproj -scheme ClassicTouch -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath work/ios/DerivedData build
xcodebuild -project app/ClassicTouch.xcodeproj -scheme ClassicTouch -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath work/ios/DerivedData \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<signing team ID> build
```

Boot measurement (put the devices into the App's Documents first, see section 3):

```bash
scripts/ios/sim-boot.sh n72ap-7E18 interp          # E0, simulator
TBSIZE=32 scripts/ios/device-boot.sh n88ap-10B500 jit   # E1/E2, real device; jit attaches LLDB automatically
```

Overview of `scripts/ios/`:

| File | Purpose |
|---|---|
| `sources.tsv`, `fetch-sources.sh` | Official URLs and sha256 of the dependency sources (glib through nettle taken from LightTouchMac's `dependencies.json`); download and verify |
| `common.sh` | Platform settings: `-target arm64-apple-ios16.0[-simulator]`, SDK, parallelism (capped at 8) |
| `build-deps.sh` | libffi 3.8.0, pcre2 10.48, glib 2.88.3 (with proxy-libintl 0.5 and LightTouchMac's pipe2 patch), pixman 0.46.4, libslirp 4.9.4 (with qemu-ios's two patches), OpenSSL 3.6.3 (libcrypto only), Nettle 3.10.2, all static; license texts go in `sysroot/share/licenses/` |
| `build-qemu.sh` | Adapted from upstream's deleted `contrib/ios-app/build-ios.sh`: TCTI and PGO removed, `--without-default-features` then pixman, slirp and nettle turned back on, `--with-coroutine=sigaltstack`, `-Dhost_gles=disabled` |
| `make-dylib.sh` | Adapted from upstream's deleted `make-dylib.sh` and the current `make-dylib-macos.sh`: takes ninja's link command, replaces `system/main.c` with `qemu-ios-entry.c`, links in `qemu-ios-ui.c` and `qemu-macos-extras.c`, and exports the same ABI as the Mac version plus two iOS-only functions, 58 in total; does not use `-undefined dynamic_lookup` |
| `embed-qemu.sh` | Xcode build phase: copy the dylibs into Frameworks and sign them |
| `pack-device.py` | Packs a device directory into a `.ctpack` (only the extents that hold data), see section 5 |
| `sim-boot.sh`, `device-boot.sh`, `summarize-run.py` | Cold boot timing: reset state, launch, one guest screenshot per second, OCR to detect the lock screen and home screen, automatic unlock, summary |
| `lldb_jit.py` | Upstream's deleted LLDB stop hook, recovered unchanged (only a note on its origin added) |
| `lldb_jit_runner.py` | The debugger used for E2: LLDB SB API, synchronous mode, answers `brk #0x69` |

There are two more dependencies than in the brief, both official source packages: **libffi** (the iOS SDK has no ffi headers, and the simulator SDK does not even have the library; glib's gobject needs it) and **Nettle** (QEMU 11 dropped its built-in AES, and CDMA decryption for the iPod touch 1st gen and A4 models relies on it; LightTouchMac builds it too). In addition, QEMU's configure uses pip to install two build tools, `qemu.qmp` and `setuptools`, from PyPI (the same as M0's Mac build, a few hundred KB). No prebuilt binaries were downloaded.

## 2. Patches and changes to upstream

| Patch | What it changes | Why |
|---|---|---|
| `patches/ios-host-gles-option.patch` | Adds a `host_gles` feature option to `meson_options.txt` (default auto, same behavior as upstream), makes the `host_gles` dependency in `meson.build` use it, and adds the matching `--enable/--disable-host-gles` to `scripts/meson-buildoptions.sh` | The iOS SDK includes OpenGLES.framework, and upstream builds the EAGL GL bridge automatically whenever it finds it, with no way to turn it off. The first boot has to run without host GL (research report 4.5): `gles-host-stub.c` is used instead, and after the guest's GLES HLE probe fails it falls back to software compositing |

Apart from this, not a line of QEMU source was changed. None of the places expected to need changes did: the TXM path in `tcg/region.c`, the JIT write protection stub in `osdep.h` and `needs_exe_wrapper` in configure are all in main and work as is; things like IOKit in `file-posix.c` and `system()` being unavailable on iOS were handled by QEMU itself long ago.

Two machine options used at run time (added when the App builds the arguments, not patches):

- iPod touch 2nd gen adds `amc-mode=handshake`: the default `decode` needs libavcodec (FFmpeg) and exits with an error without it; `handshake` only does the audio handshake, which matches M1 having no sound.
- The JIT version adds `-accel tcg,split-wx=on`: split-wx is off by default and would request MAP_JIT, which iOS does not grant; only the dual mapping takes the TXM path in `region.c`. The code buffer uses `tb-size` (App default 256 MB, 32 MB for device JIT measurements).

## 3. App shell (`app/`)

- XcodeGen project (`app/project.yml`), Bundle ID `org.classictouch.app`, display name "Classic Touch", both placeholders. Minimum iOS 16, scene lifecycle (required by the iOS 27 SDK), portrait only. The signing team is not written into the repository and is passed on the command line at build time.
- `Engine.swift`: by backend, `dlopen` `libqemu-arm-interp.dylib` or `-jit.dylib` from Frameworks, `dlsym` the ABI, and call `qemu_ios_main` on a background thread with an 8 MB stack. QEMU is started only once per process.
- `EmulatorViewController.swift`: CADisplayLink fetches the `qemu_ios_ui_frame` BGRA frame on every screen refresh, turns it into a CGImage and puts it in a CALayer; single-finger touches are normalized to the guest screen and passed to `qemu_ios_ui_touch`; the Home and power buttons go to `qemu_ios_ui_button`; `sceneWillResignActive` and `sceneDidBecomeActive` are wired to `qemu_ios_set_foreground`. A line at the top shows run time, CPU, footprint, free memory and frame count. QEMU's stderr, serial port, per-second stats and guest screenshots are all written to `Documents/logs/<time>-<device>-<backend>/`.
- `DeviceProfile.swift`: reads FirmwareKit's `device.lock.json` and builds argv following LightTouchMac's `BootRecipe.swift` (the iPod and iPad variants) and M0's `bench.py`. M1 supports devices whose `boot_strategy` is iboot (iPod touch 2nd gen) or kboot (3GS, iPhone 4, iPod touch 3rd/4th gen, original iPad).
- `DevicePack.swift`: at launch, unpacks `Documents/import/*.ctpack` into Documents.
- Launch arguments (for scripts): `-device`, `-tcg`, `-tbsize`, `-resetstate`, `-waitdebugger`, `-guestpng`, `-autounlock`, `-qemuargs`; the host can put `unlock`, `home` or `quit` files into `Documents/control/` to operate it.
- Host GL is off, there is no entitlements file (`get-task-allow` comes with development signing), and `increased-memory-limit` was not added.

Putting devices into the App: in the simulator, `cp -c` (APFS clone) straight into the container's `Documents/devices/`; on the real device, pack with `pack-device.py`, copy into `Documents/import/` with `xcrun devicectl device copy to`, and the App unpacks it at launch. The 3GS pack includes M0's state after completing the setup assistant (a clone of `work/states/n88ap-10B500`, placed in `golden-state/`); `-resetstate` starts over from it each time, so boot goes straight to the lock screen.

## 4. Boot results

Timing method: wall-clock seconds counted from when the App calls `qemu_ios_main`; "lock screen" and "home screen" are the times when OCR on the one-per-second guest screenshots first recognizes "slide to unlock" and the home screen icon names; CPU is user+sys of all threads of this process, with percentages counted as one core (same as M0); "QEMU screen on" is QEMU's own `[boot] first lit frame` log, which excludes the pauses for waiting on the debugger and preparing the code region, and is best for side-by-side comparison. The home screen time is affected by when the automatic unlock happens (swiping does nothing while the screen is still off and has to be retried), so it is less useful as a reference than the lock screen.

### 4.1 iOS simulator (E0, iPhone 18 Pro simulator on an M4 Max, iOS 27.2)

| Device | Backend | QEMU screen on | Lock screen | CPU to lock screen | Home screen | Home screen idle CPU | Max footprint |
|---|---|---|---|---|---|---|---|
| iPod touch 2nd gen 3.1.3 | Interpreter | 36.3 s | 54 s | 54.5 s | 64 s | 58% | 394 MB |
| iPod touch 2nd gen 3.1.3 | JIT (256 MB) | 7.0 s | 10 s | 9.2 s | 19 s | 17% | 704 MB |
| iPod touch 2nd gen 3.1.3 | JIT (32 MB, for comparison) | 19.5 s | 27 s | 26.9 s | 35 s | 19% | 228 MB |
| iPhone 3GS 6.1.6 | Interpreter | 159.9 s | 160 s | 169.0 s | 179 s | 93% | 545 MB |
| iPhone 3GS 6.1.6 | JIT (256 MB) | 18.2 s | 19 s | 20.7 s | 49 s | 10% | 789 MB |

- In the simulator `os_proc_available_memory()` is always 0, so free memory is meaningless.
- JIT in the simulator needs no debugger: the simulator process follows macOS rules, and the `split-wx` dual mapping can be used directly.
- What the 32 MB comparison shows: shrinking the code buffer hurts JIT a lot (screen on goes from 7 seconds to 19.5 seconds), so the small JIT speedup on the real device in section 4.2 is mainly due to the buffer being too small, not the phone being slow.
- Actual observations on first boot (`m1-sim-n72ap-3.1.3-interp-*.png`): touch and the Home button both work; the 3.x lock screen turns off after a few seconds untouched, and pressing Home wakes it; while the screen is off the interpreter's CPU drops to 20% to 30%, so it does not spin.

Screenshots: `docs/reports/img/m1-sim-n72ap-3.1.3-interp-home.png`, `m1-sim-n72ap-3.1.3-interp-lock.png`, `m1-sim-n72ap-3.1.3-jit-home.png`, `m1-sim-n88ap-6.1.6-interp-home.png`, `m1-sim-n88ap-6.1.6-jit-home.png`.

### 4.2 iPhone 18 Pro real device (E1, E2, iOS 27.2 24B119, A20 Pro, connected to the Mac over Wi-Fi)

| Device | Backend | QEMU screen on | Lock screen | CPU to lock screen | Home screen | Home screen idle CPU | Footprint | Free memory (minimum) |
|---|---|---|---|---|---|---|---|---|
| iPod touch 2nd gen 3.1.3 | Interpreter | 27.4 s | 43 s | 42.5 s | 54 s | 50% | 378 to 411 MB | 2965 MB |
| iPod touch 2nd gen 3.1.3 | JIT (32 MB) | 12.8 s | 88 s, about 18 s excluding the pause | 17.8 s | 101 s | 18% | 227 to 277 MB | 3099 MB |
| iPhone 3GS 6.1.6 | Interpreter | 114.6 s | 115 s | 122.7 s | 137 s | 91% | 534 to 559 MB | 2817 MB |
| iPhone 3GS 6.1.6 | JIT (32 MB) | 26.1 s | 84 s, about 26 s excluding the pause | 27.0 s | 112 s | 79% | 319 to 365 MB | 3011 MB |

- The "pause" in the two JIT rows is: the App waits for LLDB to attach; when QEMU allocates the code region it issues `brk #0x69` to ask the debugger to prepare it, and the debugger took 46.4 seconds (iPod) and 37.7 seconds (3GS) to read and write 32 MB. During this time the whole App is stopped by the debugger and the phone's display does not move (section 6). Only after the pause does QEMU really start running, so for the JIT rows "QEMU screen on" and "CPU to lock screen" are more accurate.
- The real device is faster than the simulator on the M4 Max: interpreter screen on at 27.4 seconds versus 36.3 seconds (iPod), and 114.6 seconds versus 159.9 seconds (3GS).
- JIT versus interpreter on the real device: screen on is 2.1 times faster (iPod) and 4.4 times faster (3GS); these are numbers with a 32 MB buffer, and extrapolating from the simulator comparison, 256 MB would be another 2 to 3 times faster.
- Without `increased-memory-limit` the App's memory limit is about 3.3 GB, and free memory stayed above 2.8 GB throughout the measurements, so memory is not a problem on the iPhone 18 Pro.
- iOS 6 under the interpreter still uses 91% of a core while idle on the home screen, which will be a battery problem; iPod 3.1.3 uses 50%.
- **Note added after the decision session's check**: in the 3GS JIT run, reaching the home screen at second 112 is genuine (`work/ios/runs/device/20261101-195908-n88ap-10B500-jit/guest-0112.png`). But from seconds 116 to 146, Settings, General and Language were opened one after another in the guest, and then it went back to the home screen. The script sent none of these taps (`events.log` has only two unlocks and one quit); someone tapped on the phone, which happens to show that touch works under JIT on the real device. So this row's "home screen idle CPU 79%" is not an idle figure and must be remeasured; `m1-device-n88ap-6.1.6-jit-home.png` also captured Settings just opening, not the home screen.

Screenshots: `docs/reports/img/m1-device-n72ap-3.1.3-interp-booting.png` (full device screen captured with devicectl, during boot), `m1-device-n72ap-3.1.3-interp-home.png`, `m1-device-n72ap-3.1.3-jit-home.png`, `m1-device-n88ap-6.1.6-interp-home.png`, `m1-device-n88ap-6.1.6-jit-home.png`, plus two guest screenshots of the lock screen. Raw records are in `work/ios/runs/` (summaries `*.summary`, per-second stats `stats.csv`, `qemu.log`, serial port, LLDB logs).

## 5. Problems and fixes

| Problem | Fix |
|---|---|
| configure fails with `--disable-download`: it unconditionally wants to install Python's tooling group (qemu.qmp, setuptools), which it cannot find offline | Do not use that switch; meson subprojects are copied locally from the upstream clone beforehand, so it only installs those two build tools from PyPI, the same as M0 |
| meson reports "No build machine compiler" for the hexagon target | `--host-cc` cannot use the bare clang from the toolchain (it cannot find the macOS SDK); use `/usr/bin/clang` (the xcrun wrapper) instead |
| `otool \| grep -m1` at the end of the dependency script triggers a pipefail exit | Add `\|\| true` |
| The App reports "qemu_ios_set_foreground not found in the dylib" | The Mac version's export table lacks it and `qemu_ios_ui_frame_size` (the Mac does not need them); add both to the iOS export table |
| iPod touch 2nd gen reports "AMC decoding requires a build with libavcodec support" | Machine option `amc-mode=handshake`, see section 2 |
| iPod touch 2nd gen reports "is a NAND image store, written in place: it takes no nandrw overlay" | This device's NAND is an image store written in place. Following LightTouchMac's `liveNAND`: on first launch clone the NAND to `state/nand` and write it in place, without passing nandrw. The 3GS NAND controller supports a page overlay, so it uses `nand-overlay` as in M0 |
| **iPod touch 2nd gen needs Apple's SecureROM (`bootrom_240_4`), which this machine does not have** | Use a 4-byte placeholder file (one ARM `b .`). From reading `hw/arm/ipod_touch_2g.c`: on a direct-iboot cold boot the bootrom is only placed at address 0 and never executed, so it boots; but **waking from deep sleep (AP powered off) goes through the real boot chain from the bootrom, and with the placeholder file it will hang**. In testing, the lock screen turning off and waking with Home both worked, but that is display sleep, not AP power off; whether long idle periods trigger it has not been tested. This needs a decision, see section 7 |
| devicectl does not preserve sparse holes when copying files: the device NANDs are sparse files (iPod actually 465 MB, apparent 8.1 GB; 3GS plus the golden state apparent 34 GB), and transferring a 4 GB hole as zeros was measured at 71 seconds | Pack it ourselves: `pack-device.py` collects only the extents that hold data (SEEK_DATA/SEEK_HOLE, then skipping all-zero 64 KiB blocks), giving 451 MB for the iPod and 1911 MB for the 3GS; copying to the phone takes 9 and 32 seconds, the App unpacks them in 0.4 and 1.8 seconds, and the results are still sparse files |
| Automatic unlock fails: the 3.x and 6.x lock screens turn off after a few seconds, and swiping does nothing while the screen is off | Press Home first to wake it, then swipe 5 seconds later; if the script does not see the home screen, it retries every 20 to 25 seconds |
| JIT: white screen on the phone after `devicectl --start-stopped` plus LLDB attach | This machine only had the symbol cache for the phone's old system (24B5110a), while the phone is already on 24B119, so LLDB got stuck on dyld's load notifications reading modules over the network. Changed to launching the App normally with `-waitdebugger` so it waits for the debugger in its UI, and LLDB sets `target.memory-module-load-level minimal` to read only section info; attaching went from timing out to 0.5 seconds |
| JIT: Xcode 27.2's LLDB crashed twice | Once in `PlatformDarwinDevice::GetDeviceSupportDirectoryForOSVersion` while loading modules in parallel (turned off `target.parallel-module-load`); once in the command-line driver's event thread in `ProcessGDBRemote::WillPublicStop`. In the end switched to a standalone script, `lldb_jit_runner.py`: SB API, synchronous mode, handling each stop itself, no stop hook |
| JIT: occasionally stuck for good after "Resume timed out" | The default gdb-remote packet timeout is not enough over Wi-Fi; set `plugin.process.gdb-remote.packet-timeout` to 60 |
| JIT: preparing a 256 MB code region takes 322 seconds | Use `-tbsize 32` for device measurements (38 to 46 seconds); for the real fix see section 7 |

## 6. Installing on the real device: current state, what was used, what the user still needs to do

Already done (after the decision session added E1/E2, within the boundary of "use only the signing team already in Xcode"):

- **Signing team**: Xcode has one paid individual team (team ID omitted, `isFreeProvisioningTeam = 0`), and the keychain has its Apple Development certificate. Automatic signing used the team's existing wildcard profile "iOS Team Provisioning Profile: *"; no new App ID was created and no account settings were changed. The team ID is not written into the repository.
- **Phone**: iPhone 18 Pro, iOS 27.2 release (24B119, not the 24B5110a in the cache during research), already paired, Developer Mode on, connected over Wi-Fi. Installing the App, copying devices, launching and attaching the debugger were all done from the Mac with `xcrun devicectl` and LLDB, with no need for the user to tap anything on the phone.
- The phone now has `org.classictouch.app` installed, with two devices (about 2.4 GB) and run records in Documents. The App was ended after testing. When it is not needed, the App can simply be deleted on the phone.

For the user to know or decide:

1. **The phone will show a white screen or freeze during tests**: in JIT tests the App first shows "Waiting for debugger", and after attaching the whole display stops moving while the code region is prepared (about 40 seconds for 32 MB). Earlier, one attempt with `--start-stopped` gave a white screen for 5 minutes; that approach has been changed.
2. **Plugging in the cable will be much faster** (guess): the phone currently uses Wi-Fi, and the debugger reads and writes memory at about 0.8 MB/s. One more test with a data cable to the Mac will show whether the code region can be grown to 256 MB. Needs the user to plug in the cable.
3. **Whether to let Xcode copy the 24B119 device symbols** (about 6 to 7 GB, from the phone to `~/Library/Developer/Xcode/iOS DeviceSupport` on the Mac): Xcode copies them automatically when you "Run" directly to this phone from Xcode. For now the minimal module loading works around it, so it works without copying; after copying, attaching the debugger and reading crash stacks go more smoothly. I did not trigger it.
4. **The iPhone 14 Pro was not touched**: the first connection to Xcode would also copy about 6 to 7 GB of symbols; per the brief, waiting for approval.
5. **Using JIT away from the computer (E3)** needs StikDebug and LocalDevVPN installed and a pairing file imported; not done.

Recommended phone: keep using the iPhone 18 Pro as the development device (already working, fastest CPU, plenty of memory); use the 14 Pro after E3 as the low-end and 27.0.1 comparison.

## 7. Suggested next steps

1. **Switch JIT to the new protocol (the most worthwhile thing before E3)**: have the debugger directly allocate executable memory that is already prepared (StikDebug's universal.js approach: `brk #0xf00d`, and when x0 is 0, debugserver allocates RX on its behalf; see Ios-emul's 0016 patch), instead of moving the whole block of data. Then the code region can go back to 256 MB or more, preparation time no longer depends on region size, and JIT on the real device can get the 4 to 9 times speedup seen in the simulator; it is also the prerequisite for using StikDebug away from the computer. This requires changing `tcg/region.c`, as `patches/ios-txm-jit-protocol.patch`.
2. **First rerun E2 once with the cable plugged in** (256 MB) to quantify preparation speed over USB, and judge whether the old protocol is good enough for the development phase.
3. **What to do about the iPod touch 2nd gen SecureROM (needs a decision)**: upstream Light Touch bundles `bootrom_240_4` in the App, while our rule is that Apple firmware goes neither into the repository nor into the App. Options: let users supply it themselves; or investigate whether waking can also take the direct-iboot route (changing qemu-ios), or disable deep sleep in the guest. Until then, the iPod touch 2nd gen may hang after long idle periods, and a long idle test should be run first.
4. **Power saving**: under the interpreter, iOS 6 uses 91% of a core while idle on the home screen. Worth looking at the idle optimizations in upstream's blake-lucas branch, and at pausing the VM when switching between foreground and background.
5. **Stage F as originally planned**: add ES 2.0 to EAGL, snapshots (save without GL, quit, restore in a new process, check whether it can be tapped), `tb-size` and memory comparison, `glGetTexImage` probing.

## 8. Outputs and directories

- In the repository (not committed): `scripts/ios/`, `patches/ios-host-gles-option.patch`, `app/` (`project.yml`, the generated `ClassicTouch.xcodeproj`, `ClassicTouch/*.swift`, `Info.plist`), this report and `docs/reports/img/m1-*.png`.
- `work/ios/` (about 7.5 GB, not committed): `src/` (source packages), `sysroot-*`, `deps-build/`, `qemu-ios/` (work tree, with patches), `build-qemu-*` (four builds and dylibs), `DerivedData/`, `devices/` (APFS clones of the M0 devices and the 3GS golden state), `packs/` (`.ctpack`), `runs/` (measurement records), `logs/`.
- A dedicated simulator, "ClassicTouch iPhone 18 Pro" (7C0870F5-C435-4A26-AC3C-D17ADB816486), whose App container has clones of the two devices.
- `upstream/qemu-ios` itself is unchanged; it only gained one worktree registration.
- One entry was added to the automated memory: when a device test will show a white screen or freeze, tell the user first.
