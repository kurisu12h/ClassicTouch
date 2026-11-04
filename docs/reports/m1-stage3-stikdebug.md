# M1 stage 3 (E3): JIT from StikDebug on the phone itself

- Date: 2026-11-01
- Execution session: M1 execution session (continuing from stages 1 and 2). Scope: on the iPhone 18 Pro (iOS 27.2), use StikDebug to answer the new JIT protocol on the phone itself, measure the 256 MB preparation time, and do one formal measurement round on each of the two devices.
- Not done: did not touch the iPhone 14 Pro, did not copy device symbols, did not file issues or PRs with StikDebug or any other upstream, did not commit. StikDebug's code (AGPL-3.0) lives only in `work/`; it did not go into the repository and is not compiled into our App.

## 0. Conclusions

1. **StikDebug 3.2.0 can provide JIT on iOS 27.2, and the new protocol works in the release form.** It answers `brk #0xf00d` on the phone itself:
   - preparing a **256 MB code region takes 0.68 to 0.85 seconds** (4 runs), 32 MB takes 0.10 seconds;
   - about 41 to 52 microseconds per page (16 KiB) on average, including allocation;
   - the same 256 MB took 2 to 8 minutes with LLDB on the Mac over Wi-Fi in stage 2.
   
   Once preparation is done QEMU tells it to detach, and from then on the App runs without a debugger.
2. **With the code region back at 256 MB, JIT is much faster:**

   | Device | QEMU screen on | Lock screen | CPU to lock screen | Home screen | Home screen idle CPU |
   |---|---|---|---|---|---|
   | iPod touch 2nd gen 3.1.3 | 7.7 s | 10 s | 6.9 s | 18 s | 19% |
   | 3GS 6.1.6 | 12.2 s | 14 s | 14.0 s | 22 s | 16% |

   Compare the interpreter on device: iPod 43 seconds and 3GS 115 seconds to the lock screen, idle CPU 61% and 108%. The idle segments of both rounds were checked; nobody touched the phone.
3. **The user has very little to do.** In this stage the user actually did three things:
   - installed and opened LocalDevVPN;
   - plugged in the cable once to generate the pairing file;
   - unplugged and replugged the cable once partway through, to get the stuck file service to recover.

   For each measurement round the user does not need to tap the phone even once: the Mac uses a `stikjit://` URL to bring up StikDebug, which launches our App; the App reads its configuration and boots, unlocks, idles and exits on its own.
4. **A newly found risk is confirmed: with the placeholder SecureROM, the iPod touch 2nd gen cannot be woken once it enters deep sleep.** About 18 seconds after the lock screen turns the display off, the guest enters deep sleep, and pressing Home to wake it jumps into the placeholder bootrom, where the CPU spins in place at 100% (section 4). So it has to be unlocked as soon as possible after boot; this must be solved before the iPod touch 2nd gen is officially supported.
5. Blockers (all worked around):
   - With LocalDevVPN on, CoreDevice's file service (`devicectl copy`) first got slow over Wi-Fi and later hung completely, and replugging the cable did not bring it back. Switching to AFC (the idevice tools, over USB) works.
   - Lock screen detection on the Mac side was too slow, and that is exactly what let the iPod fall into deep sleep. The App now detects it itself with Vision.

## 1. Building and installing StikDebug

- Source: the official repository StikDebug/StikDebug, release tag **3.2.0** (commit 97530a9, 2026-10-30, not lower than the required 3.1.11), shallow-cloned to `work/ios/stikdebug/`.
- Dependencies:
  - The idevice library, written in Rust, ships in the repository as a prebuilt static library (`StikDebug/idevice/libidevice_ffi.a`, 57 MB). It was used as is, not rebuilt from the Rust source (that would mean downloading a Rust toolchain).
  - Xcode's SPM pulled two source packages from GitHub: CodeEditorView and Rearrange.
- Two changes were made, only on the copy in `work/`:
  - Bundle ID changed to `org.classictouch.dev.stikdebug`: the original `com.stik.stikdebug` belongs to someone else's team.
  - The App Group was removed with an empty local entitlements file: the original group name belongs to someone else's team. The only thing in the code that uses the App Group is the icon disk cache, which has a fallback when it cannot get the container; the group name used in its code did not match the entitlements anyway.
- Signing: Release build, automatic signing with the paid personal team already set up in Xcode. It used the team's existing wildcard provisioning profile "iOS Team Provisioning Profile: *". **No App ID or capability was registered, and no account settings were changed.**
- Installed on the iPhone 18 Pro with devicectl, then its preferences were written in advance (`Library/Preferences/org.classictouch.dev.stikdebug.plist`):
  - `confirmExternalJITRequests = false`: no confirmation prompt when an external URL requests JIT;
  - `keepAliveLocation = false`: background keep-alive uses audio only, with no location permission prompt.

