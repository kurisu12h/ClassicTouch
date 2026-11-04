# M0: JIT vs pure interpreter (TCI) benchmarks on the Mac

- Date: 2026-11-01
- Execution session: M0 (took over from the previous background agent, which had been interrupted). Scope: TCI on 3GS 6.1.6; first-time setup plus JIT and TCI benchmarks for iPhone 4 7.1.2 and iPod touch 2nd gen 3.1.3; system load during each run; how snapshots relate to host GL; extrapolation to the two test phones; this report.
- Not done: nothing was downloaded; M1's directories were not touched (only read `docs/reports/m1-stage1.md` to get real-device numbers for calibration); the two upstream repositories were not changed (`git status` is clean, so `patches/` has no M0 patches); no commit, nothing sent anywhere outside.
- Test machine: M4 Max (10 performance cores + 4 efficiency cores, 36 GB), macOS 27.0.1, Xcode 27.2. qemu-ios b225694505 (QEMU 11), LightTouchMac b06012fa4c.

## 0. Conclusions

1. **How far apart JIT and TCI are: 7 to 11 times on pure compute work, 2.5 to 5 times in average CPU during everyday interaction, and the newer the system, the bigger the gap.** Boot to lock screen is the cleanest comparison (it saturates one core the whole time): in CPU seconds of the guest main core thread, iPhone OS 3.1.3 differs by 6.9 times, iOS 6.1.6 by 7.0 times, iOS 7.1.2 by 11.2 times (wall clock 5.1, 6.1, 10.1 times: 9 seconds vs 46 seconds, 26 seconds vs 156 seconds, 40 seconds vs 407 seconds). During interaction the guest spends most of its time waiting, so average CPU share differs only 2.5 to 5 times; but iOS 7 under TCI saturates even an M4 Max, so its interaction ratio is clipped by the "at most one core" ceiling, and the real gap is close to the 11 times seen at boot.
2. **Roughly what the experience on iPhone is without JIT** (iPhone 18 Pro calibrated against M1's real-device boot data, about 1.2 M4 Max cores; the brief's rough estimate of 0.7 is more conservative; iPhone 14 Pro is roughly 0.48, more than twice as slow again. See section 4):
   - **iPhone OS 3 (iPod touch 2nd gen 3.1.3): usable.** Boot takes 40 seconds to 1 minute (M1 measured 43 seconds on the real device), home screen idle uses about a third to half a core, paging and opening apps about half a core to 0.8 cores, and home screen drag frame rate on the Mac is not CPU-bound (JIT 35 fps, TCI 44 fps). On the 14 Pro, paging and opening apps briefly saturate a core.
   - **iOS 6 (3GS 6.1.6): barely usable; stutter and battery drain are the problems.** Boot takes 2 to 4 minutes (M1 measured 115 seconds), idle uses about half a core to 0.7 cores (fluctuating between 42% and 60% on the Mac; 91% on M1's real device, measured differently), paging half a core to one core, opening apps 0.7 to 1.2 cores; home screen drag drops from 52 fps with JIT to the low 20s. On the 14 Pro, idle alone saturates a core, and drag is about 15 fps.
   - **iOS 7 (iPhone 4 7.1.2): not usable.** On the M4 Max, TCI already saturates one core: the home screen doing nothing takes 94% (the iOS 7 home screen redraws 30 times per second), Settings and Clock take 4 to 11 seconds to reach the foreground (JIT 1.3 to 1.9 seconds), home screen drag is 7 fps, Home press to screen on takes 5.6 seconds, and boot takes 6 min 47 s. Estimated from the boot ratio, everyday interaction on the 18 Pro would need about 2 to 3 cores (4 to 6 by the rough estimate), so the guest can only run at one half to one fifth of real speed, and boot takes 6 to 14 minutes.
3. **With JIT, all three eras have plenty of headroom on both phones.** By the rough estimate, on the 14 Pro the iOS 7 home screen idles at about half a core, paging about 0.7 cores, opening apps about 0.6 cores, and boot about 1.5 minutes; on the 18 Pro everything is within about half a core. This assumes the JIT code buffer is large enough: on the phone, M1 cut the buffer to 32 MB to shorten the debugger "prepare" time, and the boot speedup became noticeably smaller. (Correction from the decision session: M1's 79% idle figure for the 3GS cannot be used as evidence, because someone opened Settings on the phone during the measurement; see the note added to section 4.2 of `m1-stage1.md`. The effect of 32 MB on idle CPU has to wait for M1's stage 2 remeasurement.)
4. **Snapshots: on the Mac, host GL is always on and GL state travels with the snapshot, no problem; on iPhone they currently cannot be saved.** The Mac's CGL backend reads back the live GL state and stores it as a "gles-host" section in the snapshot (about 4 MB for iOS 3 and 6, about 18 MB for iOS 7, 1.5% to 4% of the snapshot). Snapshot size is about equal to guest memory: iPod 115 MB, 3GS 259 MB, iPhone 4 445 MB; saving takes 0.67, 1.8, 3.3 seconds; restoring takes 0.1 to 0.2 seconds for all of them, and after restoring, tapping an icon opens the app normally. But the EAGL backend used on the phone (and the experimental ANGLE on the Mac) installs a migration blocker as soon as there is one live GL context, and once SpringBoard is up there always is one, so **snapshots cannot currently be saved on the phone**. M2's "instant switching via snapshots" first needs CGL's readback and rebuild ported to EAGL; until then the phone has to cold boot every time, and without JIT, cold boots of iOS 6 and 7 take minutes.
5. **The iPod touch 2nd gen SecureROM problem is half solved.** A 4-byte placeholder file is enough to cold boot; but in testing, waking from deep sleep resets into the ROM and hangs at address 0. The 3GS machine code does a high-level emulation of the same wake (`s5l8920_resume`); adding a similar piece for the iPod 2nd gen would remove the need for Apple's SecureROM entirely. `docs/plan.md` records that the user has decided not to do long standby tests for now and to deal with this once the iPod 2nd gen is officially supported; the two-minute sleep test here was done in passing before seeing that decision, and it happens to answer the first step of that route, "does it hang": it does, and the next step is this patch.
6. **All interference during testing is recorded.** M1 compiling at the same time plus Spotlight indexing pushed the load to 20 to 63 several times; affected runs are marked ⚠ in the tables and excluded from the means, and extra runs were done: a third 3GS TCI run and all four iPhone 4 runs. Also, iOS 7 pops up "Cannot Use Device / QEMU USB Keyboard", which blocks all touches, so the first three iPhone 4 runs were discarded and redone (details in section 7).

## 1. What was measured and how

Each run cold boots from an APFS clone of the same "golden state" (first-time setup completed, powered off), with `-display none`, `-audio driver=none`, networking per upstream `restrict=on,lan=off`, and host GL on (CGL, display by readback), matching Light Touch's parameters. Measurements:

- **Boot to lock screen**: from starting QEMU until the guest agent reports that the foreground is SpringBoard's lock screen; process CPU seconds and per-thread CPU seconds are recorded at the same time (`CPU 0/TCG` is the guest main core, `qemu_main` is the main thread, which includes the GL bridge and display).
- **Settle**: wait until some 10-second window has process CPU below 60% (limit 180 seconds for JIT, 300 seconds for TCI).
- **Home screen idle** for 40 seconds, **paging** (5 round trips), **opening Settings and Clock** (launched by the guest agent, 10 seconds each, plus the seconds until it reaches the foreground): process CPU seconds / wall clock seconds, recorded as "% of one core".
- **Snapshot**: after returning to the home screen, `stop` plus `migrate file:`; record size, time taken and the size of the GL section in it; restore twice with `-incoming file:` on a clone of the matching state, record load time, use OCR to find the Settings icon and tap it to verify touch, then idle for 30 seconds.
- **Visible frame rate** (a probe added in this session): restore from a snapshot, then hold and drag back and forth on the home screen for 20 seconds, or watch the "slide to unlock" shimmer animation on the lock screen, while taking screenshots at 120 Hz and comparing them, counting how many times a new frame appears on screen.
- **Load**: `uptime` before and after each run, load average at the start of each window, plus `work/runs/load*.log` with one entry every 15 seconds.

Each device has two valid runs each for JIT and TCI (three TCI runs for the 3GS, with the interaction part of one discarded because of load). Benchmark runs ran one after another, never two at once. The frame rate probes and `swaps` readings ran during other runs' unmeasured "settle" phase (a single core; this machine has 10 performance cores). There are two exceptions: the measurement window of the first 3GS TCI run overlapped with the iPhone 4 first-time setup (one extra JIT emulator, load 3.9), so a third run was added as a control; the iPod sleep test overlapped with the second iPhone 4 JIT run, which was discarded anyway because of the USB keyboard alert.

## 2. Data

Device codes: n72 = iPod touch 2nd gen · iPhone OS 3.1.3 (7E18); n88 = iPhone 3GS · iOS 6.1.6 (10B500); n90 = iPhone 4 · iOS 7.1.2 (11D257). "% of one core" is the CPU seconds of all QEMU process threads / wall clock seconds × 100, and can exceed 100% (guest main core, secondary core and main thread busy at the same time).

### 2.1 The three eras side by side (means and TCI/JIT ratios)

| Item | n72 JIT | n72 TCI | Ratio | n88 JIT | n88 TCI | Ratio | n90 JIT | n90 TCI | Ratio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Boot to lock screen (s) | 9.0 | 45.7 | 5.1× | 25.7 | 156.0 | 6.1× | 40.2 | 407.3 | 10.1× |
| Guest main core thread CPU seconds during boot | 6.4 | 44.2 | 6.9× | 21.8 | 153.1 | 7.0× | 35.5 | 397.6 | 11.2× |
| Home screen idle (% of one core) | 11.7 | 32.7 | 2.8× | 9.9 | 50.5 | 5.1× | 25.0 | 94.1 | 3.8× |
| Home screen paging (% of one core) | 23.1 | 57.3 | 2.5× | 19.2 | 66.8 | 3.5× | 35.0 | 96.5 | 2.8× |
| 10 seconds of opening Settings (% of one core) | 18.6 | 54.8 | 2.9× | 18.2 | 86.6 | 4.7× | 28.9 | 102.6 | 3.5× |
| Tap Settings to foreground (s) | 0.61 | 1.93 | 3.1× | 0.77 | 1.69 | 2.2× | 1.85 | 7.54 | 4.1× |
| Tap Clock to foreground (s) | 0.54 | 1.84 | 3.4× | 0.70 | 1.85 | 2.6× | 1.31 | 5.83 | 4.4× |
| Home screen drag visible frame rate | 34.6 | 44.3 | 0.8× | 52.5 | 26.3 | 2.0× | 15.1 | 7.2 | 2.1× |
| &emsp;Guest main core % during drag | 20.6 | 74.0 | 3.6× | 29.7 | 85.9 | 2.9× | 48.8 | 73.8 | 1.5× |
| Lock screen shimmer visible frame rate | 15.0 | – | – | 10.7 | 9.7 | 1.1× | 57.2 | 44.5 | 1.3× |
| &emsp;Guest main core % during lock screen animation | 9.9 | – | – | 12.2 | 72.3 | 5.9× | 36.2 | 62.9 | 1.7× |
| Snapshot size (MB) | 115.4 | 114.3 | – | 259.1 | 259.4 | – | 445.1 | 445.6 | – |
| Of which GL state (MB) | 4.4 | 4.4 | – | 3.8 | 4.4 | – | 17.6 | 17.5 | – |
| Save snapshot (s) | 0.67 | 0.67 | – | 1.81 | 1.81 | – | 3.27 | 3.27 | – |
| Restore snapshot (s) | 0.10 | 0.09 | – | 0.14 | 0.13 | – | 0.16 | 0.17 | – |
| Tap Settings to foreground after restore (s) | 0.31 | 1.62 | 5.2× | 0.57 | 2.80 | 4.9× | 0.85 | 5.73 | 6.8× |

Means use only runs whose 1-minute load at the start of the measurement window was at most 8 (for boot, the load at the start of each run; for interaction items, the load at the start of the idle window). Ratios are TCI ÷ JIT; for the frame rate rows it is JIT ÷ TCI. "Tap app to foreground" relies on repeatedly asking the guest agent, and under TCI the agent itself is slow, so the granularity is about 1 to 3 seconds; treat it only as an order of magnitude.

### 2.2 Raw data per run and the load at the time

| Run | Boot to lock screen s | Boot CPU s | Home screen idle % core | Paging % core | Open Settings s | Open Settings % core | Open Clock s | Open Clock % core | Snapshot MB | Save s | Restore s | Idle after restore % core | Drag visible frame rate | Load at start | Load at idle window | Load at end |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| n72-jit-1 | 9.0 | 6.8 | 12.4 | 25.3 | 0.62 | 20.5 | 0.46 | 20.2 | 115 | 0.67 | 0.09 | 11.5 | 34.6 | 6.2 | 5.0 | 63.6 |
| n72-jit-2 ⚠ | 8.7 | 7.0 | 10.9 | 20.9 | 0.61 | 16.7 | 0.61 | 18.5 | 116 | 0.67 | 0.10 | 10.6 | – | 8.2 | 6.7 | 3.3 |
| n72-tci-1 | 46.1 | 45.6 | 32.8 | 55.9 | 0.93 | 54.7 | 0.92 | 51.5 | 114 | 0.67 | 0.09 | 25.4 | 44.3 | 3.8 | 4.1 | 2.7 |
| n72-tci-2 | 45.3 | 44.7 | 32.6 | 58.8 | 2.92 | 54.9 | 2.77 | 54.7 | 114 | 0.67 | 0.09 | 30.2 | – | 2.7 | 2.8 | 1.9 |
| n88-jit-1 | 26.9 | 27.1 | 10.7 | 19.7 | 0.77 | 18.6 | 0.78 | 20.0 | 259 | 1.82 | 0.15 | 10.0 | 52.5 | 2.8 | 2.8 | – |
| n88-jit-2 | 24.6 | 24.7 | 9.2 | 18.8 | 0.77 | 17.9 | 0.62 | 19.9 | 259 | 1.81 | 0.12 | 9.0 | – | 1.9 | 2.1 | – |
| n88-tci-1 | 151.0 | 159.1 | 41.5 | 67.1 | 1.69 | 87.4 | 1.85 | 82.8 | 260 | 1.80 | 0.13 | 55.6 | 26.3 | 3.4 | 3.9 | 3.8 |
| n88-tci-2 ⚠ | 150.5 | 158.1 | 57.7 | 70.1 | 2.00 | 83.5 | 1.54 | 85.6 | 260 | 1.79 | 0.12 | 49.4 | – | 3.5 | 20.8 | 9.5 |
| n88-tci-3 | 166.5 | 173.7 | 59.6 | 66.6 | 1.68 | 85.7 | 1.85 | 84.7 | 259 | 1.82 | 0.14 | 56.5 | – | 3.9 | 4.1 | 4.5 |
| n90-jit-3 | 43.2 | 47.8 | 25.1 | 34.7 | 1.85 | 30.5 | 1.24 | 31.0 | 446 | 3.26 | 0.17 | 25.1 | 15.1 | 2.4 | 3.4 | 2.7 |
| n90-jit-4 | 37.2 | 41.5 | 24.9 | 35.3 | 1.84 | 27.4 | 1.38 | 33.0 | 445 | 3.28 | 0.16 | 22.1 | – | 2.7 | 4.2 | 15.1 |
| n90-tci-3 ⚠ | 403.2 | 415.6 | 92.4 | 101.7 | 10.61 | 103.4 | 3.68 | 101.5 | 444 | 3.25 | 0.17 | 90.6 | 7.2 | 15.1 | 3.1 | 3.3 |
| n90-tci-4 | 407.3 | 440.1 | 95.7 | 91.3 | 4.46 | 101.8 | 7.97 | 102.2 | 448 | 3.29 | 0.17 | 91.2 | – | 3.3 | 3.0 | 3.9 |

⚠: the 1-minute load at the start of this run or of its idle window exceeded 8 (M1 compiling or Spotlight); the corresponding part is excluded from the means. n72-jit-2 and n90-tci-3 only hit a load spike at the moment of boot (8.2 and 15.1, dropping right after), and their boot times match the other runs. The three 3GS TCI idle runs are 41.5%, 57.7% (load 20.8) and 59.6% (load 4.1); the third run shows the second run's high value was not caused by load, and 3GS TCI idle itself fluctuates between 42% and 60%. The third run also booted 10% slower than the first two (166 seconds vs 151 seconds); by then this machine had been fully loaded for more than an hour straight, so there may have been throttling.

### 2.3 How to read the frame rates

Screenshot comparison measures "new frames actually appearing on screen", capped at the 120 Hz sampling rate, regardless of which rendering path is used. The three systems behave differently and have to be read separately:

- **iOS 6 (3GS) home screen drag is CPU-bound**: JIT 52.5 fps (guest main core 30%), TCI 26.3 fps (guest main core 86%, nearly saturated), a difference of half. This is the only reliable set for extrapolating phone frame rates.
- **iPhone OS 3 (iPod) home screen drag is not CPU-bound**: JIT 34.6 fps, TCI 44.3 fps; the guest main core at 21% and 74% is not saturated in either case, and the difference between them is noise, which shows that on the Mac TCI does not slow down 3.x dragging. The lock screen shimmer on 3.x is itself only about 15 fps.
- **iOS 7 (iPhone 4)**: home screen drag is only 15 fps even with JIT, with the guest main core at just 49%, so the bottleneck is not the CPU (possibly touch reporting or the 640×960 display path, left for M2 to investigate); TCI drops to 7 fps. The "slide to unlock" shimmer on the lock screen is a continuous 60 fps animation: JIT 57 fps, TCI 44.5 fps (guest main core 63%, plus main thread 38%). Also, the display model's `swaps` counter confirms that even when the iOS 7 home screen is doing nothing, the panel swaps frames 30 times per second (14% of one core under JIT). This is why iOS 7 idle costs much more than iOS 6 and saturates a core under TCI; the system's "Reduce Motion" setting might bring it down, worth trying in M2.
- The iOS 6 lock screen shimmer is itself only about 10 fps, the same under JIT and TCI, so it cannot be used for comparison.

### 2.4 Boot numbers from discarded runs

In the first three iPhone 4 runs (USB keyboard alert, see section 7) and the run stopped midway, boot happened before the alert appeared, so their boot numbers are still usable as a reference: JIT 41.2 seconds (load 9.5), 59.2 seconds (load 63, interfered with); TCI 399.2 seconds, 405.5 seconds. Together with the valid runs, the four iPhone 4 TCI boots are 399, 405, 403 and 407 seconds, very stable.

## 3. Snapshots and host GL

**GL was on during measurement.** All runs (including snapshot and restore) had host GL on: the log has `[gles] host GL up: 2.1 Metal - 91.7 / Apple M4 Max, present by readback`, and CoreAnimation uses host compositing. On the Mac there is no switch to turn GL off for comparison: FirmwareKit always burns the GL frontend (a shim replacing OpenGLES.framework) into the system when making a device, with no "without GL" option; on the QEMU side there is only the choice `gl-renderer=cgl|angle`.

**On the Mac (CGL), GL has very little effect on snapshots.** When saving a snapshot, `hw/arm/gles-host-snapshot.c.inc` uses GL to read back each context's state (share groups, contexts, buffers, textures with their pixels, renderbuffer sizes, framebuffer attachments, shaders and programs, fixed-function pipeline state) and packs it into a "gles-host" section; on restore it rebuilds the contexts and loads the state back in. Measured, this section is about 4 MB on the iPod and 3GS and about 18 MB on the iPhone 4 (iOS 7 has more textures), 1.5% to 4% of the whole snapshot. Saving time goes almost entirely into writing memory (3GS about 252 MB of memory pages, 1.16 Gbit/s, 1.74 seconds, matching the measured 1.8 seconds). After restore, GL renders normally and tapping an icon opens the app (iPod 0.31 seconds, 3GS 0.57 seconds, iPhone 4 0.85 seconds to foreground, JIT).

**On iPhone they currently cannot be saved.** On an iOS host the same file compiles to the EAGL backend (`TARGET_OS_IPHONE` → `GLES_HOST_EAGL`), and `gles_begin_context` installs the migration blocker "Live OpenGL ES state cannot be saved (including accelerated system UI)" as soon as the first GL context is created, lifting it only when all contexts are destroyed; after SpringBoard is up there is always a context, so `migrate` is refused. The experimental ANGLE renderer is the same ("angle (experimental; no snapshots)"). To do snapshots on the phone, CGL's readback and rebuild have to be moved to EAGL: iOS's OpenGLES.framework still exports the full ES 1.1 fixed-function pipeline, so most of the state readback carries over as is, but ES has no `glGetTexImage`, so texture pixels have to be read instead by attaching the texture to an FBO and calling `glReadPixels`, and ES 2.0 shader programs have to be recompiled. The M1 report has also already put "snapshot (save when there is no GL)" and "`glGetTexImage` probe" into the next stage.

**Snapshot size is proportional to guest memory**: iPod 128 MB of memory → 115 MB, 3GS 256 MB → 259 MB, iPhone 4 512 MB → 445 MB. iOS uses memory very fully (the 3GS has only about 4000 all-zero pages), so there is little room for compression. Saving runs at about 145 MB/s, limited by QEMU's migration code rather than the disk (this machine's SSD is much faster), and on the phone it should be the same order of magnitude: the iPhone 4's 445 MB takes over 3 seconds, which has to be accounted for when saving a snapshot as the app goes to the background. Restoring takes only 0.1 to 0.2 seconds, but at that point the snapshot file has just been written and is still in the system cache; a cold read on the phone, estimated at 1 to 2 GB/s for flash, takes about 0.1 to 0.5 seconds, which still counts as "instant switching".

