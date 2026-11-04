# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There is no release yet, so milestones are listed by date; details are in `docs/plan.md` and `docs/reports/`.

## Unreleased

### 2026-11-04

- **iOS 10.3.4 in the app**: the iPhone 5 (A6) is a new entry in the timeline. In the iOS Simulator it reaches the lock screen in 85 s, the home screen and Settings; on the iPhone 14 Pro, with JIT from a tethered Mac, it reaches the home screen in 146 s with a peak footprint of 1.4 GB. (`docs/reports/a6-app.md`)
- **New machine: iPhone 5 (A6, S5L8950X).** iOS 10.3.4 reaches the lock screen and home screen on every boot on a Mac, with its default wallpaper, opens Settings, and wakes with Home after the screen goes off. This includes the Swift CPU, the A6 decrementer, letting our signatures through via the static trust cache, touch, and the GL front end filling the TLS slot Apple's gl* functions read. (`docs/reports/a6-step1.md`)
- **iOS 9.3.5 on the A5** reaches the lock screen, home screen and Settings. (`docs/reports/a5-step1.md`, section 3.17)
- **The A5 in the app**: iOS 9.3.5 and 7.1.2 both reach Settings in the iOS Simulator. (`docs/reports/a5-app.md`)
- **iPhone 14 Pro**: the app is installed and, with JIT from a tethered Mac, iOS 9.3.5 and 7.1.2 both reach the home screen. (`docs/reports/ios-device-14pro.md`)
- iOS 7.1.2 on the A5 reaches the lock screen and home screen; a script unlocks it and opens Settings.
- Standard open-source files: contributing guide, code of conduct, security policy, issue and pull request templates. All repository text is now in English.

### 2026-11-03

- **New machine: iPod touch (5th gen, A5, S5L8940X).** AIC interrupt controller, I2C and the PMU, PMGR clock gating, CDMA, display and USB. The iOS 7.1.2 and 9.3.5 kernels boot and mount their root from a USB disk.
- A high-level model of the NAND's IOP, which formats the partitions and creates the effaceable storage and the system keybag. With the GL bridge connected, the A5 draws the iOS interface.

### 2026-11-02

- The timeline is complete: iPhone OS 1.0 on the original iPhone, 2.2.1 on the iPod touch (2nd gen), and iOS 4.3.5 and 5.1.1 on the iPhone 4 reach the home screen on a Mac and in the iOS Simulator. The app supports the original iPhone's boot method.
- The goal widens to iPhone OS 1 through iOS 10.

### 2026-11-01

- In the app on an iPhone 18 Pro, iPhone OS 3.1.3, iOS 6.1.6 and iOS 7.1.2 reach the home screen, with JIT from StikDebug and graphics on the phone's GPU (OpenGL ES 1.1 and 2.0 on EAGL).
- The timeline interface: home screen, emulator screen, settings, about, icon.
- Faster iOS 7: one readback per frame, taking scrolling from 5 to 49 frames per second.
- Project start: qemu-ios cross-compiled for iOS, and the JIT protocol for iOS 26 and later (`brk #0xf00d`).
