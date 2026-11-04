# M1 stage 2: JIT moves to the universal protocol

- Date: 2026-11-01
- Execution session: M1 execution session (continuing from stage 1). The scope is stage 2 as assigned by the decision session: the new JIT protocol patch, debugger support, simulator regression, a 256 MB re-test on device, and a long standby test on the iPod touch 2nd gen. The decision session narrowed the scope three times along the way: the long standby test was cancelled; each device gets only one 256 MB round; no 512 MB run and no "without mirroring" comparison.
- Not done: did not touch the iPhone 14 Pro, did not install StikDebug, did not copy the 6 to 7 GB of device symbols, did not commit.

## 0. Conclusions

1. **The new protocol works, but it does not reach the goal of "256 MB ready in a few seconds".** The patch `patches/ios-txm-jit-protocol.patch` makes QEMU issue `brk #0xf00d` (the convention of StikDebug's universal.js). The debugger on the Mac allocates executable memory with debugserver's `_M`, and **256 MB takes only 0.02 seconds**; once QEMU has mapped it, it sends "detach", and from then on the App no longer runs with a debugger attached. On the iPhone 18 Pro, 32 MB succeeded end to end 4 times, each reaching the home screen.
2. **After allocation the debugger still has to write every page once, and this step is limited by connection speed.** Measured: if memory is only allocated and not written, the generated code cannot execute: the App pins one core and the screen does not move. Over Wi-Fi there are two ways to write: writing the whole block runs at about 2.0 to 2.2 MB/s, so 32 MB takes 15 to 17 seconds; writing 1 byte per page (what StikDebug does) takes about 29 ms per page, so 32 MB takes 60 seconds. Extrapolating, 256 MB takes about 2 minutes as a whole-block write and about 8 minutes page by page. The old protocol's read-and-write-back of 256 MB took 322 seconds. StikDebug runs on the phone itself, where the round trip is nearly zero, which is why page-by-page writing is fast there. Debugging from the Mac across the network, this step cannot be made fast.
3. **The formal 256 MB measurement on device was not completed; there are no new numbers for JIT lock screen time or idle CPU on either device.** The reason is that my debugger script (`lldb_jit_runner.py`) is unstable under the LLDB in Xcode 27.2. Details of the three phases below are in section 4:
   - First, two measurement scripts were running at the same time and kept killing each other's App, causing repeated attach failures. A single-instance lock has been added.
   - With the signals QEMU uses set to "handled internally by LLDB", attaching sometimes hung (Resume timed out).
   - After switching to "stop, then pass each one through", attaching became stable, but registers could no longer be changed: the PC could not step past `brk`, and the same request fired again and again.

   As agreed with the decision session, I stopped here. The App on the phone has been terminated and no processes are left over.
4. At 32 MB, boot behavior is the same under the new and old protocols; the only difference is the preparation time:
   - QEMU screen on: new protocol 12.0 to 15.9 seconds, old protocol 12.8 seconds.
   - To lock screen, excluding the pause: new protocol about 16 to 18 seconds, old protocol about 18 seconds.
   - Home screen idle CPU: new protocol 23% to 28%, old protocol 21%.
5. The simulator regression matches stage 1; the change only affects JIT on device. The iPod touch 2nd gen long standby test was cancelled as instructed, and the SecureROM placeholder file is listed as "known risk, untested" (section 5).

## 1. Patch: `patches/ios-txm-jit-protocol.patch`

Changes `tcg/region.c`, and only takes effect on a real iOS device, iOS 26 or later, JIT build, with a debugger attached:

- `jit26_prepare_region(0, size)`: `mov x16, #1; brk #0xf00d; ret`. x0 = 0 asks the debugger to allocate, x1 is the length, and the debugger writes the address back into x0. If the return value is not page-aligned, or is below the 4 GiB `__PAGEZERO`, it is treated as the debugger not having handled the request, and QEMU exits with an error.
- After getting the RX address, it makes an alias with `mach_vm_remap` and then `mprotect`s it to RW, as the side TCG writes code to (split-wx).
- `jit26_detach()`: `mov x16, #0; brk #0xf00d`, asking the debugger to detach. QEMU maps the code region only once and no longer needs the debugger after that.
- The environment variable `QEMU_IOS_JIT_PROTOCOL=legacy` keeps the old `brk #0x69` read-and-write-back for comparison. The App launch argument `-jitprotocol legacy` sets this variable.
- The implementation follows the 0016 patch in vytska69/Ios-emul; the protocol follows StikDebug's universal.js (`_M<length>,rx` to allocate, `prepare_memory_region` writes 1 byte per 16 KiB page; see StikDebug's `JSDebugSupport.swift`).
- The patch header gives the reason and the upstream commit it is based on (b225694505, stacked after `ios-host-gles-option.patch`). All four dylibs have been rebuilt, and 3 instances of `brk #0xf00d` can be seen in the device JIT build.