## 4. Extrapolation to iPhone

**Conversion factor.** Upstream feasibility study (qemu-ios's since-deleted `docs/research/ipod-touch-2g-on-iphone.md`, 2026-08-03): A19 Pro single-thread performance is about 0.90 M4 Max cores; multiplied by 0.75 for throttling under sustained load, that is about 0.68 "M4 Max core equivalents". Per the brief: iPhone 18 Pro (A20 Pro) at 0.7, and iPhone 14 Pro (A16) roughly 0.7 times the A19 Pro, about 0.48. Both are rough estimates.

**M1's real-device numbers show 0.7 is on the conservative side.** M1 booted the interpreter build on the iPhone 18 Pro (section 4.2 of `docs/reports/m1-stage1.md`): iPod 43 seconds, 3GS 115 seconds to the lock screen; TCI on this machine is 45.7 seconds and 150.7 seconds. In other words, under short interpreter loads the A20 Pro is about 1.06 to 1.31 M4 Max cores, so the tables give one more column, "calibrated against M1's real-device boot, 1.2". Two caveats: first, boot lasts only a minute or two, which cannot reveal throttling during long play sessions, so sustained use should fall between 0.7 and 1.2; second, M1's iOS build had host GL disabled (`-Dhost_gles=disabled`) and the app itself grabbed a frame on every screen refresh, so it measures differently from here. M1's measured idle CPU (iPod 50%, 3GS 91%) is higher than extrapolated here, very likely because of these two points, not because the phone is slower.

**How to read**: boot seconds / k; CPU share / k, counted against one phone core, where over 100% means saturated and the guest then runs slower than real speed (for example 179% is about 56% of real speed); drag frame rate = Mac frame rate × min(1, k / guest main core share), meaningful only for the CPU-bound 3GS; for the iPod and iPhone 4 the drag bottleneck is not the CPU, so the computed value is only an upper bound. iPhone 4 TCI is already saturated on the Mac (≥90%), so the guest already runs slower than real speed on the Mac and dividing directly by k would underestimate; it is therefore written as "≥lower bound (about estimate)", where estimate = JIT share × the TCI/JIT ratio of guest main core CPU during boot (11.2) / k. This estimate is on the high side (the main thread's display and GL overhead does not slow down with the interpreter), but the order of magnitude is credible.

#### iPhone 18 Pro (A20 Pro, rough estimate 0.7)

| Model | Mode | Boot to lock screen s | Home screen idle % core | Paging % core | Open app % core | Home screen drag frame rate |
|---|---|---:|---:|---:|---:|---:|
| iPod touch 2nd gen · iPhone OS 3.1.3 | JIT | 13 | 17 | 33 | 27 | 35 |
| iPod touch 2nd gen · iPhone OS 3.1.3 | TCI | 65 | 47 | 82 | 77 | 42 |
| iPhone 3GS · iOS 6.1.6 | JIT | 37 | 14 | 28 | 27 | 52 |
| iPhone 3GS · iOS 6.1.6 | TCI | 223 | 72 | 96 | 122 | 21 |
| iPhone 4 · iOS 7.1.2 | JIT | 57 | 36 | 50 | 44 | 15 |
| iPhone 4 · iOS 7.1.2 | TCI | 582 | ≥134 (about 400) | ≥138 (about 559) | ≥146 (about 487) | 7 |

#### iPhone 14 Pro (A16, rough estimate 0.48)

| Model | Mode | Boot to lock screen s | Home screen idle % core | Paging % core | Open app % core | Home screen drag frame rate |
|---|---|---:|---:|---:|---:|---:|
| iPod touch 2nd gen · iPhone OS 3.1.3 | JIT | 19 | 24 | 49 | 40 | 35 |
| iPod touch 2nd gen · iPhone OS 3.1.3 | TCI | 96 | 69 | 120 | 113 | 28 |
| iPhone 3GS · iOS 6.1.6 | JIT | 54 | 21 | 40 | 40 | 52 |
| iPhone 3GS · iOS 6.1.6 | TCI | 328 | 106 | 140 | 179 | 15 |
| iPhone 4 · iOS 7.1.2 | JIT | 84 | 53 | 74 | 64 | 15 |
| iPhone 4 · iOS 7.1.2 | TCI | 856 | ≥198 (about 588) | ≥203 (about 823) | ≥215 (about 716) | 5 |

#### iPhone 18 Pro (calibrated against M1's real-device boot, 1.2)

| Model | Mode | Boot to lock screen s | Home screen idle % core | Paging % core | Open app % core | Home screen drag frame rate |
|---|---|---:|---:|---:|---:|---:|
| iPod touch 2nd gen · iPhone OS 3.1.3 | JIT | 8 | 10 | 19 | 16 | 35 |
| iPod touch 2nd gen · iPhone OS 3.1.3 | TCI | 38 | 27 | 48 | 45 | 44 |
| iPhone 3GS · iOS 6.1.6 | JIT | 21 | 8 | 16 | 16 | 52 |
| iPhone 3GS · iOS 6.1.6 | TCI | 130 | 42 | 56 | 71 | 26 |
| iPhone 4 · iOS 7.1.2 | JIT | 34 | 21 | 29 | 25 | 15 |
| iPhone 4 · iOS 7.1.2 | TCI | 339 | ≥78 (about 233) | ≥80 (about 326) | ≥85 (about 284) | 7 |

## 5. Screenshots

Home screens of the three versions after first-time setup (JIT, `screendump` from headless runs on the Mac):

| iPod touch 2nd gen · iPhone OS 3.1.3 | iPhone 3GS · iOS 6.1.6 | iPhone 4 · iOS 7.1.2 |
|---|---|---|
| ![](img/n72ap-7E18-home-after-setup.png) | ![](img/n88ap-10B500-home-after-setup.png) | ![](img/n90ap-11D257-home-after-setup.png) |

The iOS 7 USB keyboard alert (discarded iPhone 4 runs; during "paging" it was in fact blocking the screen):

![](img/m0-n90ap-11D257-usbkbd-alert.png)

Screenshots of each run's lock screen, home screen, second page, Settings, Clock and post-restore state are in `work/runs/<run>/`.

## 6. Reproduction steps

All commands run from the project root `~/Developer/classic-ios`. All outputs are in `work/` (not in the repository). The two upstream repositories are read-only and unchanged (`git status` is clean, see "Upstream changes").

### 0. Environment and dependencies

This machine: M4 Max (10 performance cores + 4 efficiency cores, 36 GB), macOS 27.0.1, Xcode 27.2.

```bash
brew install glib ninja meson pixman pkgconf openssl@3 python@3.12 libslirp ldid jq
```

QEMU's configure needs Homebrew's python@3.12 (troubleshooting section of RUNNING.md: the latest Python lacks distlib).

### 1. Upstream source

```bash
git clone https://github.com/samhenrigold/qemu-ios upstream/qemu-ios          # b225694505
git clone https://github.com/samhenrigold/LightTouchMac upstream/LightTouchMac  # b06012fa4c
```

### 2. FFmpeg (workaround 1)

QEMU treats libavcodec/libavutil as optional dependencies (`hw/arm/meson.build`: H.264 and AAC decoding for the iPod touch 2nd gen) and builds without them, but the Light Touch release uses FFmpeg 9.0.1 with two upstream patches (`contrib/ffmpeg/*.patch`), which the Homebrew version lacks. So a minimal build is made by hand with the options from LightTouchMac's `build-support/recipes/build-package-native.sh` (only the aac, mp3, alac and h264 decoders enabled):

```bash
tools/m0/build-ffmpeg.sh            # downloads ffmpeg-9.0.1.tar.xz (checks sha256), applies the patches, installs to work/ffmpeg/prefix
mkdir -p work/build-jit/ffmpeg-pkgconfig
ln -s $PWD/work/ffmpeg/prefix/lib/pkgconfig/libavcodec.pc $PWD/work/ffmpeg/prefix/lib/pkgconfig/libavutil.pc \
  work/build-jit/ffmpeg-pkgconfig/
```

(The TCI build points to this directory too. Only these two .pc files are put there so that pkg-config takes FFmpeg only from here and does not touch anything else in Homebrew.)

### 3. QEMU: JIT build and pure interpreter (TCI) build

The two builds differ only by `--enable-tcg-interpreter`:

```bash
for kind in jit tci; do
  mkdir -p work/build-$kind && cd work/build-$kind
  extra=""; [ $kind = tci ] && extra="--enable-tcg-interpreter"
  PKG_CONFIG_PATH=$PWD/../build-jit/ffmpeg-pkgconfig ../../upstream/qemu-ios/configure \
    --target-list=arm-softmmu --disable-sdl --disable-sdl-image --disable-capstone --disable-pie --disable-fuse \
    --extra-cflags="-I/opt/homebrew/opt/openssl@3/include -mmacosx-version-min=12.0" \
    --extra-ldflags="-L/opt/homebrew/opt/openssl@3/lib -lcrypto -mmacosx-version-min=12.0 -Wl,-rpath,$PWD/../ffmpeg/prefix/lib" \
    --python=/opt/homebrew/opt/python@3.12/libexec/bin/python3 $extra
  ninja qemu-system-arm && cd ../..
done
```

Each build takes about 1 minute (14 cores). `--disable-sdl`: headless only (`-display none`); `--disable-fuse`, `--disable-capstone` and `--disable-pie` follow RUNNING.md's Apple Silicon configuration.

### 4. Guest tools: substitute SDK (workaround 2)

When making a device, FirmwareKit installs qemu-ios's guest tools into the firmware (the OpenGLES GL frontend, it_agent, AppSync and so on). They are compiled by `contrib/export-guest-artifacts.sh`, which requires two old SDKs, iPhoneOS 3.1.3 and 3.2. Those are Apple downloads, not on this machine, and may not be fetched. In practice the build uses only two things from the SDK: the C headers in `usr/include`, and a libSystem stub with an armv7 slice (used only by the linker to resolve symbols; at runtime the firmware's own libSystem is bound). `tools/m0/make-substitute-sdk.py` builds a stand-in from the local Xcode's iPhoneOS SDK: it copies the headers (forcing `_FORTIFY_SOURCE` off, because 3.x's libSystem has no `__*_chk` family), adds the compiler's own freestanding headers (stdbool.h and the like, which the old SDKs shipped and the new SDK does not), and then flattens all exported symbols in libSystem.B.tbd into a single armv7-ios text stub. The stand-in contains no Apple binaries and is not packaged or distributed.

