# M2 app prototype: no Mac needed, just pick up the phone and use it

- Date: 2026-11-02
- Execution session: m2-app-proto. Scope: a system list as the home page, one-tap JIT (`stikjit://`), returning to the list and switching systems, pausing the VM in the background, importing devices via Finder or the Files app, keeping the test entry points. The last step asks the user to unplug the cable and try it by hand (section 7, waiting for the user).
- Not done: `upstream/` not changed; no commit, no push; no issues or PRs filed upstream; the iPhone 14 Pro not touched; nothing new downloaded. The interface covers function only; no device body styling.

## 0. Conclusions

1. **The app is now "open it and you get the system list; tap one and it boots"**. Without JIT, tapping a system makes the app record which device was chosen, open `stikjit://enable-jit?bundle-id=org.classictouch.app&script-name=universal.js`, and exit by itself; StikDebug launches a new process with the debugger attached, and the new process sees "JIT available, a device waiting to boot" and boots it directly. Switching systems is the same path again, which also solves "a process can start QEMU only once".
2. **On the real device (iPhone 18 Pro, iOS 27.2), the whole chain was run end to end once by script** (`scripts/ios/device-app-flow.sh`, with no test switches enabled in the app):
   - list process → StikDebug → new process boots iOS 6 with JIT; the run directory appears 10 seconds after the app opens, and preparing the 256 MB code region takes 0.60 seconds;
   - 17.7 seconds in the background (the phone's Settings app in the foreground): the process ID is unchanged (31485), no extra run directory appears, and after returning the home screen is as before and the frame number keeps increasing;
   - switching systems: QEMU first exits cleanly (status 0), then a new process started via StikDebug boots iOS 7 (prepare 0.83 seconds) to the home screen;
   - 178 seconds in total, 0 taps on the phone.
3. **Background**: on `sceneWillResignActive` the app clears the foreground flag and pauses the VM (QMP stop), and resumes on returning to the foreground; it also pauses when going back to the list. In the simulator, pausing drops this process's CPU from 12% to 19% down to 1% to 2%.
4. **Import without scripts**: Finder (file sharing) or the Files app puts a `.ctpack` into `Documents/import/` (the root of Documents is recognized too), and the home page shows "Copying in" (`正在拷入`), progress and the result. On the real device an AFC upload (which is what Finder uses) of 473 MB took 14 seconds; import started automatically 3 seconds after copying finished, and unpacking took 0.5 seconds. Packs are unpacked to a staging directory first and merged in only once fully unpacked; a truncated pack reports "Import failed: ctpack ended early" (`导入失败：ctpack 提前结束`), and existing devices are unaffected.
5. **The test entry points are all still there**: `device-boot.sh` (iOS 6 in STIK mode: lock screen 15 seconds, home screen 23 seconds, idle 17%, consistent with stage 3's 14 and 22 seconds and 16%) and `sim-boot.sh` (3GS JIT: lock screen 16 seconds, home screen 45 seconds) both pass regression.
6. **Please try it by hand**: steps in section 7. Our copy of StikDebug has the confirmation popup for external requests turned off, so no confirmation tap is needed in between; real users will by default tap "Confirm" one extra time.
7. In the scripted real-device test the app lost the foreground twice (section 6.2): once for 7 seconds, after which the app came back by itself, cause unclear; once apparently because the phone was touched. Pause and resume both worked as designed. The nearly 3-minute absence in the user's hand test was, the user confirmed, the user switching away.
8. **User hand test** (section 7.1): the flow works, but on iOS 7 dragging the lock screen and paging the home screen are very laggy (6 to 10 frames per second, the process saturating one core), while Settings is not laggy (33 to 57 fps); iPod 3.1.3 is smooth (14 to 54 fps). The bottleneck is on the side of the emulated CPU plus GL forwarding and readback; recommend dispatching a separate performance session.

## 1. What was done

| Brief item | Implementation | Main files |
|---|---|---|
| 1. System list as home page | Scans `Documents/devices/`, reads `device.lock.json`, sorts by system version, and shows "iPhone 3GS · iOS 6.1.6" (written as iPhone OS before 4.0), the build number and disk usage (counted by allocated blocks, computed on a background thread); the iPod touch 2nd gen has an extra orange line "Experimental: may hang after the screen turns off" (`实验性：熄屏后可能卡住`). At the top is "Running" (when coming back from the emulator view), in the middle import, at the bottom JIT status | `LibraryViewController.swift`, `DeviceProfile.swift` |
| String Catalog | `Localizable.xcstrings`, source language Chinese, 67 entries; all interface text goes through `String(localized:)`; adding English later only touches this file | `Localizable.xcstrings`, `project.yml` |
| 2. One-tap JIT | `csops` checks `CS_DEBUGGED`, then checks whether the debugger is still attached (see 2.2); `canOpenURL` determines whether StikDebug is installed (added `LSApplicationQueriesSchemes: [stikjit]`); if it is not installed, the app explains and allows booting with the interpreter, warning that iOS 7 is basically unusable | `JIT.swift`, `RootViewController.swift` |
| 3. Switching systems | "‹ Back to list" at the top left of the emulator view; tapping a different system in the list brings up a confirmation; with StikDebug it goes through `stikjit://`, without it the user is asked to close the app and open it again (after reopening, that device boots directly with the interpreter) | `RootViewController.swift`, `EmulatorViewController.swift` |
| 4. Background | Losing the foreground and returning to the list both pause the VM; coming back resumes it | `Engine.setRunning`, `RootViewController.updateRun` |
| 5. Import | Watches `Documents/import/` and the Documents root, waits for copying to finish before unpacking, merges after staging, shows progress and results on the home page | `ImportManager.swift`, `DevicePack.swift` |
| 6. Test entry points | Launch arguments, `autostart.json`, `Documents/control/` and autodrive as before; new `-select`, `-fakejit`, and control commands `back`/`resume`/`select` | See section 5 |

The app name is still the placeholder "Classic Touch" (no Apple trademarks); naming models and systems (iPhone, iOS) in the list content is nominative use.

## 2. How enabling JIT and switching systems work

### 2.1 Flow

```
User taps a device
├─ Has this process started QEMU already?
│   ├─ Same device, still running → back to its screen, continue
│   └─ A different one → confirm "Switch to X?" → "switch process" below
├─ JIT available (CS_DEBUGGED and debugger still attached) → boot directly with JIT
├─ StikDebug installed → switch process (wants JIT)
└─ Neither → "No JIT": boot with interpreter / how to install StikDebug / cancel

Switch process: write Library/Application Support/pending-boot.json (device id, whether JIT is wanted, time)
       → if QEMU is running, qmp quit for a clean exit (block devices flushed to disk, wait at most 2 seconds)
       → wants JIT: open stikjit://…, exit(0) as soon as the system confirms the URL was handed off
         no JIT: exit(0), the user reopens the app themselves

New process starts: launch arguments / autostart.json name a device → test entry point, as before
          pending-boot.json present (valid 2 minutes if JIT is wanted, 10 minutes for interpreter) → wait for JIT up to 5 seconds → boot
                                                                       not in time → "Didn't get JIT": try again / use interpreter / cancel
          otherwise → list
```

### 2.2 Key points

- **Why the app exits by itself**: when StikDebug 3.2.0 handles `enable-jit` it uses `process_control_launch_app(…, start_suspended: true, kill_existing: false)` (`JITEnableContext.debugApp`), which does not kill an existing process. If our process were still alive, it would either fail to launch or attach to the old process, and the old process, having already started QEMU, is useless. So the app calls `exit(0)` as soon as the URL is handed off. Measured on the real device, it takes 10 seconds from opening the app to the new process creating its run directory, with no collision in between.
- **Detecting JIT**: per the brief, `csops(getpid(), CS_OPS_STATUS)` checks `CS_DEBUGGED`. But that is a sticky "has been debugged" flag, and since iOS 26 TXM only accepts code pages prepared by the debugger: the debugger must still be attached when QEMU allocates its code region, otherwise nobody catches `brk #0xf00d` and the process crashes outright. universal.js stays attached until QEMU sends the detach command, so on the real device both `CS_DEBUGGED` and `P_TRACED` are required to count as "JIT available".
- **A process launched by StikDebug has the debugger from the start**: StikDebug launches it suspended, attaches the debugger, then lets it run, so the new process sees JIT on its first check and the 5-second wait was never used.
- **Let QEMU exit cleanly first when switching systems**: in the real-device switch, `qemu_exit status=0` and `relaunch` happened within the same 0.1 seconds; for the guest itself it is like pulling the battery (the confirmation dialog says so), but on the host side all block devices were flushed to disk.
- **Faking JIT in the simulator**: launch argument `-fakejit on|off|nostik` (only effective in the simulator). With `off`, tapping a system only writes the pending file and exits; the host then launching the app again with `-fakejit on` is equivalent to the new process StikDebug would launch.

### 2.3 The user's extra tap

A real user's StikDebug has "confirm when an external request enables JIT" on by default, so every boot or system switch takes one extra "Confirm" tap in StikDebug (the copy on our phone has it turned off; see the M1 stage 3 report). The app's JIT help text already says "StikDebug may show a confirmation once; just tap Confirm" (`StikDebug 可能会弹一次确认，点确认即可`). Embedding StikJIT later could remove this hop.

## 3. Background and returning to the list

- `RootViewController.updateRun`: the VM runs only when "the app is in the foreground" and "the emulator view is showing". `Engine.setRunning(false)` first calls `qemu_ios_set_foreground(false)` (GL stops immediately; iOS kills background processes that issue GL), then `qemu_ios_ui_pause` (QMP stop, queued onto the QEMU main loop); with `true` it calls `set_foreground(true)` and then `qemu_ios_ui_resume`.
- Note that `qemu_ios_set_foreground(true)` by itself restarts a stopped VM (`ios_resume_bh` in `qemu-ios-ui.c`), so when the app returns to the foreground while on the list page it does not call it, and waits for the user to tap "Continue".
- Every pause and resume is logged in `events.log`: `vm_pause reason=background|list`, `vm_resume`.
- Pulling down Control Center or Notification Center also makes the app lose the foreground; the screen freezes then and continues on return.
- Benefits: the guest does not run in the background, which saves power; the guest's virtual clock is stopped, so it does not jump far ahead on return.

## 4. Import

- Watches two directories, `Documents/import/` and `Documents/` (directory events), and also scans once when the app returns to the foreground. A pack counts as fully copied only when its modification time has not changed for 3 seconds; one still being copied shows "Copying in" and is checked again every second.
- Unpacks into `import/.staging-<pack name>/`, and once fully unpacked moves the files one by one into the same location under `Documents` (replacing files with the same name, leaving the device's existing `state/` alone, so reimporting the same device does not lose user data), then deletes the pack. Staging left over from a previous kill is cleaned up at launch.
- Checks free space before unpacking and reports an error if it is insufficient (pack size plus 500 MB). If the system in the pack is currently running, it is not merged in yet and waits until the app is next opened. A failed pack is not retried while its size and time are unchanged; one that failed because it was read halfway through copying is retried automatically once the copy finishes and its size changes.
- Results are appended to `logs/import.log` in the same format as before (`device-boot.sh` fetches it).
- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in Info.plist were already on.

## 5. Test entry points (all kept)

| Entry point | Change |
|---|---|
| Launch arguments such as `-device` | As before; goes through `RootViewController`'s test entry branch and boots after import finishes |
| `Documents/autostart.json` | **Now single use**: renamed to `autostart.used.json` once read. Otherwise, whenever the user later opens the app themselves, it would boot that device directly and never show the list. `device-boot.sh` rewrites it before every launch, so it is unaffected |
| `Documents/control/` | Existing `unlock`, `home`, `quit`; new `back` (return to list), `resume` (return to the screen), `select` (file content is a device id; acts as if the user tapped it, with no confirmation when switching systems) |
| autodrive, opensettings | As before; enabled only when the app is opened via launch arguments or autostart.json. All off when a real user boots from the list |
| New `-select <id>` | Acts as if the user tapped this device in the list and goes through the full flow (including the trip to StikDebug); `device-app-flow.sh` uses it |
| New `-fakejit on\|off\|nostik` | Simulator only, see 2.2 |
| Saving screenshots | Test entry points as before (guest screen every 5 seconds by default, window every 15 seconds); booting from the list saves none by default, so they don't keep piling up on the user's phone |
| Run directories | Only the latest 30 are kept |
| Auto-lock | Previously the whole app prevented the phone from auto-locking; now only while the emulator view is open |

`scripts/ios/device-boot.sh` and `sim-boot.sh` are unchanged, and both pass regression (section 6).

## 6. Verification

### 6.1 iOS Simulator (ClassicTouch iPhone 18 Pro, iOS 27.2)

Taps on the screen are done with the simulator tools; `-fakejit` fakes JIT and StikDebug.

| Step | Result |
|---|---|
| Open with `-fakejit off` | List with three devices, disk usage, the iPod's experimental note, JIT "not enabled yet" (`JIT 还没开`) (`m2app-sim-1-list-nojit.png`) |
| Tap iPhone 3GS | Writes `{"device":"n88ap-10B500","wantJIT":true}`, process exits |
| Launch again with `-fakejit on` (equivalent to StikDebug launching it) | New process `boot config=list … backend=jit`, reaches the lock screen (`m2app-sim-2-booted-after-fakejit.png`) |
| Back to list | `vm_pause reason=list`, CPU drops to 1% to 2%; the top of the list shows "Running · Paused", the 3GS is marked "Running", JIT shows "The current system is using JIT" (`当前系统在用 JIT`) (`m2app-sim-3-back-to-list-paused.png`) |
| Tap "Continue" | `vm_resume`, CPU back to about 12% |
| Switch the system Settings app to the foreground for 8 seconds, then back | Same process (PID 14802), `vm_pause reason=background`, `vm_resume` |
| Tap iPhone 4 | Shows "Switch to iPhone 4 · iOS 7.1.2?" (`换成 iPhone 4 · iOS 7.1.2？`) (`m2app-sim-4-switch-confirm.png`); tap "Switch system": `relaunch` and `qemu_exit status=0`, process exits; launch again with `-fakejit on` and it boots iOS 7 directly |
| Tap iPod with `-fakejit nostik` | Shows "No JIT" (`没有 JIT`) with three buttons (`m2app-sim-5-nostik-alert.png`); choosing the interpreter boots normally |
| Tap 3GS while the interpreter is running | Shows the "Close App" kind of explanation (`m2app-sim-6-switch-nostik.png`); after closing and reopening, the 3GS boots directly with the interpreter |
| Slowly copy in the iPod pack (40 MB per second, imitating Finder) | "Copying in" (`m2app-sim-7-import-copying.png`), imported automatically once copied, the iPod appears in the list (`m2app-sim-8-import-done.png`) |
| Put a truncated pack in the Documents root | "Import failed: ctpack ended early", staging cleaned up, existing devices untouched |
| `sim-boot.sh n88ap-10B500 jit` regression | Lock screen 16 seconds, home screen 45 seconds, idle 13%, clean exit |

A problem was found and fixed in the simulator: when booting from the list, Root received "engine started" before it had registered the emulator view as "currently showing", so it treated it as "not showing" and cleared the foreground flag (GL for iOS 6 and 7 would then be refused). Changed to register first and then add the view, with one more check after boot.

Also, a few seconds after reaching the lock screen the iOS 7 guest turns off its own screen (backlight from 1971 down to 456, then fully black), and it lights up only after pressing Home below the screen. This is the guest's own behavior, the same as on a real iPhone, but a fully black screen the first time makes it look broken, so the instructions for the user mention it.

### 6.2 iPhone 18 Pro real device (iOS 27.2, USB, LocalDevVPN on)

**Home page**: `m2app-device-1-list.png`. The JIT row shows "not enabled yet", which means `canOpenURL(stikjit://)` recognized StikDebug.

**The whole user flow** (`scripts/ios/device-app-flow.sh`, records in `work/ios/runs/device/flow-20261102-002055/`):

| Time (from script start) | Event |
|---|---|
| 0 s | Kill the app, open it with `-select n88ap-10B500` (list process PID 31480) |
| 10 s | New run directory appears, boot process PID 31485, `backend=jit debugger=true`, preparing 256 MB takes 0.60 seconds |
| 64 s | iOS 6 home screen recognized (`m2app-device-2-ios6-home-via-stikdebug.png`). The script checks every 15 seconds; it sent one unlock each at 20 and 39 seconds (in-app time) |
| 64 to 97 s | **Background test**: the system Settings app switched to the foreground, then back. At in-app 56.3 seconds `vm_pause reason=background`, suspended by the system after 57 seconds, resumed at 73.5 seconds, `vm_resume` at 74.0 seconds (away 17.7 seconds). Process ID 31485 before and after, 1 run directory, frame number 275 → 278, home screen as before after returning (`m2app-device-3-ios6-after-background.png`), CPU back to 10% to 13% |
| 103 s | Write n90ap-11D257 to `control/select` |
| 115 s | Old process `relaunch`, `qemu_exit status=0`; new process PID 31505, `backend=jit debugger=true`, prepare 0.83 seconds |
| 165 s | iOS 7 home screen recognized (`m2app-device-4-ios7-home-after-switch.png`) |
| 178 s | `control/quit`, app ends |

`foreground again: N GL calls refused` did not appear during the background part: the VM had stopped first, so there were no GL calls at all in the background.

**`device-boot.sh` regression** (`STIK=1 IDLE=40 … n88ap-10B500 jit`): lock screen 15 seconds, home screen 23 seconds, idle 17% (25 seconds), prepare 0.81 seconds, clean exit. `autostart.json` was renamed to `autostart.used.json` after being read, and opening the app normally afterwards shows the list.

**Import** (AFC upload, which is what Finder file sharing uses): uploading the iPod pack while the app showed the list, 473 MB took 14 seconds, during which the home page showed "Copying in" (`m2app-device-5-import-copying.png`); it imported automatically once copied, in 0.5 seconds, overwriting the existing copy of the same device (`m2app-device-6-import-done.png`).

**Two unexplained losses of foreground**:
- In the flow test, from 2.8 to 9.9 seconds into the iOS 6 boot, the app lost the foreground for 7 seconds (not during the second boot). It may have been a system prompt the first time the app was launched by StikDebug after install, or StikDebug briefly coming to the foreground. During this time the VM was stopped by design, so QEMU's screen-on time was recorded as 22.6 seconds (stage 3: 12.2 seconds; subtracting the 7.1 seconds roughly matches).
- In the `device-boot.sh` regression, the app was switched to the background at 50 seconds, suspended at 52 seconds, and only came back at 94.8 seconds, by which time the idle period was over and it exited as planned. During this part the script only fetches files over AFC and does not switch apps, so it looks like someone touched the phone. Idle CPU covers only the first 25 seconds; the lock screen and home screen numbers are unaffected, and as agreed there was no remeasurement.

During the hand test, please watch for any popups (section 7).

## 7. Please try it by hand (this step stops here and waits for the user)

Prerequisites: the phone has the latest app (already installed) and our build of StikDebug; all three devices are present.

1. Unplug the cable.
2. Make sure LocalDevVPN is on (not some other VPN).
3. Open Classic Touch. The home page is the system list, with three devices; the JIT row at the bottom says "not enabled yet".
4. Tap "iPhone 3GS · iOS 6.1.6". The app jumps to StikDebug, and a few seconds later automatically returns to Classic Touch and starts booting. Our copy of StikDebug has the confirmation popup turned off, so nothing needs tapping in between; a real user would tap "Confirm" once more in StikDebug here.
5. The lock screen appears in about 15 seconds. Left untouched for a few seconds, the lock screen turns off and goes black; tap "Home" below the screen to wake it, then swipe left to right on the emulated screen to unlock, and you see the iOS 6 home screen.
6. Tap "‹ Back to list" at the top left. The top of the list shows "Running · Paused". Tap "iPhone 4 · iOS 7.1.2"; "Switch to iPhone 4 · iOS 7.1.2?" pops up; tap "Switch system".
7. The app jumps to StikDebug once more and automatically comes back to boot iOS 7; the lock screen appears in about 30 seconds; as before, wake it with Home and swipe to unlock to reach the home screen.
8. When done, swipe the app away in the app switcher.

If it gets stuck in StikDebug (most likely LocalDevVPN is not connected): open LocalDevVPN and return to Classic Touch within 2 minutes; it will say "Didn't get JIT" (`没拿到 JIT`); tap "Try again".

Please also tell us: whether any system popup appeared along the way; roughly how many seconds it takes from tapping a system to returning to Classic Touch; and which step felt awkward.

### 7.1 User hand test results (from 2026-11-02 00:30)

User feedback: **"iOS 7 swiping and unlocking are very laggy, swiping on the home screen is very laggy, but Settings is not laggy."** The flow itself (list, jump to StikDebug, boot, back to list, switch system) worked (the run records on the phone were fetched to `work/ios/runs/device/handtest/`).

Two runs:

| Run | Events |
|---|---|
| 00:30:39 iPod touch 2nd gen 3.1.3 (first row of the list, not the 3GS from the brief) | JIT boot; the app lost the foreground at 10.1 seconds and only came back at 174.7 seconds; back to the list at 221.9 seconds, system switch at 228.0 seconds (`qemu_exit status=0`) |
| 00:34:30 iPhone 4 iOS 7.1.2 | JIT boot (no switch-away at the start this time); away for 2 minutes from 78 to 198 seconds, then twice more for a few seconds each |

Frames per second (difference of frame numbers in stats.csv) and this process's CPU:

| Screen (inferred from time and frame output) | Frames per second | CPU (share of one core) |
|---|---|---|
| iOS 7 boot until before the lock screen (0 to 25 seconds) | 0 to 1 | 100% to 140% |
| iOS 7 dragging the lock screen to unlock (29 to 44 seconds) | **6 to 10** | 95% to 103% |
| iOS 7 animation into the home screen (45 to 57 seconds) | 28 to 57 | 50% to 100% |
| iOS 7 paging the home screen etc. (the laggy stretches within 198 to 260 seconds) | **5 to 10** | 70% to 96% |
| iOS 7 smoother stretches (presumably Settings) | 33 to 57 | 45% to 98% |
| iOS 7 at rest (71 to 78, 244 to 250 seconds) | steady 10 | about 40% |
| iPod 3.1.3 unlocking and use (175 to 222 seconds) | 14 to 54 | 30% to 60% |

Preliminary assessment:
- What lags is the lock screen and the home screen. In these two places iOS 7 has many compositing layers (full-screen wallpaper, translucent layers, the whole screen moving while dragging), so every frame needs a large number of GL calls forwarded on the vCPU thread, and then the whole screen read back into guest memory with glReadPixels. When it lags the process basically saturates one core and produces only 6 to 10 frames, which means the bottleneck is on the emulated CPU side (guest code plus GL forwarding and readback on the same thread), not the app interface; Settings is an opaque list with few layers, so it is smooth.
- At rest it holds a steady 10 frames per second with CPU at about 40%, which is the same thing as "iOS 7 idle 44%, frame swaps only a third of the Mac's" in the M2 host GL report.
- On a real iPhone 4, iOS 7's lock screen and home screen were somewhat laggy too, so part of it is the system itself, but here it is clearly slower.
- This is beyond the scope of the app prototype; recommend dispatching a separate performance session: use `IT_GLES_PROF=1` to see where the GL bridge's time goes (readback, texture upload, or guest CPU), then decide whether to add IOSurface for CoreAnimation surfaces to avoid readback, move GL to its own thread, or start on the TCG side. It can first be reproduced in the simulator on the Mac (same EAGL backend), without tying up the phone.

In the iPod run, the nearly 3-minute absence starting at 10 seconds into boot was, the user confirmed, the user switching away, not being stuck in StikDebug. So "tap a system, StikDebug enables JIT, then the app automatically comes back and boots" holds in the user's hands. The 7-second loss of foreground from 2.8 to 9.9 seconds in the first boot of the scripted test is still unexplained; the app came back by itself, and it does not affect use.

## 8. Known issues and next steps

1. **Two unexplained losses of foreground** (section 6.2): the user's hand test can help confirm whether they are system prompts.
2. **iPod touch 2nd gen hanging after the screen turns off** is not fixed (per the user's decision); it is marked "Experimental" in the list.
3. **The guest lock screen turns off after a few seconds**: users may think the black screen means it is broken. Could consider unlocking once automatically after boot, or showing a "press Home to wake" hint on screen.
4. **Deleting a system**: devices cannot be deleted from the list yet; `devices/<id>` can only be deleted with Finder or the Files app.
5. **"Open in another app" for .ctpack**: no document type is declared, so from the Files app or AirDrop it cannot be opened directly with "Open in Classic Touch"; it can only be copied into this app's folder. To support it, add a UTI declaration.
6. **English**: the String Catalog is in place; adding English only needs English added to `Localizable.xcstrings` in Xcode and the translations filled in.
7. Every system switch goes through StikDebug once (one extra confirmation tap for real users). Embedding StikJIT could remove it.

## 9. Files

- In the repository (not committed):
  - New: `app/ClassicTouch/RootViewController.swift`, `LibraryViewController.swift`, `JIT.swift`, `ImportManager.swift`, `Localizable.xcstrings`
  - Changed: `app/ClassicTouch/EmulatorViewController.swift` (removed the menu and import; added back to list, pause, new control commands, screenshot saving rules), `Engine.swift` (`setRunning`), `DeviceProfile.swift` (display name, disk usage, sorting), `DevicePack.swift` (staging, progress, merge), `LaunchOptions.swift` (autostart single use), `AppDelegate.swift`
  - `app/project.yml` (`LSApplicationQueriesSchemes`, String Catalog settings), and the regenerated `ClassicTouch.xcodeproj`
  - New: `scripts/ios/device-app-flow.sh`
  - This report and `docs/reports/img/m2app-*.png` (14 images, all checked by eye; the one switched to the system Settings app shows the user's Apple ID and Wi-Fi name, so it was left out)
- In `work/` (not committed): `work/ios/runs/device/flow-20261102-002055/` (all screenshots and logs of the flow test), `work/ios/runs/device/20261102-002453-n88ap-10B500-jit*` (regression), `work/logs/m2app-*.log` (build and per-run output)
- On the phone: the new app is installed and not running; all three devices are present (the iPod one was reimported once, same contents); `Documents/autostart.used.json` was left by the regression and is harmless. StikDebug untouched.