## 2. Pairing file

- StikDebug 3.2.0 needs a **RemotePairing pairing file** (RPPairing: an Ed25519 key pair, an identifier, an optional `alt_irk`), not a traditional lockdown pairing record. The code uses `rp_pairing_file_read`.
- Tool: `idevice-tools-macos-arm-v0.1.68.zip` from idevice's official releases page (MIT, 5 MB, sha256 matches the one GitHub gives), placed in `work/ios/tools/idevice-tools-0.1.68/`.
- Generation: `idevice-tools remotepairing_lockdown pair <hostname> <file>`, over USB, reusing the Mac's existing trust relationship; no prompt appeared on the phone. It was then checked with `verify`, and the phone answered "recognizes this pairing record". This step only works over USB, which is why the user plugged in the cable once.
- Storage: the file is in `work/ios/secrets/` (directory 700, file 600). It did not go into the repository and is not written into the report. It was copied with devicectl to StikDebug's `Documents/pairingFile.plist`, which StikDebug moves into its protected directory on its own at launch.
- The official guide recommends iloader (a GUI, a DMG downloaded from GitHub); it was not used this time.

## 3. Changes on our side

- **Patch**: `patches/ios-txm-jit-protocol.patch` adds a timing log line in the new protocol path: `[jit] universal: N MiB at … prepared in X s`, written to `qemu.log`. Of the four dylibs, only the device JIT build is affected, and it has been rebuilt.
- **App**:
  - `LaunchOptions.swift`: launch arguments take priority; with no arguments it reads `Documents/autostart.json`. When StikDebug brings us up it passes no arguments, so this file decides which device to boot, which backend to use and how big the code region is.
  - `GuestText.swift`: Vision text recognition.
  - `EmulatorViewController.autodrive()`: reads the guest screen once a second. When it sees "slide to unlock" it records `lock_seen` and unlocks immediately, retrying every 12 seconds; when it recognizes the home screen it records `home_seen`, stops recognizing, idles for `idle` seconds (default 40) and then makes QEMU exit on its own. A full measurement round needs no help from the Mac.
- **Script** `scripts/ios/device-boot.sh` gets a `STIK=1` mode:
  1. write `autostart.json` (JIT, code region, autodrive, 40 seconds idle, one screenshot every 5 seconds);
  2. terminate the App if it is still running;
  3. `devicectl device process launch --payload-url "stikjit://enable-jit?bundle-id=org.classictouch.app&script-name=universal.js" org.classictouch.dev.stikdebug`;
  4. after that, fetch `events.log` every 3 seconds, and once QEMU exits, fetch the stats, logs and window screenshot.

  All file operations now go through AFC (`idevice-tools afc --documents`). Other fixes:
  - each control command writes different content: devicectl skips files it thinks have not changed;
  - when AFC occasionally crashes, do not exit; download to a temporary file first, then rename;
  - `summarize-run.py` and `check-idle.py` also recognize the `auto_quit` sent by the App itself.

## 4. Measurements

All on the iPhone 18 Pro (iOS 27.2 24B119), connected to the Mac over USB, phone unlocked, LocalDevVPN on. The iPhone Mirroring App on the Mac was running (the script can only record whether the App is running, not whether a mirroring session is connected). Mac 1-minute load 3.7 to 8.1 (for the first few seconds one of my own builds was finishing up).

### 4.1 One round on each device (StikDebug, 256 MB)

| Device | Backend | Code region preparation | QEMU screen on | Lock screen | CPU to lock screen | Home screen | Home screen idle CPU | Footprint | Available memory (minimum) |
|---|---|---|---|---|---|---|---|---|---|
| iPod touch 2nd gen 3.1.3 | **StikDebug JIT 256 MB** | **0.68 s** | **7.7 s** | **10 s** | **6.9 s** | **18 s** | **19%** | 751 to 775 MB | 2601 MB |
| | Stage 2 new protocol 32 MB (Mac LLDB, Wi-Fi) | 16.7 s | 12.0 s | 16 s, pause excluded | 15.8 s | | 25% | 247 MB | 3129 MB |
| | Stage 1 old protocol 32 MB (Mac LLDB, Wi-Fi) | 46.4 s | 12.8 s | about 18 s, pause excluded | 17.8 s | | 21% | 277 MB | 3099 MB |
| | Stage 1 interpreter | none | 27.4 s | 43 s | 42.5 s | 54 s | 61% | 411 MB | 2965 MB |
| iPhone 3GS 6.1.6 | **StikDebug JIT 256 MB** | **0.76 s** | **12.2 s** | **14 s** | **14.0 s** | **22 s** | **16%** | 791 to 892 MB | 2484 MB |
| | Stage 1 old protocol 32 MB (Mac LLDB, Wi-Fi) | 37.7 s | 26.1 s | about 26 s, pause excluded | 27.0 s | | Void (someone tapped) | 365 MB | 3011 MB |
| | Stage 1 interpreter | none | 114.6 s | 115 s | 122.7 s | 137 s | 108% | 559 MB | 2817 MB |