```bash
python3 tools/m0/make-substitute-sdk.py work/sdk-substitute/iPhoneOS-substitute.sdk
ARMV6_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk IPAD_SDK=$PWD/work/sdk-substitute/iPhoneOS-substitute.sdk \
  LDID=$(command -v ldid) upstream/qemu-ios/contrib/export-guest-artifacts.sh work/guest-artifacts
```

Result: 44 files; `work/guest-artifacts/ipad-guest-tools/` is the flat directory FirmwareKit expects. All three devices got the GL frontend, AppSync and it_agent installed when they were made, and after boot the GL bridge works normally (`[gles] host GL up`).

### 5. FirmwareKit and a fake LightTouchDevice (workaround 3)

```bash
swift build -c release --package-path upstream/LightTouchMac/Packages/FirmwareKit --scratch-path work/build-firmwarekit
# output: work/build-firmwarekit/release/firmwarekit (about 50 seconds)
```

When making devices for iOS 4 and later, `firmwarekit create` boots them a few times (sealing, creating the keybag, checking), and hands these boots to Light Touch's device helper LightTouchDevice (built with Xcode, signed, sandboxed, loading libqemu-arm.dylib in process). We do not build the Light Touch app, so `tools/m0/helper-shim/` provides a stand-in: it implements only the two modes firmwarekit uses, `machines` (lists machine types, taken from `tests/fixtures/machines.json`) and `oneshot` (runs `qemu-system-arm` with the same argv until QEMU exits, a marker appears on the serial port, or it times out). One detail: firmwarekit launches the helper from a thread that blocks SIGTERM, and the signal mask is inherited across exec, so the stand-in must unblock it first, otherwise QEMU does not receive SIGTERM when the marker arrives.

