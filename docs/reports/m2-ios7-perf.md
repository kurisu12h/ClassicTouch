# M2: iOS 7 lock screen and home screen stutter

- Date: 2026-11-02
- Execution session: m2-gl-eagl (continuing after adding ES 2.0 to EAGL). Scope: find out why lock screen swipes and home screen page flips stutter for iPhone 4 iOS 7.1.2 on the iPhone 18 Pro and fix it, with no regression on iOS 3.1.3 and 6.1.6.
- Not done: no changes to `upstream/`, no commit, no push, no issue or PR filed upstream, no use of the iPhone 14 Pro, nothing downloaded.

## 0. Conclusions

1. **Bottleneck: the whole screen was read back into guest memory a dozen to two dozen times per frame.** When iOS 7's CoreAnimation draws a frame, it switches back and forth between the display surface and an offscreen target, calling `glFlush` on the offscreen target each time. The GL bridge's `glFlush` writes all "rendered but not yet written back" surfaces back to guest memory, so the full-screen display surface (640×960, 2.3 MB), not yet finished, was read back with `glReadPixels` every frame: 2 to 12 times on the lock screen, and 21 to 25 times when pressing and dragging on the home screen. Only the one at the end of the frame is actually useful. On the phone one readback takes 6.5 to 14 milliseconds, almost all of it CPU time, and the vCPU thread spent nine tenths of its time on it.
2. **What changed:** on `glFlush`, if the bound framebuffer is not the one used for display, write back only that framebuffer's own surface, plus surfaces that have been "dirty" for more than 50 milliseconds; at the end of the frame (back to the default framebuffer, `glFinish`, or a flush on the display framebuffer) everything is still written. Writebacks per frame drop from a dozen or twenty to 1. Patch: `patches/ios-gles-perf.patch`, which also contains the statistics used to find the cause (only enabled with `IT_PERF=1`).
3. **Device comparison (the same automated swipe test, one run per item):**

   | Screen | Before, frames/s | After, frames/s | CPU (share of one core) before → after |
   |---|---|---|---|
   | Dragging back and forth on the lock screen | 25.8 | **59.7** | 96% → 99% |
   | Lock screen still (the "slide to unlock" shimmer) | 58.6 | 60.0 | 100% → 96% |
   | Home screen page flip (whole segment, including the still time between flips) | 4.5 (lower than the 10 frames when still) | 22.7; the flip animation itself **36** (4 times: 33, 40, 37, 35; not measured separately before) | 67% → 49% |
   | Home screen press and drag back and forth | 5.4 | **49.0** | 91% → 74% |
   | Home screen still | 9.8 to 10 | 10 | 41% to 54% → 41% to 42% |

4. **Idle CPU did not come down (41%); the goal was not met.** When still, the iOS 7 home screen changes frames 30 times per second, 10 of which actually change (the second hand of the clock icon). The one readback per frame takes 13 milliseconds, about 13% of a core in total; the guest itself is about 20%; display compositing, frame delivery and the App UI about 7%. The remaining readback is slow inside Apple's GL implementation, and three different readback methods were all the same (section 5); going lower requires changing the display path (section 7).
5. **No regression on iOS 3.1.3 and 6.1.6:** lock screen at 10 seconds and 14 seconds, home screen still at 19% and 15%, the same as before; there is also only 1 writeback per frame. The page flip animation runs at 42 and 40 frames, and press and drag at 40 and 54 frames, on the two devices.
6. There was one black screen during testing: the gray "slide to unlock" text with its moving highlight on the lock screen kept the App's text recognition from recognizing it for 13 seconds, the test kept waiting, and the lock screen dimmed and turned off by itself. Fixed (recognition loosened, and if the lock screen has not been recognized when it dims, Home is pressed to wake it); all runs afterwards were normal (section 8).

## 1. Method: a repeatable swipe test, no hands

### 1.1 The "swipe test" in the App

autodrive gained `swipetest` (`EmulatorViewController.swipeLock`, `swipeHome`). Touches are injected with `qemu_ios_ui_input_sequence` on guest virtual time, one point every 16 milliseconds (like a finger on a 60 Hz screen):