- In this stage the lock screen and home screen times were detected by the App itself with Vision (`lock_seen`, `home_seen`), which matches the method of the first two stages (OCR on the Mac of a screenshot taken every second); timing starts when the App calls `qemu_ios_main`. In both rounds the first automatic unlock succeeded (1 second after the lock screen).
- Idle CPU uses stage 2's new method: from 3 seconds after the home screen until just before `auto_quit`. Checked with `check-idle.py`:
  - iPod: 21 to 58 seconds, the frame number changed by only 2 (the status bar clock), no events at all;
  - 3GS: 25 to 63 seconds, likewise changed by only 2, no events.
- The footprint is about 500 MB larger than at 32 MB, mainly from the 256 MB code region (mapped once as read-execute and once as writable, counted by the pages actually used). Available memory on the iPhone 18 Pro is still above 2.4 GB. `increased-memory-limit` was not added.
- Compared with stage 1 at 32 MB, the iPod's CPU to lock screen dropped from 17.8 seconds to 6.9 seconds, and the 3GS's from 27.0 seconds to 14.0 seconds; compared with the interpreter, that is 6.2x and 8.8x respectively. Stage 2 inferred that "32 MB is too small and gets flushed and retranslated often", and this data confirms it.
- No extra runs needed: neither round was disturbed or hit an error, and the numbers are within the expected range.

Screenshots (window snapshots saved by the App itself, home screen, status bar shows JIT, image checked):
- `docs/reports/img/m1s3-device-n72ap-3.1.3-stikdebug-jit256-home.png`
- `docs/reports/img/m1s3-device-n88ap-6.1.6-stikdebug-jit256-home.png`

### 4.2 All preparation time records

| Run | Code region | StikDebug preparation time | QEMU screen on |
|---|---|---|---|
| 221610 | 32 MB | 0.10 s | 12.6 s |
| 221950 | 256 MB | 0.85 s | 8.1 s |
| 223815 | 256 MB | 0.81 s | 7.8 s |
| 224227 (iPod formal) | 256 MB | 0.68 s | 7.7 s |
| 224356 (3GS formal) | 256 MB | 0.76 s | 12.2 s |

The per-page "round-trip time" cannot be measured on its own: StikDebug pipelines 128 `M` packets per batch (1 byte written per page), so the round trips are amortized. Dividing the total time by the number of pages, 256 MB is about 41 to 52 microseconds per page (including the `_M` allocation and script overhead), and 32 MB is about 49 microseconds, so preparation time is roughly proportional to the code region size, but it stays under a second.

### 4.3 iPod touch 2nd gen: cannot wake from deep sleep with the placeholder SecureROM (run 223815)

This round still detected the lock screen on the Mac side by fetching screenshots one by one over AFC, with a large delay: the lock screen appeared at second 10, and the unlock command was not sent until second 39. `stats.csv` shows it clearly:

| Time | CPU | Backlight | Frame number | Notes |
|---|---|---|---|---|
| 15 s | 33% | 245 | 76 | Lock screen on |
| 18 s | 25% | 0 | 103 | Lock screen turns the display off by itself |
| 21 to 33 s | 17% to 22% | 0 | 103 | Display off, idle |
| 36 to 39 s | 2% | 0 | 103 | Entered deep sleep (processor powered off) |
| 39 s | | | | Press Home to wake |
| 42 s onward | 100% | 0 | 103 | Fully loaded from then on, screen no longer updates |

This matches the logic in `hw/arm/ipod_touch_2g.c`: when the processor is powered back on it resets and runs the bootrom, and the bootrom is our placeholder file (a single `b .` at address 0), so it spins in place. It did not trigger during the 11 minutes observed in the simulator in stage 2 because Home was never pressed to wake it after the lock screen; that time the CPU likewise dropped to 2% to 4%.

**Handling**:
- On the measurement side, the App now detects the lock screen itself and unlocks within 1 second, and the problem has not appeared since.
- It must be solved before the iPod touch 2nd gen is officially supported. Options:
  - have the user supply their own SecureROM;
  - change qemu-ios so that wake-up also goes through the direct-iboot path (only researched, not done);
  - disable deep sleep inside the guest.