```bash
mkdir -p work/tools && cp -R tools/m0/helper-shim work/tools/helper-shim
```

### 6. OCR tool

First-time setup (Setup Assistant) is driven automatically by reading text from screenshots and tapping, implemented with Vision following the TextReader in LightTouchMac's SessionKit:

```bash
mkdir -p work/tools/ocr && swiftc -O tools/m0/ocr.swift -o work/tools/ocr/ocr
```

### 7. Firmware (downloaded by the user, not in the repository)

| Device | File | Source | SHA-1 |
|---|---|---|---|
| iPhone 3GS 6.1.6 | iPhone2,1_6.1.6_10B500_Restore.ipsw | Apple servers (URL from the firmware catalog) | eb7f495760a500bb284b07f11492a4fadf687802 |
| iPhone 4 7.1.2 | iPhone3,1_7.1.2_11D257_Restore.ipsw | Apple servers | 81da17b3e893a61508fe203849b7e1f60e2127b1 |
| iPod touch 2nd gen 3.1.3 | iPod2,1_3.1.3_7E18_Restore.ipsw | archive.org (URL from the firmware catalog; Apple has taken it down) | 5f4f5c01eda2f811f73167e7d1f82dbeed82367b |

All URLs come from `upstream/LightTouchMac/LightTouchMac/Resources/firmware-catalog.json`; after downloading, check them against it with `shasum`.