This patch is also the prerequisite for later getting JIT through StikDebug without a computer: universal.js only returns an error code for `brk #0x69`.

## 2. Debugger side: `scripts/ios/lldb_jit_runner.py`

- Recognizes `brk #0xf00d`: when x16=1, it allocates with `SBProcess.AllocateMemory(size, readable and executable)`, then writes according to `JIT_TOUCH`:
  - `bulk` (default): write zeros over the whole block.
  - `page`: write 1 byte per page.
  - `none`: allocate only, do not write.

  After writing, it writes the address back into x0 and adds 4 to PC. When x16=0, it detaches and exits. The old `brk #0x69` is still supported as before.
- LLDB problems worked around (already present in stage 1):
  - no stop hooks driven from the command line; the SB API in synchronous mode is used instead;
  - parallel module loading is turned off;
  - `target.memory-module-load-level minimal`: this machine has no symbol cache for the phone's 24B119;
  - the gdb-remote packet timeout is raised to 60 seconds.
- New in stage 2:
  - after writing registers, read them back to verify, and if they are wrong, write again with `register write`;
  - if the same prepare request appears a third time, terminate the process so the phone does not stay frozen;
  - after 3 consecutive Resume timed out, flush the packet log to disk first and then exit;
  - an optional gdb-remote packet log (`LLDB_PACKET_LOG`).
- New in `device-boot.sh`:
  - `TBSIZE`, `JITPROTO`, `JIT_TOUCH` parameters;
  - automatic retry when attaching hangs (up to 3 times);
  - single-instance lock;
  - the summary records whether the iPhone Mirroring App was running at the time, the Mac load, and the debugger preparation time.
- New in the App:
  - the `-jitprotocol` argument;
  - during JIT preparation the status bar says "The screen will freeze for a moment", and this is drawn before QEMU starts;
  - the JIT build of the library is loaded before waiting for the debugger;
  - `-qemuargs` now reads the raw arguments directly (UserDefaults treats a value starting with "-" as a new key).

## 3. Measurements

### 3.1 Simulator regression (the new patch does not affect the simulator)

| Device | Backend | QEMU screen on | Lock screen | Home screen | Home screen idle CPU | Peak footprint |
|---|---|---|---|---|---|---|
| iPod touch 2nd gen 3.1.3 | JIT 256 MB | 8.8 s | 11 s | 19 s | 20% | 703 MB |
| iPod touch 2nd gen 3.1.3 | Interpreter | 36.3 s | 54 s | 64 s | 77% | 399 MB |
| iPhone 3GS 6.1.6 | JIT 256 MB | 18.6 s | 19 s | 48 s | 12% | 799 MB |

Matches stage 1 (10 seconds, 54 seconds, 19 seconds to the lock screen). The idle segments were checked: no events, and the frame number did not change.

### 3.2 iPhone 18 Pro, iPod touch 2nd gen 3.1.3, JIT, 32 MB code region

