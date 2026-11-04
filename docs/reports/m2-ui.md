# M2 UI: making the App look good

- Execution session: m2-ui. Two steps: first produce design proposals for the user to choose from (step 1), then implement the chosen one (step 2).
- On 2026-11-02 the user chose the redone design A, "Timeline" (`年表`); step 2 is complete.
- Not done: no changes to `EmulatorViewController.swift`, `Engine.swift`, `GuestText.swift` (the iOS 7 optimization session is changing them), no changes to `RootViewController.swift` (not needed), no use of `upstream/` or `scripts/ios/`, no commit, no push, nothing downloaded (all fonts are built into the system), nothing installed or run on the iPhone.

## 0. Conclusions (step 2)

1. **The home page is implemented as the "Timeline"** and checked in the iOS simulator in light mode, dark mode and large text: major versions 1 to 10 are laid out as a timeline, one row per device (large year, model, system version, build number, footprint, line drawing of the device). Consecutive years with nothing imported are merged into one gray row, and iOS 8 to 10 get one row marked "Later" (`以后`). The year of the device that is running turns red, with a red bar on the left and "Resume" (`继续`); tapping it returns to the emulator screen.
2. **The new look of the emulator screen is written as a separate file**, `EmulatorChromeView.swift`, and per the brief is not yet connected to `EmulatorViewController`; in the debug build the launch argument `-uipreview <device id>` shows what it looks like. Once the iOS 7 optimization session is done, connecting it takes about ten lines (section 3).
3. **The App icon** is changed to the Timeline style (white background, "2007", a red bar). The colors are in `Assets.xcassets`, one set each for light and dark.
4. **The test entry points are not broken**: `-device` boot, `control/back` back to the list, and tapping "Resume" to return to the screen were each run once in the simulator; not a single line of the `-fakejit`, `-select`, `autostart.json` or `control/` code was touched. Debug and Release both compile, with 0 warnings in the new code.
5. Not installed on the real device; the decision session will schedule that.
6. **Settings, About and "Buy me a coffee" (`请我喝杯咖啡`) were also added** (requested by the user on 2026-11-02, see step 3). The donation link is still empty, waiting for the user to provide it.
7. **The new look of the emulator screen is connected to `EmulatorViewController` and installed on the iPhone 18 Pro** (see step 4): in the device iOS 7 swipe test, dragging on the lock screen ran at 60.3 and dragging on the home screen at 54.5 frames per second, comparable to the numbers after the iOS 7 optimization (59.7, 49.0); the data of all three devices on the phone is kept.

## Step 2: implementation (2026-11-02)

### 1. What changed

| File | Content |
|---|---|
| `app/ClassicTouch/LibraryViewController.swift` | Rewritten. Plain table, no system navigation bar; row types are header, import, system, gray row, footnote and JIT box. Ordered by major version 1 to 10, consecutive unimported ones merged into one row, ones above `Era.supported` (currently 7) marked "Later". The public interface (`current`, `jitState`, `onSelect`, `onResume`, `onJITHelp`, `reload()`) is unchanged, so `RootViewController` needs no change. Tapping a gray row shows the import instructions; tapping "Later" explains why it cannot be opened yet. The debug build adds a `-uipreview` entry point |
| `app/ClassicTouch/LibraryCells.swift` (new) | The look of the row types above |
| `app/ClassicTouch/Theme.swift` (new) | Colors, fonts (years use the built-in DIN Condensed, all other text follows the system text size), the year table `Era`, the device line drawing `LineDeviceView` (4 shapes covering 8 models, all outlines drawn by us) |
| `app/ClassicTouch/EmulatorChromeView.swift` (new) | Emulator screen look: black background, large year, model and system at the top, and "⋯"; a thin rule; run status ("⋯" collapses or expands it, stored in UserDefaults); the middle is left for the guest screen (360 × 540 on a 402-wide screen); three big square buttons at the bottom: "Timeline", "Home" and "Power" (`电源`). Includes a debug build preview, `EmulatorChromePreviewController` |
| `app/ClassicTouch/Assets.xcassets` (new) | `AppIcon` (1024, captured from `docs/design/mockups/app-icon.html`); colors Paper, Ink, Mid, Faint, Rule, Accent |
| `app/ClassicTouch/Localizable.xcstrings` | Added 19 entries, removed 8 that were no longer used, 78 in total |
| `app/ClassicTouch.xcodeproj` | Regenerated with `xcodegen generate`; only the 3 Swift files above and the asset catalog were added, `project.yml` unchanged |