### 8. Making the devices

```bash
for id in n88ap-10B500:iPhone2,1_6.1.6_10B500 n90ap-11D257:iPhone3,1_7.1.2_11D257 n72ap-7E18:iPod2,1_3.1.3_7E18; do
  dev=${id%%:*}; ipsw=${id#*:}
  /usr/bin/time -p work/build-firmwarekit/release/firmwarekit create \
    --catalog upstream/LightTouchMac/LightTouchMac/Resources/firmware-catalog.json --id $dev \
    --ipsw work/firmware/${ipsw}_Restore.ipsw --out work/devices/$dev \
    --helper work/tools/helper-shim/LightTouchDevice --cache work/cache \
    --guest-tools work/guest-artifacts/ipad-guest-tools \
    > work/devices/create-$dev.jsonl 2> work/devices/create-$dev.err
done
```

Time taken: 3GS 237 seconds (including three one-off boots), iPhone 4 about 2 minutes, iPod 9 seconds (3.x does not need a boot to create the keybag). Language and keyboard default to the Mac's (en-AU).

### 9. First-time setup, producing the "golden state"

```bash
python3 tools/m0/bench.py setup --device work/devices/n88ap-10B500 --golden work/states/n88ap-10B500
python3 tools/m0/bench.py setup --device work/devices/n90ap-11D257 --golden work/states/n90ap-11D257
python3 tools/m0/bench.py setup --device work/devices/n72ap-7E18  --golden work/states/n72ap-7E18
```

