# iPhone 5 (A6, n41) iOS 10.3.4 in the app

- Date: 2026-11-04
- Execution session: a5-nand (after `docs/reports/a6-step1.md` section 17 and `docs/reports/ios-device-14pro.md` section 7). The user asked to put iOS 10 into the app: first in the iOS Simulator, then on the iPhone 14 Pro with JIT from the tethered Mac's LLDB.
- Not done: no commit or push, nothing downloaded, the iPhone 18 Pro was not touched, no StikDebug or pairing files. Firmware, device images and packs stay in `work/`.

## 0. Conclusions

1. **The app has an iPhone 5 / iOS 10.3.4 entry, and the 2016 row of the timeline is runnable.** The iPhone 5 boots with the same `n78` boot strategy as the iPod touch 5 (kernel bundle, two-partition USB root disk, IOP NAND directory) on the `iPhone-5` machine, which is a QEMU subtype of the iPod touch 5G machine, so its buttons and its DSI panel (screen-off detection) needed no new code. [verified: code, simulator and phone runs]
2. **iOS Simulator** (iPhone 18 Pro simulator, iOS 27.2, JIT): lock screen at 85 s, home screen at 88 s, Settings at 121 s, QEMU exited normally at 126 s. Maximum app footprint 1449 MB. The wallpaper is there. Run `work/ios/runs/20261104-225001-n41ap-14G61-jit`.
3. **iPhone 14 Pro** (iOS 27.0.1, JIT from the Mac's LLDB over USB): attached on the first try; the 256 MiB code buffer took 42.9 s to prepare; first frame at 43.7 s, lock screen at 144 s, one Home press, home screen at 146 s, then 20 s idle and a clean exit. Maximum footprint 1419 MB, minimum available memory 1653 MB, so the 1 GiB guest fits without an increased-memory-limit entitlement. Run `work/ios/runs/device/20261104-225505-n41ap-14G61-jit`.
4. **Pack:** `work/ios/packs/n41ap-14G61.ctpack`, 3.5 GB of data, built in 3 s; transferred to the phone in 105 s with `devicectl`; unpacked by the app in 6.2 s (simulator) and 8.2 s (phone).
5. **Not done:** Settings was not opened on the phone (only the home screen was asked for); one boot each, so no statistics; the interpreter backend was not tried. The open items from `ios-device-14pro.md` section 7 still apply to iOS 7 and 9 (the app's synthetic slide-to-unlock often fails on the phone; LLDB attaches reliably only with its packet log on). iOS 10 needs no slide, which is why it unlocked on the first press.

## 1. App changes

- `app/ClassicTouch/DeviceProfile.swift`: board `n41ap` = machine `iPhone-5`, 640 x 1136, no cellular (the boot bundle hides the baseband and CommCenter is disabled on the disk), no USB keyboard (the USB host port carries the root disk); model name "iPhone 5". The machine's default RAM is 1 GiB, and the app passes no `-m`.
- `app/ClassicTouch/Theme.swift`: iOS 10 added to `Era.runnable`; the iPhone 5 uses the flat device outline.
- `app/ClassicTouch/LibraryViewController.swift`: the help text for the "later" row now only covers iOS 8 (the old text said there was no emulator for A5 and A6 machines). UI strings stay Chinese for now.
- `app/ClassicTouch/GuestText.swift`: the lock screen check also accepts iOS 10's "Press home to open" and the lock screen's date line ("Wednesday, December 31"). "Press home to open" is visible only for a few seconds after the screen lights up; in the first simulator run none of the saved frames had it, so the lock screen was never recognized. The home screen's Calendar icon shows the weekday and the day on separate lines, without a comma or a month, so it does not match.
- `app/ClassicTouch/EmulatorViewController.swift`: on iOS 10 and later, `unlock` only presses Home. The slide that follows the Home press on older systems would page the iOS 10 home screen to the Today view.
- Scripts `sim-boot.sh`, `sim-settings.sh` and `device-boot.sh` accept the same two lock screen texts.

## 2. QEMU bridge

- `patches/a5-n78-ios-ui.patch` adds the `iPhone-5` / `n41ap` row (640 x 1136, scale 2) to the machine table in `contrib/ios-app/qemu-ios-ui.c`. Buttons (`ipod_touch_5g_press_button`) and the DSI panel test both use `object_dynamic_cast` to the iPod touch 5G machine type, which the iPhone 5 machine inherits from, so neither changed.
- The patch was regenerated against the file after the four iOS patches and the skeleton; `build-qemu.sh` then confirmed that the whole patch set applied to upstream equals the iOS working tree. Rebuilt: simulator JIT, device JIT and interpreter QEMU and dylibs, the simulator app and the device app (signed with the team that now has the 14 Pro registered).

## 3. The 14G61 device pack

Device directory `work/ios/devices/n41ap-14G61/`:

| File | Source |
|---|---|
| `device.lock.json` | board `n41ap`, boot strategy `n78`, 10.3.4, 14G61 |
| `kboot.bin` | `work/a6/kboot/n41-14G61-n3-clk.bin`: `tools/a5/n78_kboot.py` with `N78_TRUST` from `disk-n3.img.trust` and the full clock table |
| `disk.img` | APFS clone of `work/a6/nandfmt/disk-n3.img` (NAND format boot, `n78_diskfix.sh`, data migration done, wallpaper cache dropped, `a6-step1.md` 17.5) |
| `nand/` | clone of `work/a6/nandfmt/nand-n3` |

- The trust cache in the boot bundle matches the disk: the CDHashes of `mobileactivationd` and of the GL front end on disk-n3's system volume (read-only mount of a clone) and of the shared cache (`n78_devcache.py` run on a copy, since it edits in place) are all in `disk-n3.img.trust`. [verified]
- `scripts/ios/pack-device.py`: 3502 MB of data. The NAND's 4.7 GB nominal (2.3 GB allocated on the Mac) is almost all zero blocks, which the pack skips.
- First boot from the pack regenerates SpringBoard's wallpaper cache (it was dropped from disk-n3), which is what draws the wallpaper; both runs showed it.

## 4. iOS Simulator runs

| Run (`work/ios/runs/`) | How | Result |
|---|---|---|
| `20261104-223605-n41ap-14G61-jit` | `sim-settings.sh`, fresh state | Lock screen at 104 s, but not recognized (no "Press home to open" in any saved frame); stopped by hand after 6 minutes |
| `20261104-224325-n41ap-14G61-jit` | same, with the date-line check, state left by the run above | The forced stop left the data volume unclean: journal replay, SpringBoard and backboardd up, then the panel turned off before any lock screen frame was saved. Black for 6 minutes; stopped |
| `20261104-225001-n41ap-14G61-jit` | same, `state/` deleted first | Lock 85 s, home 88 s (one Home press), Settings 121 s (the first tap at 102 s did not open it, the second at 117 s did), exit 126 s, max footprint 1449 MB |

- `sim-settings.sh` reuses `state/` (it has no reset like `sim-boot.sh`), and neither script wakes a screen that turns off before the lock screen is recognized. The app's own autodrive does (`lock_wake`).
- Screenshots: `docs/reports/img/a6-app-library.png` (the timeline after the import), `a6-app-sim-lock.png` (86 s), `a6-app-sim-home.png` (96 s), `a6-app-sim-settings.png` (121 s), all from `20261104-225001-n41ap-14G61-jit`.

## 5. iPhone 14 Pro run

- Install: `devicectl device install app` with the newly built app. Pack: `devicectl device copy to` into `Documents/import/` (105 s, the app not running); the app unpacked it on its next launch (8.2 s).
- Boot: `PHONE=… IDLE=20 scripts/ios/device-boot.sh n41ap-14G61 jit 600`. Files went through `devicectl` (no `idevice-tools` on this Mac), so the app's autodrive recognized the lock and home screens; the LLDB packet log was on (the default since `ios-device-14pro.md` section 7.3).

| Step | Time |
|---|---:|
| Code buffer prepared by LLDB (256 MiB, page by page over USB) | 42.9 s |
| First frame | 43.7 s |
| Lock screen recognized | 144.3 s |
| Home pressed (`auto_unlock 1`) | 145.0 s |
| Home screen recognized | 146.2 s |

- Footprint 1382 MB at the lock screen, 1389 MB at the home screen, maximum 1419 MB; minimum `os_proc_available_memory` 1653 MB. Home screen idle CPU 103% (one core).
- Without the 43 s of code buffer preparation, the phone reaches the lock screen in about 100 s, against 85 s in the simulator and about 100 s on the Mac.
- Screenshots: `docs/reports/img/a6-app-14pro-lock.png` (144 s, "Press home to open" visible), `a6-app-14pro-home.png` (149 s), `a6-app-14pro-window.png` (the app window at 154 s), all from `work/ios/runs/device/20261104-225505-n41ap-14G61-jit`.
- At the end the app was ended on the phone and no debugger or script was left on the Mac.

## 6. Small fix asked for in the same brief

The "Cannot Use Device" notification on the iPod touch 5 7.1.2 lock screen was already fixed in the previous round: it comes from DeviceOMatic, which `n78_diskfix.sh` now disables for 11D257 in launchd's `overrides.plist`; the 7.1.2 pack was rebuilt and re-imported on the phone, and 105 screenshots from two boots never showed it (`ios-device-14pro.md` section 7.5).

## 7. Open items

- Settings on the phone, repeated boots for statistics, and the interpreter backend for iOS 10 on the phone.
- The scripts should reset `state/` (or wake the screen) so a forced stop does not leave the next run black.
- From `ios-device-14pro.md` section 7: the synthetic slide-to-unlock for iOS 7 and 9 on the phone, and the LLDB attach race that the packet log hides.
- iOS 10 still shows a low battery (`a6-step1.md` 15.4).

## 8. Files touched this round

`app/ClassicTouch/DeviceProfile.swift`, `Theme.swift`, `LibraryViewController.swift`, `GuestText.swift`, `EmulatorViewController.swift`; `patches/a5-n78-ios-ui.patch`; `scripts/ios/sim-boot.sh`, `sim-settings.sh`, `device-boot.sh`; this report and its screenshots; `README.md` (status table) and `CHANGELOG.md`.