So that the shared project would not fail to build midway (another session is also building it), the new home page was first changed in a staging project in `work/ios/ui-build/` until it compiled, then copied back in one go and the shared project regenerated; the staging project has been deleted.

### 2. Verification (iOS simulator)

Our own simulator device "ClassicTouch UI" (iPhone 18 Pro, iOS 27.2, UDID in `work/ios/ui-sim-udid`), our own build directory `work/ios/DerivedData-ui`. The three devices were placed in the simulator's Documents directory as APFS clones, taking no extra space.

| Check | Result | Image |
|---|---|---|
| Cold start, `-fakejit off` (StikDebug installed, no JIT yet) | Timeline, two gray "Not imported yet" (`还没导入`) rows, "2014–16 iOS 8, 9, 10 Later", JIT box "not on yet" (`还没开`) | `img/ui-impl-home.png` |
| Boot with `-device n88ap-10B500 -tcg jit -fakejit on`, write `control/back` after 20 seconds | `vm_pause reason=list`; the 3GS row turns red with "Resume", JIT box "Current system is using JIT" (`当前系统在用 JIT`) | `img/ui-impl-running.png` |
| Tap the 3GS row | `vm_resume`, back to the emulator screen (still the old look, see section 3) | |
| Dark mode | White text on black, red switched to its dark variant | `img/ui-impl-home-dark.png` |
| Accessibility large text (accessibility-large) | Text wraps normally; years do not grow and do not overlap other text | (no image) |
| `-uipreview n88ap-10B500` | New look of the emulator screen; after tapping "⋯" to collapse the status line, the guest screen re-centers; tapping "Timeline" closes the preview | `img/ui-impl-emulator.png` |
| Home screen | New icon | `img/ui-impl-icon.png` |
| Debug and Release builds (simulator) | Both pass, no warnings in the new code | |

Found and fixed during checking:

1. At large text sizes, the year in system rows was truncated to "…", and the year in gray rows pressed into the text on the right. The year column has a fixed width and the year is already 46 pt, so it no longer grows with the system text size and shrinks automatically when it does not fit.
2. On cold start the "Experimental" (`实验性`) note in the iPod row was squashed; after a relayout it looked normal again. The cause was a height constraint that UIStackView adds when toggling the hidden state of arranged subviews, which lingered until the first row height measurement; changed to not toggle hidden, so when there is no note that area is naturally 0 high.

### 3. How to connect the emulator screen (done in step 4, kept here as a record)

Also written at the top of `EmulatorChromeView.swift`. About ten lines:

1. `viewDidLoad`: first `view.addSubview(chrome)`, then add `screen` (the screen sits on top; chrome's own empty areas do not take touches, so touches still land on `EmulatorViewController`); `chrome.configure(profile, backend: "JIT" or "解释器")`, where the second value is "Interpreter".
2. Replace the existing `status`, `backButton`, `homeButton`, `powerButton` with `chrome.status`, `chrome.back`, `chrome.home`, `chrome.power`. Attach the back, press and release actions as before, and delete the lines that set the font, border and corner radius.
3. `viewDidLayoutSubviews`: `chrome.frame = view.bounds; chrome.layoutIfNeeded(); screen.frame = chrome.screenFrame(for: guestSize)`.
4. Before boot, Home and Power are still hidden first (`chrome.home.isHidden = true`) and shown after boot.

After connecting, run through the test entry points in the simulator (touch coordinates for autodrive and the swipe test are normalized to the guest screen, so a change in screen position does not affect them).

### 4. Not done, and things to watch

- The dialogs for switching systems, no JIT and import instructions are still the system `UIAlertController`, with the style unchanged.
- No English added (the String Catalog is in place).
- When new models or versions are supported later, change `Era.runnable` in `Theme.swift` (currently 2...7), and the "Later" rows will automatically become "Not imported yet".
- After reinstalling the App in the simulator, the data container path changes (the contents remain), so scripts must fetch `simctl get_app_container` again each time.
- The debug preview reads `Documents/ui-preview.png` as the screen image; it was only placed in the simulator, and the App ships no screenshots of any Apple system.
- The simulator device "ClassicTouch UI" is kept (shut down) and can be used later when connecting the emulator screen.

## Step 3: Settings, About, Buy me a coffee (2026-11-02)

The user's request: "Also add Settings and About, and ideally a donate button so people can buy me a coffee." The style follows the Timeline: black text on white paper, thin rules, large titles over a thick black rule.

### 1. What was done

- **Entry point**: a gear was added to the left of the import button at the top right of the home page (`LibraryCells.swift`, `LibraryViewController.swift`). The Settings, About and License pages are all pushed onto the same navigation stack; the system back button reads "Timeline", and swiping right goes back.
- **Settings** (`SettingsViewController.swift`, new):
  - Display (`显示`): Appearance (`外观`) (System (`跟随系统`), Light (`浅色`), Dark (`深色`)), a pop-up menu; the choice takes effect immediately, is stored in UserDefaults, and is applied from the first frame the next time the App opens. The emulator screen always has a black background and is not affected.
  - Systems and storage (`系统和存储`): one row per device, showing its footprint; the device that is running shows "Running" (`运行中`). Tapping a device asks for confirmation and then deletes it (the title gives the model and system, the body says how much data will be deleted and that it cannot be recovered). The running one cannot be deleted, and an explanation says what to do. Below that is how much space is left on the phone, plus "How to import a system" (`怎么导入系统`).
  - JIT: the "JIT and StikDebug" (`JIT 和 StikDebug`) explanation (using Root's existing dialog).
  - About (`关于`): "About Classic Touch" (`关于 Classic Touch`) plus the version number, then "Buy me a coffee".
- **About**: a small icon (drawn after the App icon), name and version; a short introduction; Open source (`开源`) (Source code (`源代码`) links to the GitHub repository, license GPL-2.0-or-later, view the full text); Acknowledgements (`致谢`) (qemu-ios, QEMU, Light Touch, StikDebug, each with its license; tapping opens the project home page in the in-App Safari) and Licenses of dependencies (`依赖库的许可证`); Disclaimer (`声明`) (not affiliated with Apple, trademarks belong to Apple, the App ships no Apple system files); and "Buy me a coffee" at the end too.
- **Full license text** (`许可证`): new resource `app/ClassicTouch/ThirdPartyLicenses.txt` (about 200 KB). Following the comment in `scripts/ios/build-deps.sh`, "must ship with the App when distributing under the GPL", it combines this App's LICENSE, qemu-ios's LICENSE and COPYING.LIB, Light Touch's LICENSE, and the original license texts of the 8 libraries QEMU links statically (GLib, PCRE2, proxy-libintl, pixman, libslirp, OpenSSL, Nettle, libffi). When displayed, hard line breaks inside paragraphs are joined so it reads well on the phone.
- **Buy me a coffee**: a big button with white text on black, one at the bottom of the Settings page and one at the bottom of the About page. The link is in `Links.coffee` and **is currently empty**; tapping shows "The donation page isn't set up yet" (`捐赠页还没设置好`). Once the user picks a platform and provides a link, changing this one line is enough.
- **The Timeline was also made accurate**: iPhone OS 1 only runs on the original iPhone and iPod touch (1st gen), and the App does not support those two yet (they need pflash), so the old "Not imported yet" was wrong. They are now marked "Later" like iOS 8 to 10, and tapping explains why (`Era.runnable = 2...7`).
- The String Catalog gained 38 more entries and lost 1, 115 in total. The shared project was regenerated with `xcodegen generate`, adding only `SettingsViewController.swift` and `ThirdPartyLicenses.txt`.

### 2. Verification (iOS simulator)

| Check | Result | Image |
|---|---|---|
| Home page | Gear to the left of the import button; the 2007 row becomes "iPhone OS 1 Later" | `img/ui-impl-home.png` |
| Tap the gear | Goes to Settings, back button "Timeline" | `img/ui-impl-settings.png`, `img/ui-impl-settings-2.png` (lower half) |
| Choose "Dark" for appearance, then back to "System" | Changes immediately, the menu checkmark is right | |
| Tap "Buy me a coffee" | Link empty, shows "The donation page isn't set up yet" | |
| About, License | Content correct, license reflowed by paragraph | `img/ui-impl-about.png` |
| Delete the iPod (a clone, cloned back after deleting) | Confirmation dialog gives the model and 487.1 MB; after deleting the directory is gone, and Settings and the home page both refresh | `img/ui-impl-delete.png` |
| Boot iOS 6 with `-device`, return to the list, then go to Settings and tap it | Shows "Running"; tapping explains it cannot be deleted | |
| Running (with gear), dark home page | Normal | `img/ui-impl-running.png`, `img/ui-impl-home-dark.png` |
| Debug and Release builds | Both pass, no warnings in the new code | |

Found and fixed during checking:

1. **Deletion stopped halfway**: in devices made by FirmwareKit, `nand/` is a read-only directory (r-x). Deleting directly first removed `device.lock.json` and other files and then failed with no permission on `nand/`, so the device vanished from the list while hundreds of MB remained. Now every directory in the tree is made writable first and then deleted; a retest in the simulator removed the whole directory cleanly.
2. Tapping delete before the footprint was computed showed the size as "?" in the confirmation dialog: now the size is omitted until it is computed.
3. The "Settings" (`设置`) title in the middle of the Settings page's navigation bar duplicated the large title: the one on the navigation bar was removed.

### 3. For the user to decide

- **Donation link**: which platform (Buy Me a Coffee, Ko-fi, GitHub Sponsors, Afdian and so on), and a page address. Two are possible (for example one international, one for China), and the button could then first show a choice.

## Step 4: connecting the emulator screen and device verification (2026-11-02)

The decision session passed on the user's approval: after the iOS 7 optimization session is done (`docs/reports/m2-ios7-perf.md`), connect the new look to the emulator screen and then install it on the phone.

### 1. Wiring

- `EmulatorViewController.swift`: 51 lines changed (not counting the iOS 7 session's changes). The existing `status`, `backButton`, `homeButton`, `powerButton` became properties pointing to the controls of the same names in `EmulatorChromeView`; not a line of the rest of the code (status text, button press and release, back, hide and show) changed. The code that set the font, border, corner radius and computed positions by hand was deleted; `viewDidLayoutSubviews` is now three lines; after boot reads the device, `chrome.configure` is called (year, model, system, JIT or interpreter). The swipe test, `-perf`, `-qemuenv`, `threads.csv` and the lock screen recognition fallback added by the iOS 7 session were not touched.
- `EmulatorChromeView.swift`: on models without a notch (iPhone SE) the safe area is 0 at top and bottom, so the year touched the top edge of the screen and the buttons were only 8 pt from the bottom edge; minimum margins were added (14 at the top, 16 at the bottom). The note at the top of the file now says "connected".
- String Catalog: added "Interpreter", removed the unused "‹ Back to list" (`‹ 返回列表`), 115 in total.

### 2. Simulator (our own "ClassicTouch UI")

| Check | Result |
|---|---|
| Boot from the list (`-fakejit off`, tap iPhone 4, the App records the pending boot and quits; reopen with `-fakejit on`, equivalent to StikDebug launching it) | `boot config=list`, new look: "2013 iPhone 4 · iOS 7.1.2 · JIT" at the top, the status line, the guest screen centered (`img/ui-impl-emulator-sim.png`) |
| Power button | Guest screen turns off |
| Home button | Wakes it when the screen is off |
| Swipe "Deslizar para configurar" on the guest screen | Goes to language selection, touch position correct |
| "⋯" collapse, expand | After the status line collapses the guest screen re-centers; tapping again restores it |
| "Timeline" | `back_to_list`, `vm_pause reason=list`; the iPhone 4 row on the home page turns red with "Resume" |
| Temporary iPhone SE (3rd gen) simulator, `-uipreview` | Fits even on the shortest-screen model, centered, with margins top and bottom (`img/ui-impl-emulator-se.png`); this simulator was deleted afterwards |
| `SIM_UDID=… scripts/ios/sim-boot.sh n88ap-10B500 jit` | Lock screen 18 seconds, home screen 46 seconds, idle 14% (before: 16 seconds, 45 seconds, 13%), quit normally |
| `SIM_UDID=… scripts/ios/sim-swipe.sh n90ap-11D257` | Recognized the lock screen, unlocked, recognized the home screen, every segment completed. Frames per second: lock screen drag 60.0, lock screen still 59.5, home screen still 10.0, page flip 19.9, press and drag 44.5, still 10.0; the iOS 7 session's two runs were 60, 59 to 59.3, 10, 20.4 to 22.0, 49.3 to 53.9, 10.1. Press and drag is slightly lower; the simulator renders in software on the CPU and fluctuates a lot, so the real device is what counts |
| Debug and Release builds | Both pass |

The App supports portrait only, so there is no rotation to test.

### 3. Real device (iPhone 18 Pro, iOS 27.2)

- Built the iphoneos version (Debug, build directory `work/ios/DerivedData-ui`): the signing team ID was read from the local development certificate inside the command and passed straight to `xcodebuild`, not written into any repository file. Two dylibs are embedded.
- Installed over the existing App with `devicectl device install app`, **App data kept**: all three devices are on the home page (972.2 MB, 2.16 GB, 2.74 GB, 5.88 GB in total), nothing re-uploaded.
- Opened the App normally (no JIT): the new Timeline home page (`img/ui-device-home.png`; the phone has bold text on, so the text is heavier than in the simulator).
- `STIK=1 SWIPETEST=1 IDLE=20 scripts/ios/device-boot.sh n90ap-11D257 jit`, one run, not interrupted (iPhone mirroring off), recorded in `work/ios/runs/device/20261102-015446-n90ap-11D257-jit/`: lock screen 27 seconds, home screen 42 seconds, quit normally, the App was not running after the test. Emulator screen screenshot `img/ui-device-emulator.png` (a window screenshot the App saved itself at second 67).

| Screen | This run (new look) | After m2-ios7-perf changes |
|---|---|---|
| Dragging back and forth on the lock screen | **60.3** frames per second, CPU 101% | 59.7, 99% |
| Lock screen still | 60.0, 76% | 60.0, 96% |
| Home screen page flip (whole segment) | 23.9, 49%; the flip animation itself 44.5 (5 times: 52, 46, 45, 44, 36) | 22.7, 49%; animation itself 36 |
| Home screen press and drag | **54.5**, 78% | 49.0, 74% |
| Home screen still | 10.0, 41% | 10, 41% to 42% |

The new look does not slow iOS 7 down: every item is near the numbers after the iOS 7 optimization, and page flip and press and drag are even slightly higher (the guest screen went from full width 402 × 603 to 360 × 540, so the App composites slightly fewer pixels, but it is mostly normal fluctuation).

### 4. For the user to try by hand (to be passed on by the decision session)

1. Unplug the data cable and make sure LocalDevVPN is on.
2. Open Classic Touch: the home page is a Timeline in black text on white, with a gear and an import button at the top right.
3. Tap "2013 iPhone 4": it jumps to StikDebug (you may need to tap a confirmation once), then comes back automatically and boots, reaching the lock screen in about 30 seconds.
4. Emulator screen: a large "2013" and the model at the top, and three buttons at the bottom: "Timeline", "Home", "Power". After a few seconds on the lock screen the screen dims and turns off; tap "Home" to wake it, then swipe on the emulated screen to unlock.
5. Try "Power" (screen off, then press "Home" to turn it back on), and tap "⋯" at the top right to collapse or expand the line of small text.
6. Tap "Timeline" to go back to the home page: the iPhone 4 row turns red and says "Running, paused" (`运行中，已暂停`); tap "Resume" to return to the screen.
7. Back on the home page, tap the gear: look at Settings (appearance can be switched to dark) and "About Classic Touch". "Buy me a coffee" currently only says it is not set up yet. Tapping a system in Settings asks whether to delete it; if you do not want to delete it, tap Cancel.
8. When done, swipe the App away in the app switcher.

## Step 1: design proposals (2026-11-02)

Three proposals with clearly different directions, each with a home page (choosing a system) and an emulator screen while running. Details are in `docs/design/README.md`.

| Proposal | Style | Guest screen | Implementation size | Images |
|---|---|---|---|---|
| A Timeline (redone) | A black-on-white almanac: large condensed years, thin rules, device line drawings, red only for running and experimental; iOS 8 to 10 keep one "Later" row; emulator screen on black with three big square buttons | 360 × 540 pt | Medium to small, about 600 lines | `img/ui-a-home.png`, `img/ui-a-run.png` |
| B Nostalgic skeuomorphic | A tribute to pre-iOS 6: blue-gray navigation bar, vertical pinstripes, grouped tables, glass buttons; the emulator screen is a device body we draw, operated by tapping the buttons on it | 320 × 480 pt (1:1 with the original device) | Largest, over 1000 lines | `img/ui-b-home.png`, `img/ui-b-run.png` |
| C Modern cards | Large titles, horizontally swiping large model cards, a "Now running" mini bar at the bottom; emulator screen all black, screen fills the width | 402 × 603 pt (same as now) | Smallest, about 500 lines | `img/ui-c-home.png`, `img/ui-c-run.png` |

Side-by-side overview of all three: `img/ui-overview.png`.

The user said of the first version of A (midnight blue, amber glow, frosted glass cards, a year scale bar): "Doesn't look good, too AI." The same day it was completely redone as the "Timeline" above: gradients, glow and capsule labels removed, with the sense of time carried by typography instead. The old images were overwritten by the new ones.

On 2026-11-02 the goal was extended to iOS 10 (`CLAUDE.md`): A lists unimported years by year, so a row "2014–16 · iOS 8, 9, 10 [Later]" was added, styled lighter than "Not imported yet" so it does not look already supported; B and C only list imported systems and need no change. For the App name candidates (`拾光`, roughly "gathering time"; Pinstripe; Throwback) and the suggestion that "they can be mixed", see `docs/design/README.md`.

Method: each screen was drawn in HTML at 402 × 874 pt (`docs/design/mockups/`), the device bodies are vector drawings we wrote (`device()` in `common.js`), and local headless Chrome captured them at 3x as 1206 × 2622 PNGs (`docs/design/render.sh`). The guest images inside the screens come from our own run records (`work/ios/runs/`); three were copied to `docs/design/mockups/assets/` and are used only in the documents.

For the user to decide:

1. Which proposal (or how to mix them).
2. The App name stays for now; the candidates are for reference only.

Boundaries of step 2 (stated in the brief, recorded here for reference): only change the appearance-related parts of `LibraryViewController.swift` and `RootViewController.swift`, new UI files, `Assets.xcassets` and `Localizable.xcstrings`; write the new look of the emulator screen as a separate new view file first, and connect it to `EmulatorViewController.swift` with those few lines after the iOS 7 optimization session is done; use our own build directory (`work/ios/DerivedData-ui`) and a separate iOS simulator device; the test entry points must not break.