Boot with the JIT build, OCR each page, and tap according to SetupPlan's rules (English, United States, skip Wi-Fi, location off, set up as new iPhone, agree to the terms, no passcode, don't send diagnostics); on reaching the home screen, take a screenshot and power off with `system_powerdown`. The resulting `state/` (writable NOR plus NAND overlay) is the starting point for every later benchmark run; each run first makes an APFS clone of it.

iPod touch 2nd gen (workaround 4, added in this session):

- Boot chain: build the arguments following `BootRecipe.iPod`, `-M iPod-Touch,boot-args=...,direct-iboot=<base>/iBoot.bin,bootrom=<SecureROM>,nand=<overlay>/nand,nor=...,nor-rw=...,wifi=on,gid-blobs=...`, plus `-m 128M` and the environment variable `IT_TVOUT_READY=1` (upstream comment: 3.1.3 does not boot without it).
- Its NAND is in "image store" format (`nand-xor-blank-v2`), which the emulator writes directly, so, as `PreparedDeviceBoot.liveNAND` does, the base's four chip files have to be clonefiled into `overlay/nand/` and then made writable; `nand-overlay` cannot be used as on the 3GS.
- Home button: this machine type has no `button-home` property; the button goes through the keyboard as Command+Shift+H (`ipod_touch_kbd_button`), and the power button is Command+L.
- SecureROM: machine init unconditionally loads the file that `bootrom=` points to (`ipod_touch_load_bootrom`, exiting on failure). The real ROM (`bootrom_240_4`) is not in the IPSW; Light Touch ships it bundled in the app's `Resources/Device/`, and we neither have it nor may take it. When cold booting via direct-iboot the ROM is only placed in memory and never executed, so a 4-byte placeholder file (ARM instruction `b .`, `work/m0-placeholder/bootrom_240_4`) is enough to boot. For the cost, see "Pitfalls": it cannot wake from deep sleep.
- 3.x has no Setup Assistant (activation is written in when the device is made); it boots straight to the lock screen, and sliding it open gives the home screen.