## 5. How many steps the user has to take

### What was actually done this time

1. Install LocalDevVPN from the App Store, open it, allow it to add a VPN configuration, and turn on the VPN (already done by the time the decision session passed this on). The phone also has another VPN App installed, and only one can be on at a time, so make sure the one turned on is LocalDevVPN.
2. Plug in the cable once so the Mac can generate the pairing file (no prompt on the phone).
3. Unplug and replug the cable once partway through, hoping to get the stuck file service to recover; it did not help, and switching to AFC solved it later.
4. During measurements, keep the phone unlocked and plugged in, with iPhone Mirroring off, and do not touch the screen while idle is being measured.

The measurement rounds themselves take 0 taps from the user. I did not observe whether StikDebug shows a "Local Network" permission prompt on its first run, and the user did not mention one; measurements went normally throughout.

### The flow for future real users (without a Mac), for reference when designing the launch flow

**One time:**
- install StikDebug, LocalDevVPN and our App;
- on a computer, plug in the cable to generate a pairing file once and import it into StikDebug (must be redone after an iOS update or reset).

**Every time:**
1. make sure LocalDevVPN is on (once turned on it can stay on);
2. in our App, tap "Enable JIT": the App opens `stikjit://enable-jit?bundle-id=…&script-name=universal.js` itself; by default StikDebug asks for confirmation once, and after the user confirms it brings our App back up;
3. choose the system to boot.

About 2 to 3 taps. Another way is to open StikDebug first, tap Enable JIT and choose our App. But our App is not on its list for assigning scripts automatically by name, so universal.js has to be assigned to it once first with a long press.

## 6. Problems encountered

| Problem | Handling |
|---|---|
| StikDebug's original Bundle ID and App Group belong to someone else's team | In the local copy, change the Bundle ID, remove the App Group and sign with the wildcard provisioning profile; nothing needs to be registered in the account |
| The pairing file can only be generated over USB | Ask the user to plug in the cable once |
| With LocalDevVPN on, devicectl over Wi-Fi takes 13 seconds to list files and copying times out at 40 seconds | Ask the user to plug the cable back in. The screenshot, process and lock state services worked normally throughout |
| CoreDevice's file service hangs: after being interrupted a few times, no App's container can be listed, and neither restarting the user-level CoreDeviceService on the Mac nor replugging the cable brings it back | Switch to AFC from the idevice tools (traditional lockdown house_arrest, through usbmuxd), which returns within a second |
| The second control command does not reach the App | devicectl skips files that have not changed; write different content each time (kept after switching to AFC as well) |
| `idevice-tools afc` occasionally hits Abort trap | Do not exit on failure; downloads are written to a temporary file first |
| Lock screen detection on the Mac side is slow, the iPod falls into deep sleep and cannot be woken | The App detects the lock screen and home screen itself with Vision and unlocks immediately |

## 7. Suggested next steps

1. **Settle the JIT route as StikDebug (or embedded StikJIT later) plus the universal protocol.** The LLDB-on-the-Mac route is kept only for development and debugging, and the script fixes are on hold as arranged by the decision session.
2. Add an "Enable JIT" button in the App (opening the `stikjit://` URL), and put the universal.js assignment into the URL parameters, so the user does not have to assign the script manually in StikDebug.
3. **The iPod touch 2nd gen SecureROM problem must be solved before official support** (section 4.3).
4. `increased-memory-limit`: on the iPhone 18 Pro there is still 2.4 GB of headroom after the 256 MB code region, so it is not urgent; the iPhone 14 Pro (6 GB) needs an actual measurement.
5. Idle power draw under the interpreter (3GS 108%) drops to 16% under JIT, so JIT is also key for battery life.

## 8. Files

- In the repository (not committed):
  - `patches/ios-txm-jit-protocol.patch` (timing log added)
  - `app/ClassicTouch/LaunchOptions.swift`, `GuestText.swift`, `EmulatorViewController.swift`
  - `scripts/ios/device-boot.sh`, `summarize-run.py`, `check-idle.py`
  - this report and `docs/reports/img/m1s3-*.png`
- In `work/` (not committed):
  - `work/ios/stikdebug/` (StikDebug source, AGPL)
  - `work/ios/DerivedData-stikdebug/`
  - `work/ios/stikdebug-local.entitlements`, `work/ios/stikdebug-prefs/`
  - `work/ios/tools/idevice-tools-0.1.68/`
  - `work/ios/secrets/` (pairing file)
  - `work/ios/runs/device/2026110122*` (records of each round)
- On the phone: StikDebug (`org.classictouch.dev.stikdebug`) and our App are installed, and the App was terminated after testing. LocalDevVPN is managed by the user.