| Run | Protocol, write method | Preparation time | QEMU screen on | Lock screen (pause excluded) | CPU seconds at lock screen | Home screen idle CPU | Footprint | Available memory |
|---|---|---|---|---|---|---|---|---|
| Stage 1 195249 | Old protocol, read and write back | 46.4 s | 12.8 s | about 18 s | 17.8 | 21% | 277 MB | 3099 MB |
| 203400 | New protocol, page by page | allocate 0.10 s + write 60.1 s | 12.3 s | 17 s | 16.6 | 23% | 242 MB | 3134 MB |
| 203806 | New protocol, whole block | 0.02 + 16.7 s | 12.0 s | 16 s | 15.8 | 25% | 247 MB | 3129 MB |
| 204358 | New protocol, whole block | 0.03 + 16.8 s | 12.8 s | 18 s | 17.9 | 25% | 248 MB | 3128 MB |
| 204542 | New protocol, whole block | 0.10 + 17.0 s | 15.9 s | 18 s | 17.4 | 28% | 250 MB | 3126 MB |

- All runs over Wi-Fi, Mac 1-minute load 3.3 to 3.7. Each round's idle segment (about 20 seconds from the home screen until exit) was checked with `check-idle.py`: no events other than the script's, frame number change of 0 to 1 (the status bar clock), so the data is usable.
- The "mirroring" column can only record whether the iPhone Mirroring App on the Mac was running (it was in all these rounds), not whether a mirroring session was actually connected.
- Allocate only, no write (`JIT_TOUCH=none`, 256 MB, 203629): allocation took 0.02 seconds followed immediately by detach, but afterwards the App spun one core at 100%, the frame number stayed at 1, the footprint was only 25 to 38 MB, and it did not boot. This shows that TXM really only accepts pages the debugger has written.

Screenshot: `docs/reports/img/m1s2-device-n72ap-3.1.3-jit32-universal-home.png` (window snapshot saved by the App itself in run 203806, home screen, status bar shows JIT).

### 3.3 Formal 256 MB measurement on device: not completed

Neither device got new 256 MB numbers. All I can give is an extrapolation: over Wi-Fi, whole-block writing is about 2.1 MB/s, so 256 MB takes about 2 minutes; in stage 1, also over Wi-Fi, the old protocol's read-and-write-back took 322 seconds. The wired (cable) speed was not measured either: while the user had the cable plugged in, attaching was stuck on the problem described in the next section and never succeeded once.

### 3.4 Side note: correcting stage 1's idle CPU

In stage 1, `summarize-run.py` also counted the few seconds after QEMU exited as part of the idle segment, so the idle CPU was too low. Recomputed as "3 seconds after the home screen until exit":

| Stage 1 run | Originally reported | Recomputed |
|---|---|---|
| Device iPod interpreter | 50% | 61% |
| Device 3GS interpreter | 91% | 108% (more than one core) |
| Device iPod JIT 32 MB | 18% | 21% |
| Device 3GS JIT 32 MB | 79% | Void: the decision session checked and someone tapped Settings during that period |

The script has been fixed, and all stage 2 numbers use the new method.

## 4. Where it got stuck: the debugger side is unstable under Xcode's LLDB

In chronological order; every phase has logs (`work/ios/runs/device/lldb-*.log`, `packets-*.log`):

1. **20:25 to 20:46, the old signal settings** (SIGUSR1/2 etc. set to "do not stop, handled internally by LLDB and passed to the process"): 6 successes (including 4 formal 32 MB runs), 4 failures. Every failure began with two "stops with no reason" right after attaching, and then every continue gave `Resume timed out`.
2. **20:40 to 21:10, the misdiagnosis phase**: I suspected, in turn, Wi-Fi latency, the phone's lock screen, and dyld load notifications, and changed things for each one; it still failed with the cable plugged in. Finally I found that the script from the formal measurement at 21:04 had never exited after its retry failed, and the later verification script was running alongside it. Both launched the App with `--terminate-existing` and kept killing each other's App. At least part of the consecutive failures after 20:41 came from this. A single-instance lock has been added.
3. **Another problem in the packet log** (21:05, `packets-fail.log`): a QEMU thread stopped on SIGUSR2 (the sigaltstack coroutines rely on it to switch stacks), and when LLDB resumed it sent a plain `c` with no signal instead of `vCont;…;C1f`, so the signal was swallowed and the QEMU thread stayed in `sigsuspend` forever. When this sample was taken the old script may also have been running, so interference cannot be fully ruled out.
4. **After switching to "stop, notify, pass each one through"** (21:13, 21:58): attaching became stable, attaching in 0.5 seconds and stopping at `brk #0xf00d` 2 seconds later, with a whole-block write of 32 MB taking 15 to 18 seconds. But writing back x0 and PC had no effect: both SBValue and `register write` read back the old values, the same `brk` fired again and again, and the debugger reallocated and rewrote 32 MB each time. The second time, the guard I added terminated the process on the 3rd trigger. The same code changed registers fine under the settings in step 1, so I suspect it is related to the "stop on signal" setting (does LLDB refuse register changes while a thread still has a pending signal?). There was no time to verify this.