### 10. Benchmarks

```bash
tools/m0/run-queue.sh n88-jit-1:n88ap-10B500:jit n88-tci-1:n88ap-10B500:tci ...   # one run after another, never in parallel
```

Each run (`bench.py run`): clone the golden state and cold boot to the lock screen; wait until some 10-second window has CPU below 60%, which counts as "settled"; unlock and idle on the home screen for 40 seconds; page back and forth on the home screen 5 times (about 20 seconds); launch Settings and then Clock with the guest agent, 10 seconds each; return to the home screen and save a snapshot with `stop` plus `migrate file:`; quit; restore twice with `-incoming file:` on a clone of the snapshot's matching state, each time taking a screenshot, using OCR to find the Settings icon and tapping it (to verify touch works after restore), then idling for 30 seconds. All CPU numbers are the QEMU process's (all threads) user plus system time divided by wall clock time, and "% of one core" = CPU seconds / wall clock seconds × 100; per-thread breakdowns are also recorded (`CPU 0/TCG` is the guest main core). `uptime` is recorded before and after each run and load average at the start of each window, plus `work/runs/load.log` with one entry every 15 seconds.

Frame rate (`bench.py fps`, added in this session): restore from a run's snapshot; `--mode drag` holds a finger on the home screen and drags left and right for 20 seconds (one round trip every 2 seconds), `--mode lock` watches the "slide to unlock" shimmer animation on the lock screen; meanwhile, screenshots (ppm) are taken continuously at up to 120 Hz and compared, and each time two consecutive ones differ counts as one new frame on screen, giving the "visible frame rate" (upper limit = sampling rate). The original plan was to use the GL bridge's built-in `IT_GLES_PROF` frame statistics, but the path 6.x CoreAnimation compositing takes does not update that counter, so it could not be read.

Sleep test (`tools/m0/sleep-test.py`): restore from the iPod's snapshot, lock with Command+L, wait two minutes, press Home, and check the agent and CPU registers.

Commands (the frame rate probes and the sleep test all start from a snapshot saved by some run, a few tens of seconds each):

```bash
python3 tools/m0/bench.py fps --mode drag --device work/devices/n88ap-10B500 --run work/runs/n88-jit-1 --build jit --out work/runs/fps-n88-jit-1
python3 tools/m0/bench.py fps --mode lock --seconds 4 --wake-wait 0.5 --device work/devices/n90ap-11D257 --run work/runs/n90-tci-3 --build tci --out work/runs/fpslock-n90-tci-3
python3 tools/m0/sleep-test.py work/runs/n72-jit-1 work/runs/sleep-test-n72 120
python3 tools/m0/summarize.py > work/runs/summary.md     # generates all the tables in sections 2 and 4
```

Lock mode first presses the power button to lock and Home to wake, and polls until the screen turns on before sampling (under TCI, iOS 7 takes 5 to 6 seconds to light up).

## 7. Pitfalls