| Segment | What it does |
|---|---|
| After the lock screen is recognized | Press Home once first (to keep it on), start 1.5 seconds later |
| `lock_drag` | 3 times: press at the bottom of the lock screen, drag right to 0.55, drag back and release, 1.6 seconds each (no unlock; on iOS 7 the whole lock screen follows the finger, on 3.x and 6.x it is a slider) |
| `lock_static` | Still for 4 seconds (iOS 7's shimmer is a continuous animation); on 3.x and 6.x only 2.5 seconds, so the screen does not turn off (the iPod touch 2nd gen goes into deep sleep if off too long) |
| Unlock | Slide across in 0.7 seconds |
| `home_static` | Still for 6 seconds, starting 3 seconds after the home screen is recognized |
| `home_swipe` | 6 page flips, alternating left and right, 0.25 seconds each, 1.5 seconds apart; also records the frame count from each press to 0.6 seconds later (the flip animation itself) |
| `home_drag` | Press and drag back and forth between 0.3 and 0.7 for 4 seconds (M0's drag test method) |
| `home_static2` | Still for 10 seconds starting 1 second after release, then the usual 40 seconds of idle before quitting |

The start and end of each segment are logged in `events.log` as `seg <name> begin|end serial= cpu=`. The frame count is the number of images QEMU sends to the App that differ from the previous frame; no screenshots are saved within segments (saving PNGs also counts as this process's CPU). Usage: `STIK=1 SWIPETEST=1 PERF=1 scripts/ios/device-boot.sh <device> jit` (real device), `scripts/ios/sim-swipe.sh <device>` (simulator), summary with `scripts/ios/summarize-swipe.py <run directory> [--markdown]`.

### 1.2 Statistics

- **The App records CPU per thread** (`threads.csv`): QEMU's threads have their own names. `CPU 0/TCG` is the emulated CPU (GL forwarding also runs on it), `qemu` is QEMU's main loop (timers, display refresh, frame delivery), and `app-main` is the App's main thread.
- **QEMU logs one line per second** (`IT_PERF=1`, in the patch):
  - `[perf] gl`: GL call count, host time and the CPU time within it, the 5 most expensive slots, surface uploads, writebacks and the `glReadPixels` within them, rereads from cache misses;
  - `[perf] disp`: A4 display VBL, frame swaps, compositing time;
  - `[perf] ui`: frames sent to the App and copy time.
  The GL bridge's existing `IT_GLES_PROF` only counts present, and CoreAnimation on iOS 6 and 7 does not use present, so it shows nothing.
- **Per-event tracing** (`IT_PERF_TRACE=start,end` or `IT_PERF_TRACE_EVERY=seconds`): one line for each writeback, flush, framebuffer switch and display frame swap.

OpenGLES in the simulator is software rendering on the CPU, so GL timings are completely different from the phone. The simulator is therefore used only to verify function and to look at call and writeback counts (which are the same on both); all numbers come from the real device.

## 2. Where the time goes

### 2.1 Device baseline before the change (`20261102-010620`)

| Segment | Frames/s | CPU% | vCPU thread | GL calls/s | GL host ms/s | Writebacks/s | Of which `glReadPixels` ms/s |
|---|---|---|---|---|---|---|---|
| lock_drag | 25.8 | 96 | 93 | 5250 | 931 | 153 | 908 |
| lock_static | 58.6 | 100 | 94 | 7224 | 772 | 122 | 750 |
| home_static | 9.8 | 54 | 51 | 980 | 149 | 12.7 | 142 |
| home_swipe | 4.5 | 67 | 61 | 1986 | 586 | 85 | 571 |
| home_drag | 5.4 | 91 | 88 | 3224 | 910 | 139 | 889 |
| home_static2 | 10.0 | 41 | 34 | 820 | 148 | 10 | 139 |

While dragging, the vCPU thread spends about 900 milliseconds per second in the GL bridge, almost all of it in `glReadPixels`. The guest's CPU, display compositing (2 to 25 milliseconds per second) and the App UI (2% to 3%) are not bottlenecks.

### 2.2 Why one frame is read back so many times (simulator trace)

One frame while pressing and dragging on the home screen (`IT_PERF_TRACE_EVERY=5`; fb 2 is the framebuffer holding the display surface, fb 3 is the offscreen target):

```
swap 15177 ... ui0=0025a000(5f958000)       ← previous frame goes on screen
bindfb 0 -> 2                               ← start drawing the display surface
bindfb 2 -> 3                               ← go to the offscreen target to draw a layer
flush fb=3
wb tex=3 640x960                            ← write back the half-drawn display surface, full screen
bindfb 3 -> 2 / bindfb 2 -> 3 / flush fb=3 / wb tex=3 640x960
... (back and forth like this 24 times)
bindfb 2 -> 0
wb tex=3 640x960                            ← end of frame: only this one is useful
finish
swap ...                                     ← display frame swap about 12 ms later, scanning exactly this memory
```

The lock screen follows the same pattern (back and forth between the display surface and fb 5, fb 6, 10 to 12 times per frame). fb 3 itself is not a guest surface (it needs no writeback); what gets written back is always the display surface that is not finished yet: when leaving it, `gles_sync_surface` marks it "dirty", and the `glFlush` on the offscreen target then writes back all dirty surfaces. Three display surfaces are used in rotation, and their physical addresses are exactly the three blocks scanned at display frame swaps.

## 3. What changed (`patches/ios-gles-perf.patch`)

- `gles_surface_flush_partial`: on `glFlush`, if the bound framebuffer is not the one used for display, write back only the surface backing its own color attachment, plus surfaces that have already been dirty for `GLES_FLUSH_STALE_NS` (50 milliseconds). When the display framebuffer is bound, on `glFinish`, and on returning to the default framebuffer, everything is still written.
- Surfaces that other contexts, other processes or the guest CPU will read are still written back:
  - on a flush on their own framebuffer;
  - at the end of the frame;
  - when this group binds that memory as a texture (the existing `gles_surface_flush(cpu, base)` in `gles_bind_surface`);
  - or once they have been dirty for 50 milliseconds.
  The last one is a safety net for clients that "finish drawing, switch away, flush elsewhere and expect another process to read it". CoreAnimation on 3.1.3 never flushes (its end of frame is returning to the default framebuffer), so it is not affected.
- Statistics and tracing: see section 1.2; when the environment variables are not set, each call has only one extra check.
- The patch is applied after `ios-eagl-es2.patch` (file name order gives this order). `scripts/ios/export-patch.sh` exports the patch from the work tree: take upstream unchanged, apply the earlier patches first, then diff. Applying the four patches in order to a clean upstream copy gives a result identical to the work tree, character for character.
- `build-qemu.sh` now decides "is the patch applied" by looking at the whole set: it used to reverse-check each one individually, which misjudged when two patches change the same file. `SKIP_PATCHES=1` is for when the work tree still has changes that have not been exported.

Verified in the simulator: exactly 1 writeback per frame (60 frames per second means 60 per second); screenshots of the lock screen, mid-unlock and the home screen are all normal.

## 4. Device results after the change

### 4.1 iPhone 4 iOS 7.1.2 (`20261102-012908`, lock screen 26 seconds, home screen 41 seconds)

| Segment | Frames/s | CPU% | vCPU thread | GL calls/s | GL host ms/s | Writebacks/s | `glReadPixels` ms/s (CPU part) | Frame swaps/s |
|---|---|---|---|---|---|---|---|---|
| lock_drag | 59.7 | 99 | 89 | 15433 | 451 | 60.0 | 400 (384) | 60.0 |
| lock_static | 60.0 | 96 | 85 | 7378 | 504 | 59.8 | 480 (464) | 60.0 |
| home_static | 10.0 | 41 | 34 | 820 | 141 | 10.0 | 133 (127) | 30.0 |
| home_swipe | 22.7 | 49 | 40 | 11230 | 258 | 25.4 | 205 (198) | 34.3 |
| home_drag | 49.0 | 74 | 62 | 26405 | 443 | 46.6 | 339 (329) | 53.4 |
| home_static2 | 10.0 | 42 | 34 | 800 | 147 | 10.0 | 137 (130) | 30.1 |

- The flip animation itself (from press to 0.6 seconds later): 33, 40, 37, 35 frames, average **36**. The 22.7 frames for the whole `home_swipe` segment also averages in the 1.2 seconds of stillness between flips.
- 4 runs were done before and after the same fix (`011150`, `011633`, `012248`, `012908`), and frame counts per segment differ by less than 1 frame: lock screen drag 60.2 to 60.3, home screen press and drag 48.8 to 49.2, flip animation 31 to 37.
- Footprint 1055 to 1140 MB, minimum free memory 2236 MB, code region setup 0.82 seconds, the same as before.
- GL calls went up 2 to 8 times: the guest is no longer held up by readbacks, so it draws more frames.

![iOS 7 home screen after the test (App window screenshot)](img/m2perf-device-n90ap-7.1.2-after-swipetest.png)

### 4.2 Where the 41% goes when still

`home_static2` (10 seconds, untouched):

| Part | Share of one core |
|---|---|
| vCPU thread total | 34% |
| &emsp;Of which GL forwarding (CPU time) | 14%, almost all of it the 10 readbacks per second (13 milliseconds each) |
| &emsp;Of which guest code (estimated) | about 20% |
| QEMU main loop (display compositing 22 ms/s, frame delivery) | 4% |
| App main thread (building the image for each frame and putting it on screen) | 3% |

On the guest side: when still, the iOS 7 home screen changes frames 30 times per second, 10 of which actually change (the second hand of the "Clock" icon). M0 also measured 30 frame swaps per second on the Mac.

## 5. Why the remaining readback is slow (two rounds of diagnosis)

1. **`glFinish` first, then read** (`IT_GLES_WB_FINISH=1`, `20261102-011633`): `glFinish` takes only 0.3 to 0.7 milliseconds each time, and the `glReadPixels` after it still takes 6.4 to 13.5 milliseconds.
2. **Three readback methods in rotation, timed separately** (`IT_GLES_WB_MODE=3`, `20261102-012248`):

   | Segment | `glReadPixels` reading BGRA | Reading RGBA, then swapping bytes on the CPU | GPU copy into an IOSurface-backed texture, then lock and `memcpy` |
   |---|---|---|---|
   | lock_drag | 6.46 ms | 6.61 ms | 6.45 ms |
   | home_drag | 7.39 ms | 7.63 ms | 7.45 ms |
   | home_static | 13.46 ms | 13.53 ms | 13.68 ms |

   All three are equally slow. In the simulator the IOSurface method takes only 0.5 milliseconds each time, and the image is correct.
3. **In the final version**, 96% of the readback wall-clock time is CPU time (for example, 130 of the 137 milliseconds per second when still).

Conclusion: the slowness is in the step where Apple's GL (with Metal underneath) hands the rendering result to the CPU, not in the readback interface we chose, and it is real CPU work, not waiting for the GPU. Each readback is actually slower when still (13 milliseconds versus 7 when dragging), which looks like the GPU and CPU clocking down when idle. So "asynchronous readback" (returning to the guest before the result is ready) can reduce stutter but cannot save CPU. The readback method switching and IOSurface code used for the experiment were not kept in the patch.

## 6. iOS 3.1.3 and 6.1.6 regression check (one run each)

| Device | Lock screen | Home screen still CPU | Flip animation | Press and drag | Lock screen slider drag | Writebacks |
|---|---|---|---|---|---|---|
| iPhone 3GS 6.1.6 (`013103`) | **14 s** (before: 14 to 15) | **15%** (before: 12% to 16%) | 40 frames (6 times: 33 to 50) | 53.7 frames | 33.6 frames | About 1 per frame, 2 to 3 ms each |
| iPod touch 2nd gen 3.1.3 (`013239`) | **10 s** (before: 10) | **19%** (before: 19%) | 42 frames (4 times: 30 to 51) | 39.8 frames | 43.5 frames | About 1 per frame, 2 to 3 ms each |

- The screen area of both devices is a quarter of iOS 7's (320×480), so readback is much cheaper.
- M0 measured home screen drags on the Mac (CGL) at 52.5 frames for iOS 6 and 34.6 frames for iOS 3; these are comparable or better. There is no swipe data for these two devices from before the change (the swipe test is new this time), so "no regression" is judged by lock screen time, idle CPU and screenshots.
- The home screen times are later than before (27 seconds and 24 seconds, versus 22 and 18 before) because the swipe test first spends about 10 seconds dragging and staying still on the lock screen before unlocking, not because anything got slower.
- The iPod's 6 page flips alternate left and right, but 3.1.3 has only one page of icons plus Spotlight to the left, so it ended on Spotlight, with the keyboard up and the cursor blinking. So the iPod's `home_static2` (35%, 22 frames) does not count as idle, and `home_static` is used instead (screenshot `img/m2perf-device-n72ap-3.1.3-ends-on-spotlight.png`).
- Home screen screenshot after the iOS 6 test: `img/m2perf-device-n88ap-6.1.6-after-swipetest.png`.
- During the iOS 6 run, the Mac's 1-minute load spiked to 18 (another session was compiling). Device measurements depend only on the phone itself; the Mac fetches logs every 3 seconds, which does not affect the numbers.

## 7. Remaining bottlenecks and possible routes (for the decision session to decide)

1. **IOSurface-backed render targets (estimated half a day to a day, one round of diagnosis first).** Have CoreAnimation's display surface render into an IOSurface-backed texture from the start, so writeback is only a lock plus `memcpy`, and upload too. The IOSurface experiment in section 5 may not have saved anything because the "GPU copy" step also goes through the CPU in Apple's implementation, or because the IOSurface lock itself is expensive; first time copy, lock and `memcpy` separately in one device run, then decide whether to do it. If it works, idle CPU could drop by about another 13 points, and the lock screen shimmer segment could be halved.
2. **Display passthrough (estimated several days).** The surface the display scans out is no longer written back to guest memory, and the App displays the texture or IOSurface on the host directly, eliminating this readback entirely. It requires changing the A4 display model, the frame delivery interface and the App's display layer, and also handling the guest reading that memory itself (screenshots, snapshots). This counts as "rewriting the display path", so per the agreement it stops here.
3. **Power saving on the guest side.** iOS 7 still changes frames 30 times per second when still. M0 suggested trying "Reduce Motion", or having the App lower the guest's display refresh when it detects the image has not changed for a long time. This is a product tradeoff and unrelated to this GL work.
4. Asynchronous readback could make dragging steadier (the vCPU would not have to wait those 7 milliseconds), but the readback itself is CPU work and cannot save power.

## 8. Problems during testing

| Problem | Handling |
|---|---|
| Black screen on the phone in the first baseline run: the lock screen had in fact appeared, but the App's text recognition did not recognize it once in 13 seconds (gray text with a moving highlight, read as "Slide to unlog." or "slide to umoax"), the test kept waiting, and the lock screen dimmed and turned off | Stopped that run and ended the App. Loosened recognition (ignore spaces; recognizing "slide to un", or "slide" and "unlock" split into two segments, both count); if the lock screen has not been recognized yet when the backlight drops below half, press Home to wake it; while waiting, log the recognized text to `events.log` every 5 seconds. All 6 runs afterwards were normal |
| In one simulator run, text recognition was 6 seconds late, the lock screen had already dimmed, and the lock screen drag segment got 0 frames | Changed the lock screen segment to press Home to wake first, and to drag first and then stay still |
| Stats lines are only logged in seconds with GL calls; the iOS 6 home screen has no GL calls when still, so the summary script, averaging over seconds with data, was skewed | Changed to average over the segment length, counting missing seconds as 0 |
| The iPod's last segment ended on Spotlight | See section 6; does not affect the idle figure (the first segment is used) |
| The phone auto-locked once midway | Asked the user to unlock it, then continued |

Also, another session was changing the App's UI files at the same time (`EmulatorChromeView.swift`, `Theme.swift` and so on). In the App I only changed `EmulatorViewController.swift`, `Engine.swift`, `GuestText.swift`, `LaunchOptions.swift` and `Stats.swift` this time, all with context-checked replacements, without overwriting the other session's files.

## 9. Files

- In the repository (not committed):
  - `patches/ios-gles-perf.patch` (new, 579 lines)
  - `scripts/ios/build-qemu.sh` (whole-set patch check, `SKIP_PATCHES`), `device-boot.sh` (`SWIPETEST`, `PERF`, `QEMUENV`, fetching `threads.csv`)
  - New: `scripts/ios/sim-swipe.sh`, `summarize-swipe.py`, `export-patch.sh`
  - `app/ClassicTouch/`:
    - `EmulatorViewController.swift`: swipe test, `-perf`, `-qemuenv`, `threads.csv`, `clock up0`, lock screen recognition fallback;
    - `Engine.swift`: polyline drag `drag(path:)`;
    - `GuestText.swift`: looser lock screen recognition;
    - `LaunchOptions.swift`: `environment(forKey:)`;
    - `Stats.swift`: `ThreadLog`.
  - This report and `docs/reports/img/m2perf-*.png` (3 images, all checked, no personal information)
- In `work/` (not committed):
  - Device runs: `work/ios/runs/device/20261102-010125` (the black screen run, discarded), `010620` (baseline before the change), `011150` (first run after the fix), `011633` (`glFinish` diagnosis), `012248` (three readback methods), `012908` (final iOS 7), `013103` (iOS 6), `013239` (iOS 3), each with a `.summary`;
  - Simulator runs: `work/ios/runs/sim/20261102-0051*` to `0125*`;
  - `work/logs/m2perf-*.log`.
- All four dylibs were rebuilt with all the patches (device and simulator, each with JIT and interpreter); the App on the phone is the final version and is not running.

To reproduce:

```bash
# Real device (phone unlocked, cable plugged in, LocalDevVPN on, no mirroring)
STIK=1 SWIPETEST=1 PERF=1 IDLE=40 TBSIZE=256 scripts/ios/device-boot.sh n90ap-11D257 jit 400
python3 scripts/ios/summarize-swipe.py work/ios/runs/device/<run directory> --markdown
# Simulator (with tracing)
QEMUENV="IT_PERF_TRACE_EVERY=5" scripts/ios/sim-swipe.sh n90ap-11D257
# Export the patch after changing the work tree
scripts/ios/export-patch.sh patches/ios-gles-perf.patch --base patches/ios-eagl-es2.patch \
  hw/arm/gles-host.c hw/arm/s5l8930_display.c contrib/ios-app/qemu-ios-ui.c
```