I also confirmed a limitation unrelated to the code: **while the phone is locked, the system refuses an App launch from devicectl on the Mac** ("Unable to launch org.classictouch.app because the device was not, or could not be, unlocked"). With iPhone Mirroring, the phone itself is locked, so mirroring cannot be used during device measurements; the user has to unlock the phone and look at it directly. Launches were refused even when `lockState` showed passcodeRequired as false, so go by the actual launch result.

### Options

1. **Separate signal handling from register changes (recommended; prepare it first without occupying the phone)**: restore the signal settings from step 1 (register changes worked in step 1); the single-instance lock already rules out the kind of mutual interference in step 2. Only on a "stop with no reason", do not rush to continue; wait for LLDB's internal resume to finish before sending. Then, when convenient for the user, verify once at 32 MB and run two rounds at 256 MB. Each round over Wi-Fi freezes the phone for about 2 minutes.
2. **Use USB**: with the cable plugged in, whole-block writing should be much faster, but it was not measured this time, and it still requires fixing item 1 first.
3. **In the long run, JIT should not depend on LLDB on the Mac at all**: the release form is StikDebug (or embedded StikJIT) answering `brk #0xf00d` on the phone itself, where the round trip is nearly zero and page-by-page writes can also be pipelined in batches, so 256 MB would take just a few seconds. The patch is already written to this protocol and can be verified directly when StikDebug is installed in E3. StikDebug needs the user's approval before it is installed.

## 5. iPod touch 2nd gen SecureROM placeholder file: long standby test cancelled, listed as a known risk

After running for about 11 minutes in the second simulator (ClassicTouch Standby), it was stopped as instructed by the decision session, and the simulator has been shut down. Observations:

- About 1 minute after the lock screen, the backlight went to 0, CPU 2% to 4%, and the frame number stopped changing.
- Reading the CPU's PC over QMP once a minute, all 11 readings were at the same place in the guest kernel (0xc0567e3c, apparently idle waiting for an interrupt); no sign of the AP powering off or of wake-up going through the bootrom.
- It never got to the "press Home to wake" step.

Conclusion: **known risk, untested**. To be handled when the iPod touch 2nd gen is officially supported: either have the user supply their own SecureROM, or make wake-up also go through direct-iboot (only researched where to change; not done yet).

## 6. Files

- Added or modified:
  - `patches/ios-txm-jit-protocol.patch`
  - `scripts/ios/lldb_jit_runner.py`, `device-boot.sh`, `sim-boot.sh`, `summarize-run.py`
  - new scripts `check-idle.py`, `sim-standby.sh`, `qmp.py`
  - `app/ClassicTouch/Engine.swift`, `EmulatorViewController.swift`
  - this report and `docs/reports/img/m1s2-*.png`
- Raw records:
  - `work/ios/runs/device/`: each round's run directory, summary, debugger log, packet log
  - `work/ios/runs/standby-cancelled.log`
  - `work/ios/logs/`
- Research material: `work/ios/research/` (the 0016 patch from Ios-emul, StikDebug's universal.js and JSDebugSupport.swift, read-only reference).