| Pitfall | Symptom | Handling |
|---|---|---|
| iOS 7 pops up "Cannot Use Device / QEMU USB Keyboard" | Following `BootRecipe.iPad`, the benchmark script attaches `-device usb-kbd` to machine types with a USB host port (iPhone 4) (Light Touch uses it for keyboard input). iOS 7 shows this modal alert right after unlock, blocking all touches and the Home button: in the first three iPhone 4 runs, "paging" never actually paged, Home could not get back to the home screen after opening Clock, the snapshot was left inside Clock, and the iPhone 4 drag frame rate probe was also measured in this state | These runs were discarded as a whole and moved to `work/runs/invalid-usbkbd/` (the boot numbers come before the alert appears and are still usable as a reference). The script now takes a screenshot and runs OCR after unlocking, and taps "OK" when it sees the alert (`dismiss_alerts`); the iPhone 4 was rerun four times. usb-kbd was not removed, to stay consistent with Light Touch's parameters. The 3GS and iPod have no USB host port and are unaffected |
| The iOS 7 lock screen shimmer means TCI never "settles" | The shimmer on the "slide to unlock" text plays continuously; under TCI the lock screen alone takes about 93% of one core (guest main core 68% + main thread 25%), so the script's "10-second window below 60%" is never met and it runs to the 18-minute limit | Settle limit changed to 180 seconds for JIT and 300 seconds for TCI (3GS and iPod TCI both settle naturally within 30 to 120 seconds and are unaffected by this change) |
| The M1 session compiling at the same time and Spotlight indexing pushed the load to 20 to 63 | At the start of the idle window of the second 3GS TCI run the load was 20.8, and idle measured 57.7% (first run 41.5%); the second iPhone 4 JIT run booted in 59 seconds (first run 41 seconds). Under high load, CPU share is inflated, presumably because the process gets pushed onto efficiency cores, where the same work takes more CPU time | Load average is recorded at the start of each window, plus `work/runs/load*.log` with one entry every 15 seconds. In the summary, runs whose window-start load exceeded 8 are excluded from the interaction means (marked ⚠ in the tables), and a third 3GS TCI run was added. `work/` is not on Spotlight's exclusion list (changing system settings needs the user's approval, so it was left alone), and the newly generated snapshots and devices of several hundred MB trigger mds_stores at 300% CPU |
| iPhone 4 7.1.2 cannot power off | After first-time setup, `system_powerdown` on iOS 7 only brings up "slide to power off"; nobody slides it, so after 120 seconds the script exits with QMP `quit` (NAND is synced at exit). The golden state is equivalent to pulling the battery, but HFS+ is journaled, and every later run booted to the lock screen normally | Recorded. For a cleaner result, setup could add a step that uses OCR to find "slide to power off" and then slides it |
| iPod touch 2nd gen needs the SecureROM | Machine init unconditionally reads `bootrom=`; the file is not in the IPSW, and Light Touch ships it bundled in the app | A 4-byte placeholder file (`b .`) works for cold boot; but waking from deep sleep hangs, see the next row |
| With the placeholder ROM, the iPod never wakes once asleep | Measured (`tools/m0/sleep-test.py`): after restoring a snapshot and locking with Command+L, about 30 seconds later the PMU cuts power to the AP (the agent goes silent, the CPU barely moves); after pressing Home the CPU resets to address 0 (R15=0), which is the placeholder ROM's infinite loop, and it never comes back. When the screen is only dimmed (not yet in deep sleep), pressing Home wakes it; M1 saw this on the phone too | For the real fix see "Impact on later stages": add a high-level emulation of wake for the iPod 2nd gen modeled on the 3GS machine's `s5l8920_resume`, and the SecureROM is no longer needed at all. Until then, the app should keep the iPod out of deep sleep (for example set Auto-Lock to Never, and have the lock button only turn off the screen) |
| The iOS 6 frame counter cannot be read | Tried to count frames with the GL bridge's `IT_GLES_PROF`, but the path 6.x CoreAnimation compositing takes does not update that counter | Switched to continuous screenshot comparison (independent of the rendering path) |
| Lock screen animation frame rate is meaningless on 3.x and 6.x | The lock screen shimmer on 3.x and 6.x is itself 10 to 15 fps (the same under JIT and TCI), so no difference can be measured; only the iOS 7 shimmer is a continuous 60 fps animation | For 3.x and 6.x use the home screen drag frame rate; for iOS 7 both are given |
| Under TCI, "tap app to foreground" seconds have coarse granularity | This time relies on repeatedly asking the guest agent what is in the foreground, and under TCI the agent itself is slow to answer; the two iPod TCI runs measured 0.9 seconds and 2.9 seconds | Use only as an order-of-magnitude reference; CPU share and boot time are more reliable |
| `pgrep`/`pkill` kill processes by name | Other sessions on this Mac are also running emulators | Only stop processes by the PIDs we started ourselves (that is how the second iPhone 4 TCI run was stopped midway) |

## 8. Impact on later stages and recommendations

- **JIT is still required, at least for iOS 6 and later.** iPhone OS 3 is usable under the interpreter and can serve as the fallback "when JIT is not enabled"; iOS 6 barely; iOS 7 not at all. The plan of shipping two dylibs in the app and picking one depending on whether a debugger is attached (M1's research) holds up; without JIT the app could offer only generations 1 to 3 of the system, or clearly warn "slow".
- **Snapshots should go at the very front of M2**: on the phone the EAGL backend forbids saving snapshots (section 3), and no snapshots means a cold boot every time: 2 minutes for iOS 6 and nearly 7 minutes or more for iOS 7 under the interpreter. Porting CGL's readback and rebuild to EAGL is the prerequisite for "instant switching via snapshots".
- **iPod 2nd gen wake patch**: add a high-level emulation of wake to `hw/arm/ipod_touch_2g.c` modeled on `s5l8920_resume` in `hw/arm/s5l8920.c`, and iPhone OS 2 and 3 no longer need Apple's SecureROM. The patch should go in `patches/`. The S5L8900 machine types used by iPhone OS 1 (original iPhone, iPod touch 1st gen) also need a SecureROM (`bootrom_s5l8900`, which FirmwareKit's N45 recipe treats as a boot input); not tested this time, and it needs a separate look at whether it can be handled the same way.
- **iOS 7 idle cost**: the home screen redraws 30 times per second, taking 25% of one core even under JIT (iOS 6 only 10%), so battery drain on the phone will be noticeable. Worth trying "Reduce Motion" in M2, or pausing the VM when the app goes to the background (the M1 report also suggested the latter).
- **iOS 7 USB keyboard alert**: if the app attaches usb-kbd like Light Touch, iOS 7 pops up "Cannot Use Device" and blocks touches. The app should either not attach it, preset "already alerted" when making the device, or dismiss it automatically on first boot.
- **iPhone 4 home screen drag is only 15 fps (even under JIT)**; the bottleneck is not the CPU, so when M2 works on making it "playable" it needs to look at touch reporting and the 640×960 display path.
- **The benchmark script can be moved to the phone as is**: `bench.py`'s measurement method (process CPU seconds / wall clock, the guest agent to determine the foreground, screenshot comparison for frame rate) does not depend on the Mac. Once M1's real-device benchmarks use the same method as here, the extrapolations in section 4 can be replaced with measurements.

## 9. File list

- This report: `docs/reports/m0-mac-benchmark.md`; screenshots in `docs/reports/img/`: `n72ap-7E18-home-after-setup.png`, `n88ap-10B500-home-after-setup.png`, `n90ap-11D257-home-after-setup.png` (home screens of the three versions), `m0-n90ap-11D257-usbkbd-alert.png` (the iOS 7 USB keyboard alert).
- Scripts (`tools/m0/`): `bench.py` (three subcommands: setup, run, fps), `run-queue.sh` (sequential runs), `summarize.py` (tables), `sleep-test.py` (iPod sleep and wake), `make-substitute-sdk.py`, `build-ffmpeg.sh`, `helper-shim/`, `ocr.swift`.
- Data (`work/`, not in the repository): `work/runs/<device>-<mode>-<n>/result.json` plus each run's screenshots, snapshots and CPU samples; `work/runs/fps-*`, `fpslock-*` frame rate probes; `work/runs/swaps-n90-jit-3`; `work/runs/sleep-test-n72*`; `work/runs/summary.json`, `summary.md`; `work/runs/load.log`, `load2.log`; the discarded iPhone 4 runs are in `work/runs/invalid-usbkbd/`. Golden states are in `work/states/`, devices in `work/devices/`, the placeholder SecureROM in `work/m0-placeholder/`.
