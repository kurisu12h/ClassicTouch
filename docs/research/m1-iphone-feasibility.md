# M1 research: feasibility of moving qemu-ios onto iPhone

- Date: 2026-11-01
- Author: the M1 research execution session (read-only research; no repository was cloned, nothing was downloaded, and no repository file was modified, except this file)
- Method: used `gh api` to read the commits and historical files of samhenrigold/qemu-ios, samhenrigold/LightTouchMac, utmapp/UTM, utmapp/qemu, StikDebug and other repositories; WebSearch / WebFetch; the iPhoneOS27.2 SDK of the local Xcode 27.2 and the iPhone 18 Pro device symbol cache already on this machine.
- Labels: **[verified]** means I read the source, commit message, SDK file or the project's own documentation directly; **[inferred]** means my inference, or only third-party claims that I could not verify independently.
- Test devices (added by the decision session): iPhone 18 Pro (A20 Pro, iOS 27.2), iPhone 14 Pro (A16, iOS 27.0.1).

---

## 0. Summary of conclusions

1. **Upstream really did run on a real iPhone; it was abandoned because of performance, not because of the build or graphics.** On 2026-08-04 the author built qemu-ios as an iOS dylib, put it into an app, copied a NAND image in and booted on the phone; JIT was only usable with the Xcode debugger attached. The 8-05 "TCG experiments, dead end." is a whole set of experiments to speed up the pure interpreter (UTM's TCTI, PGO, HLE of memcpy and the like by address, longer timers, lower vsync), and its conclusion is: the release build "will never have JIT", the interpreter is about 30 times slower, the UI gets only 1 to 2 fps, and TCTI differs from the plain interpreter by only 1%. The same day the author moved on to the Mac version (LightTouchMac's first commit is also on 8-05). **[verified]**
2. **JIT can be had on iOS 26/27, but only through an external debugger, and by following TXM's new protocol.** Both test devices count as TXM devices on iOS 27, with the same mechanism: the app first maps the code region as RX, then traps with `brk` so that the debugger (Xcode LLDB or a StikDebug script) "prepares" that memory. qemu-ios's `tcg/region.c` already has this code (ported from UTM, using the old `brk #0x69` protocol). One public report confirms that a QEMU-type app got JIT on **iOS 27.2** with StikDebug (iPhone 16e, the new `brk #0xf00d` protocol); **no success report was found for 27.0.1**, only failure reports. **[verified / the 27.0.1 part is inferred]**
3. **For cross-compiling, add an iOS build directly on qemu-ios (QEMU 11.0.5); do not rebase onto utmapp/qemu (10.0.12).** When the upstream research doc said "rebase onto utmapp/qemu", qemu-ios was still QEMU 8.2; now it is three major versions newer than UTM. The pieces iOS needs (the TXM JIT buffer, the empty stub for `pthread_jit_write_protect_np` on iOS, the configure fixes for cross-compiling, the EAGL context) are all still in the qemu-ios main branch; only the build scripts were deleted, and they can be recovered from `af4d255637` and adapted. **[verified]**
4. **For graphics, EAGL (the system OpenGLES.framework) is the least effort: it is still in the iOS 27.2 SDK and on the real iPhone 18 Pro, exporting 457 gl functions.** But **nobody has yet made "snapshots with GL" work on any ES host** (EAGL, ANGLE and Android's EGL all register a migration blocker), and on 10-22 upstream's Mac version also found that "taps do nothing after restoring a snapshot". These two things bear directly on "switching versions at any time"; they are the biggest risk for M2, and M1 should get to the bottom of them first. **[verified]**
5. **People are working on it, but nobody has built what we want.** S5LBox (an interpreter written from scratch, only iPhone 3G 3.1.3, 0 to 4 fps) has been released; pocketTouch released a closed-source IPA that claims to run 1.x to 3.x, unverified; Inferno-iOS and Ios-emul run iOS 14 on iPhone (emulating an iPhone 11). **There is currently no publicly visible iPhone version that is based on qemu-ios, covers 1 to 7 and has JIT.** **[verified (GitHub and web searches as of 2026-11-01)]**
6. **For M1, try the iPhone 18 Pro first**, for the reasons in section 8; the iPhone 14 Pro runs second as the low-end baseline.

---

## 1. How far upstream's August attempt at an iPhone host got

### 1.1 Timeline **[verified]**

| Date | Commit | Content |
|---|---|---|
| 07-30 | Repository created | Started from devos50/qemu-ios (QEMU 8.2) |
| 08-03 | [20577fdbbb](https://github.com/samhenrigold/qemu-ios/commit/20577fdbbbd9) | Wrote the feasibility study `docs/research/ipod-touch-2g-on-iphone.md`: measured on the Mac, TCI is 3.3 to 5.2 times slower than JIT; conclusion "feasible"; the real obstacle is that JIT has to be re-enabled by a third-party tool on every launch |
| 08-04 | [74e9ca7934](https://github.com/samhenrigold/qemu-ios/commit/74e9ca793442) | Whole rebase onto QEMU v10.0.2 (the same version as UTM at the time) |
| 08-04 | [49f0804cb7](https://github.com/samhenrigold/qemu-ios/commit/49f0804cb70a) | "Shimmying things around for an iOS port????": added `build-ios-sim.sh`, `gles-host-stub.c` |
| 08-04 | [d14b8cc839](https://github.com/samhenrigold/qemu-ios/commit/d14b8cc839a8) | "iOS not-really-JIT JIT helpers": added the whole `contrib/ios-app/` set (`build-ios.sh`, `make-dylib.sh`, `embed-qemu.sh`, `install-images.sh`, `lldb_jit.py`, `qemu-ios-entry.c`, `qemu-ios-ui.c/h`), added the iOS 26 TXM path to `tcg/region.c`, added `needs_exe_wrapper` for cross-compiling to configure |
| 08-05 15:27 | [01ae922092](https://github.com/samhenrigold/qemu-ios/commit/01ae922092d37d029f42427f7aa50025fc6d2a9b) | "TCG experiments, dead end.": +8491 lines, see 1.3 |
| 08-05 | [LightTouchMac 70534953](https://github.com/samhenrigold/LightTouchMac/commit/70534953) | "Native AppKit front-end embedding qemu-ios as an in-process dylib": the Mac version is born |
| 08-05 20:51 | [7615017fe7](https://github.com/samhenrigold/qemu-ios/commit/7615017fe7fe) | `contrib/macos-app/make-dylib-macos.sh`: "contrib/ios-app is reused unchanged" |
| 08-06 | [dd93107e64](https://github.com/samhenrigold/qemu-ios/commit/dd93107e6446) | Snapshot ABI for ios-app (save2/status/resume), later reused by the Mac version |
| 10-07 | [b18cd1606c](https://github.com/samhenrigold/qemu-ios/commit/b18cd1606c9c) | Ported to QEMU 11: kept "the iOS JIT buffer path in region.c"; TCTI was not ported because QEMU 11 changed the backend interface |
| 10-08 | [74759924a1](https://github.com/samhenrigold/qemu-ios/commit/74759924a121) | Deleted TCTI ("It never built on QEMU 11") |
| 10-13 | [6a9aacff4b](https://github.com/samhenrigold/qemu-ios/commit/6a9aacff4b89) | Deleted "Dead contrib tools": 5 iOS host scripts; `qemu-ios-entry.c` and `qemu-ios-ui.c/h` were kept because the Mac dylib still uses them |

### 1.2 Did it run on a real device: yes **[verified, evidence from code comments]**

- `embed-qemu.sh` (the version before deletion, see [contrib/ios-app at af4d255637](https://github.com/samhenrigold/qemu-ios/tree/af4d25563788929799725b626c3c2f644bbeb58b/contrib/ios-app)): "a rebuilt emulator was never re-copied, so the phone quietly went on running the previous build", which shows it was run on the phone repeatedly.
- `install-images.sh`: uses `xcrun devicectl device copy to` to copy the roughly 520 MB packed NAND, bootrom, NOR and iBoot into the Documents folder of the app (Bundle ID `gold.samhenri.LightTouch`).
- The comment in `embed-qemu.sh` in the dead-end commit: TCTI "measured on device it was within 1% of the plain interpreter on this workload (104.0 vs 104.9 CPU-seconds …) while costing 322 MB of gadget tables".
- `tcg/region.c` (still in the main branch today): "measured on an A19: rx and rwx both map fine with CS_DEBUGGED unset", i.e. the author's test device was an A19 (iPhone 17 series) on iOS 26.
- `lldb_jit.py`: an LLDB stop hook that, on receiving `brk #0x69`, reads the code region out and writes it back, "That write is what makes the kernel record the mapping as a legitimate debug region", which shows the JIT build ran under the Xcode debugger.
- `gles-host-eagl.c`: the EAGL context + IOSurface color attachment are already written, and the comments contain readback formats measured on a real device ("Measured against a red triangle").
- `qemu-ios-ui.c`: adds logic to stop GL calls on foreground/background switches, save a snapshot when going to the background and restore it when returning to the foreground, all of which only an iOS app lifecycle needs.

The research doc says at the top "nothing was built from it", which contradicts the commit history above; the doc was written on 08-03 and the code on 08-04/05, and the doc was later only tidied up, without updating this passage.

### 1.3 Why it is called "dead end": performance, and the author concluded the release build would have no JIT **[verified]**

Almost everything the dead-end commit adds is an experiment to "make the pure interpreter a bit faster":

| Experiment | File | Conclusion in the comments |
|---|---|---|
| UTM's TCTI backend | `tcg/aarch64-tcti/` (including the 1026-line README brought over from UTM) | Only 1% away from TCI on a real device, and needs 322 MB of gadget tables; not bundled by default |
| PGO and other compiler optimizations | `build-ios.sh` | `-O3`, LTO and `-mcpu` are all within noise; only PGO is faster, by 13.7% |
| A comparison switch that turns off goto_ptr | `tcg-accel-ops.c` | TCTI does not support goto_ptr, so every ARM `bx lr` has to go back to C for a table lookup |
| HLE of guest functions by virtual address | `target/arm/tcg/it-hle.c` | "there will never be a native JIT in the shipping app and the TCG interpreter is roughly 30x slower than one" |
| Longer guest timers | `ipod_touch_timer.c` | "Under an interpreter that is roughly a tenth of real speed", the guest is flooded by timer interrupts |
| Lower panel vsync | `ipod_touch_lcd.c` | "under an interpreter the guest may only manage one or two frames a second" |
| Guest/vCPU sampling profiler | `cpu-exec.c` etc. | Used to find what to HLE |

So the point of failure is **performance**: the author's premise was "the release app can only use the interpreter" (JIT is only available with the debugger attached; `build-ios.sh` says "development-only"), and under the interpreter the iPod touch 2G's 3.1.3 runs at only about a tenth of real speed with one or two fps in the UI, and none of the speedups rescued it. It was not a build failure (the dylib, embedding and image copying all worked), not a graphics failure (the EAGL path was written), and not "JIT is impossible" (it worked under the debugger).

Two numbers need to be kept apart: on the Mac, measured in boot CPU seconds, TCI is 3.3 to 5.2 times slower than JIT (research doc); the dead-end code comments say the interpreter is about 30 times slower, about a tenth of real speed (interactive use). M0 is measuring JIT and the pure interpreter on the Mac right now; decide once its data is in. **[both numbers verified as upstream's own words; which one is closer to the real interactive experience is inferred]**

Also, the "Scope" section of the upstream README states explicitly that there will be no iOS version and that requests will be closed ([LightTouchMac README](https://github.com/samhenrigold/LightTouchMac#scope)). So this is both "performance did not work out" and a choice of direction after the author moved to the Mac; he never touched the iPhone host again, and in October deleted the scripts as "Dead contrib tools".

### 1.4 What is left in the main branch after the deletion that can be used directly **[verified]**

- The iOS 26 TXM path in `tcg/region.c`: first map RX; with a debugger present, `brk #0x69` asks the debugger to prepare it; then switch the write alias to RW. With no debugger it fails right away with "jit needs an attached debugger on this OS", so that the upper layer can fall back to the interpreter. The code matches [UTM's region.c](https://github.com/utmapp/qemu/blob/utm-edition/tcg/region.c).
- `include/qemu/osdep.h`: on iOS, `qemu_thread_jit_write/execute` are no-ops (the iOS SDK does not export `pthread_jit_write_protect_np`).
- `configure`: when cross-compiling, probes whether target programs can be run, and if not, writes `needs_exe_wrapper = true`.
- `hw/arm/gles-host-eagl.c` (296 lines) and the `host_gles` dependency in `meson.build` (OpenGLES, Foundation, IOSurface, CoreFoundation); `hw/arm/meson.build` automatically builds the EAGL version when OpenGL is missing but OpenGLES is present.
- `contrib/ios-app/qemu-ios-entry.c`, `qemu-ios-ui.c/h`: the C ABI for the host app (`qemu_ios_main`, frame callback, touch, keys, input sequences, foreground/background, snapshot save2/status/resume), which the Mac version has used and maintained all along.
- The deleted `build-ios.sh`, `make-dylib.sh`, `embed-qemu.sh`, `install-images.sh` and `lldb_jit.py` can be read back from `af4d255637` and adapted.

---

## 2. Cross-compiling

### 2.1 How UTM builds **[verified]**

[`scripts/build_dependencies.sh`](https://github.com/utmapp/UTM/blob/main/scripts/build_dependencies.sh):

- Platform `-p ios|ios-tci|ios_simulator…`, `-a arm64`, minimum iOS 15; each dependency is cross-compiled with `xcrun --sdk iphoneos` plus `-target arm64-apple-ios15.0` and installed into `sysroot-iOS-arm64`.
- Dependencies ([patches/sources](https://github.com/utmapp/UTM/blob/main/patches/sources)): pkg-config, libffi, libiconv, gettext, libpng, libjpeg-turbo, glib 2.83, libgpg-error, libgcrypt, pixman 0.38, OpenSSL 1.1.1b, libtpms/swtpm, opus, zstd, spice, libusb, usbredir, libslirp 4.9.1, libucontext, plus the GPU-related ANGLE (extracted from WebKit), virglrenderer, MoltenVK and so on.
- QEMU uses utmapp/qemu's `v10.0.12-utm`, with these options on iOS: `--enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext --enable-hvf-private`; the `ios-tci` platform adds `--enable-tcg-threaded-interpreter` on arm64 (TCTI, for UTM SE on the App Store).
- `--enable-shared-lib`, the `libucontext` coroutines and TCTI were all added by utmapp/qemu itself; upstream QEMU does not have them.

### 2.2 How upstream built in August (`build-ios.sh`, the version before deletion) **[verified]**

- The dependencies come straight from the sysroot produced by UTM's CI ("the dependency sysroot is UTM's prebuilt CI artifact").
- `configure --cross-prefix= --cpu=aarch64 --cc="clang -isysroot $SDK -target arm64-apple-ios16.0" … --target-list=arm-softmmu --with-coroutine=sigaltstack --enable-slirp --audio-drv-list= --disable-coreaudio --disable-hvf --disable-cocoa --disable-sdl … --disable-tools --disable-plugins --disable-opengl`, adding `--enable-tcg-interpreter` when `TCG=interp`.
- Instead of `--enable-shared-lib`, `make-dylib.sh` grabs the ninja command that links `qemu-system-arm`, swaps `system/main.c` for `qemu-ios-entry.c`, and relinks into `libqemu-arm-{jit,interp}.dylib`, exporting only `qemu_ios_*`. The Mac version's `make-dylib-macos.sh` still uses this idea today.
- The app ships both a JIT dylib and an interpreter dylib, and picks one at launch depending on whether a debugger is present.

### 2.3 What qemu-ios needs beyond what UTM has **[verified; the iOS column is partly inferred]**

Based on: [qemu-ios meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/meson.build), [hw/arm/meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/meson.build), and LightTouchMac's [dependencies.json](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/dependencies.json) and [build-package-native.sh](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/recipes/build-package-native.sh).

| Dependency | Where qemu-ios uses it | What to do on iOS |
|---|---|---|
| libslirp 4.9.4 + two patches (`libslirp-set-restricted.patch`, `libslirp-guestfwd-connector.patch`) | Guest networking, `lan=off`, guestfwd | When no patched version is found, meson automatically builds it statically as a subproject, so cross-compiling should be able to reuse that **[inferred]**; UTM's 4.9.1 lacks these two patches |
| OpenSSL libcrypto (static) | `ipod_touch_aes.c` uses `<openssl/aes.h>`, `ipod_touch_pke.c` uses `<openssl/bn.h>` | The UTM sysroot has 1.1.1b; LTM uses 3.6.3. Cross-compiling OpenSSL for iOS is a mature process |
| QEMU's own cipher (LTM uses nettle) | `s5l8930_cdma.c` goes through `crypto/cipher.h` | UTM has gcrypt; or use QEMU's built-in AES **[inferred, needs a build to verify]** |
| FFmpeg 9.0.1 + qemu-ios's two H.264 patches, with only the aac/mp3/alac/h264 decoders enabled | H.264 video and raw AAC on iPod touch 2G | Optional, only a warning when missing; LGPL, can be cross-compiled for iOS; M1 can skip it at first |
| VideoToolbox, CoreMedia, CoreVideo, IOSurface | Video decoding, GL surfaces | All present on iOS |
| glib, pixman, zlib | QEMU basics | The UTM sysroot has them; zlib comes with the system |
| libimobiledevice, libplist, usbmuxd fork, libtatsu, libusb | LTM side: installing apps on the emulated device, AFC, firmware restore | Not linked into QEMU; iOS cannot start a usbmuxd daemon, see 2.4 |
| ANGLE | Experimental renderer | Optional, see section 4 |

### 2.4 macOS-only code and how to replace it on iOS **[current state verified; handling is a suggestion]**

| Component | Current state on the Mac | Handling on iOS |
|---|---|---|
| Cocoa UI (`ui/cocoa.m`) | LTM builds with `--enable-cocoa` | `--disable-cocoa`. Display goes through the frame callback of `qemu_ios_ui_attach`, and the app draws to a CALayer / Metal itself |
| CGL (the CGL part of `gles-host.c`) | Default renderer | The iOS SDK has no OpenGL.framework, so under `TARGET_OS_IPHONE` it automatically takes the EAGL path; M1 can also do without host GL entirely at first (see section 4) |
| CoreAudio (`audio/coreaudio.m`, which uses macOS's AudioObject HAL device API) | `--enable-coreaudio` | iOS has no such device API: `--disable-coreaudio --audio-drv-list=`. No sound in M1; in M2 use noaudio's `IT_AUD_RT` real-time PCM tap or the audio capture interface, and hand it to AVAudioEngine / RemoteIO |
| usbmuxd fork + `tcp_usb` (`-M …,usb-tcp-addr=`) | LTM starts a usbmuxd process connected to QEMU's tcp_usb, then uses libimobiledevice to install apps, transfer files and restore | iOS cannot start child processes or daemons. M1 does not set `usb-tcp-addr`; M2/M3 either implement a usbmux in-process, or switch to a guest agent + slirp guestfwd (S5LBox installs apps over a "virtual USB") |
| Helper process, XPC, sandbox extension (LTM's HostRuntime) | On the Mac, one helper process per device | On iOS the dylib runs in-process. The `qemu-ios-entry.c` comment: "QEMU is not designed to be started twice in one process … One VM per app launch, as in UTM". Switching versions means either restarting the app or using an iOS 26 ExtensionKit extension process (UTM already uses one to run qemu-img, [PR #7908](https://github.com/utmapp/UTM/pull/7908)) |
| `pthread_jit_write_protect_np` | Only on macOS | `osdep.h` already has an empty stub for iOS |
| Darwin kqueue poll, `file-posix` hole punching | Generic Darwin | iOS also has kqueue and fcntl, expected to build **[inferred]** |
| vmnet, libusb passthrough, HVF | Mac | All off |
| FirmwareKit (Swift, used to build devices) | Declared for macOS, but already has Linux/Windows/Android conditional branches; starts an iBoot32Patcher child process | A matter for M3: the child process has to become a linked library |

### 2.5 How far apart the versions are, and which route to take **[version numbers verified, the suggestion is inferred]**

- The qemu-ios main branch `VERSION` is **11.0.5**; utmapp/qemu's `utm-edition` is **10.0.12** (UTM main uses `v10.0.12-utm`, released 2026-07-27). Three major versions lie between them: 10.1, 10.2 and 11.0. qemu-ios only moved from the 10.0.2 line to 11.0.3 on 10-07, and the old line is no longer maintained.
- The upstream research doc's advice to "rebase onto utmapp/qemu" was a judgment made in early August, when qemu-ios was still on 8.2, and is now outdated.
- The only things really worth borrowing from UTM are: (1) the TXM JIT buffer, which qemu-ios already has; (2) possibly the libucontext coroutines (see below); (3) the cross-compiling scripts for the dependencies. `--enable-shared-lib` can be replaced by relinking, and TCTI is not worth having (see 3.2).
- **Suggestion: add an iOS build directly on qemu-ios's QEMU 11**, with the changes kept in `patches/`. Rebasing back to 10.0.12 would throw away all of qemu-ios's porting and fixes since October, a cost far greater than adding a few iOS conditional compiles ourselves.

There is one disagreement about the coroutine backend that M1 has to test: upstream's August iOS build used `--with-coroutine=sigaltstack` and ran on a real device; but the README of [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) says "iOS has no usable `sigaltstack`" and so it uses ucontext (libucontext is among its dependencies), and UTM also uses libucontext. QEMU 11's `coroutine_backend` option has only ucontext / sigaltstack / windows / wasm. Try sigaltstack first, and if it does not work, bring over UTM's libucontext patch (a small change). **[the disagreement itself is verified, the conclusion awaits testing]**

### 2.6 Precedents of "QEMU built as an iOS library" to refer to **[verified]**

- [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) (GPL-3.0, 155 stars): using Xcode 27.0 and the iOS 27 SDK, it builds ChefKiss's QEMU fork with `meson … -Dshared_lib=true -Dcoroutine_backend=ucontext` into `libqemu-aarch64-softmmu.dylib`, with the dependencies glib, pixman, libslirp, libucontext, lzfse, libpng, gmp, nettle, libtasn1; the README says the default TB buffer is 128 MB, giving 8 to 11 fps at 64 MB and 21 to 25 fps at 256 MB.
- [Ios-emul](https://github.com/vytska69/Ios-emul) (in Lithuanian, based on QEMUAppleSilicon): has a full iOS patch set, and its [`0016-ios-txm-jit-via-stikdebug.patch`](https://github.com/vytska69/Ios-emul/blob/claude/ipsw-emulator-app/qemu/patches/inferno/0016-ios-txm-jit-via-stikdebug.patch) is exactly the implementation of the new TXM protocol that we need.

---

## 3. Execution mode

### 3.1 QEMU 11's TCI still works on aarch64 **[verified]**

- The qemu-ios main branch's `tcg/tci/` is complete, and `meson_options.txt` has `tcg_interpreter`; turning it on for a host with a native backend only prints a "not recommended" warning.
- QEMU 11's `docs/about/deprecated.rst` and `removed-features.rst` do not deprecate TCI; what 11.0 removed was 32-bit hosts. The wasm64 host added in QEMU 11 has to use TCI, which shows TCI is still maintained.
- For performance see 1.3: on the Mac, 3.3 to 5.2 times slower in boot CPU seconds; in upstream's interactive use on a real device, about a tenth of real speed and one or two fps.

### 3.2 State of UTM's TCTI: not worth the effort **[verified]**

- The last two TCTI changes in utmapp/qemu are from 2025-07, "update to support QEMU v10.0" and "implement vector immediate shifts" ([commit list](https://github.com/utmapp/qemu/commits/utm-edition/tcg/aarch64-tcti)), and it only supports the 10.0 backend interface.
- qemu-ios explicitly did not port it when moving to QEMU 11 on 10-07 ("targets the 10.0 backend interface, which v11 replaced"), and deleted it on 10-08.
- Upstream's real-device measurement: for this workload TCTI and TCI differ by 1%, and TCTI costs 322 MB more. One reason is that TCTI does not support goto_ptr, so ARM guests have to go back to C for a table lookup on every function return.
- Conclusion: do not port TCTI. Speedups for the no-JIT case should be spent elsewhere (PGO gives 13.7%, and the various TB layout optimizations in the blake-lucas fork also help under JIT).

### 3.3 How JIT is enabled on iOS 26/27 **[verified]**

**Background**: third-party apps cannot get `dynamic-codesigning`, so the `MAP_JIT` route does not work. The old method was to sign with `get-task-allow` and let a debugger attach; once the process had `CS_DEBUGGED` it could `mprotect` executable pages by itself. From iOS 26 on, this no longer works on devices with TXM (Trusted Execution Monitor): a process can no longer mark its own pages executable, and the debugger has to "prepare" each executable region.

**Which devices count as TXM** (StikDebug's [`ProcessInfo+TXM.swift`](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/ProcessInfo%2BTXM.swift)):

- iOS 26: an iPhone model number ≥ 14.2 (A15 and later) counts as TXM.
- iOS 27: **everything** except iPad8,11/8,12 is treated as TXM (DolphiniOS specifically fixed JIT for A13/A14/M1 on the iOS 27 beta, see the [builds.io guide](https://builds.io/blog/technologies/ios-technologies/how-to-enable-jit-on-iphone/)).

**Two protocols** ([StikJIT INTEGRATION.md](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md), [universal.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/universal.js), [legacy.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/legacy.js)):

| | Old protocol (legacy.js) | New protocol (universal.js, officially recommended) |
|---|---|---|
| App-side trap | `brk #0x69`, x0 = address, x1 = length | `brk #0xf00d`, x16 = command (1 = prepare region, 0 = detach, 2 = send script), x0/x1 = address/length |
| Debugger side | Handles `brk #0x69` **once**, then detaches automatically | Loops until the app itself sends "detach"; when the address passed is 0, debugserver allocates the RX region on its behalf |
| Who uses it | UTM, DolphiniOS, Flycast, Inferno-iOS; **qemu-ios's current region.c too** | MeloNX, touchHLE, Husk, etc.; Ios-emul |
| Notes | universal.js returns the error code `0xE0000069` right away when it receives `0x69` | Requirements: wait for `CS_DEBUGGED` to appear before trapping, or the process crashes; prepare all RX regions in one go before detaching |

QEMU allocates a single code buffer, only at initialization, so either protocol is enough.

**Which one UTM uses**: UTM uses legacy.js (StikDebug assigns it automatically by app name, see [AutoScriptAssignments.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/AutoScriptAssignments.swift)). UTM's [iOS.entitlements](https://github.com/utmapp/UTM/blob/main/Platform/iOS/iOS.entitlements) has only `extended-virtual-addressing`, `increased-memory-limit` and an App Group; JIT relies on the `get-task-allow` that comes with development signing plus an external debugger, and `CS_DEBUGGED` is checked with `csops` ([UTMJailbreak.m](https://github.com/utmapp/UTM/blob/main/Services/UTMJailbreak.m)).

**What our app needs**:

- Entitlements: `get-task-allow` (comes with development signing; both free and paid accounts have it); adding `increased-memory-limit` is recommended; `extended-virtual-addressing` is not needed for a 32-bit guest.
- Code: `region.c` already has the TXM path. Suggest switching it to the new protocol (referring to Ios-emul's 0016 patch): at app launch, while the debugger is still attached, prepare the code region and then detach; with no debugger, automatically use the interpreter dylib.
- Runtime: the device has **Developer Mode** on; StikDebug needs a pairing file, LocalDevVPN from the App Store, and the Developer Disk Image (DDI) mounted; our app's name is not in StikDebug's automatic assignment table, so the user has to long-press the app in StikDebug and pick "Assign Script" manually (this is how Inferno-iOS has users pick legacy.js), and **the app has to be launched from StikDebug**; opening it yourself first and then attaching fails (the maintainer's reply in [#476](https://github.com/StikDebug/StikDebug/issues/476)).

**Four ways to get JIT**:

| Method | Suited for | Notes |
|---|---|---|
| Run directly from Xcode + LLDB stop hook | M1 development | The approach of upstream's `lldb_jit.py`, tethered to the computer; no StikDebug needed |
| StikDebug (AGPL-3.0) + LocalDevVPN | Use away from the computer | The user installs one more app; every launch has to be started from StikDebug |
| Embedded StikJIT (an MPL-2.0 XCFramework) | Improving the experience later | Has to live in an app extension (a process cannot debug itself), and the user has to import a pairing file; under a free account the extension also takes an App ID |
| TrollStore / AltJIT | Not considered | TrollStore has been gone since after 17.0.1; AltStore Classic's Enable JIT needs AltServer on a computer |

### 3.4 The two test devices: both TXM, same plan

| | iPhone 18 Pro | iPhone 14 Pro |
|---|---|---|
| Chip / RAM | A20 Pro / 12 GB ([Wikipedia](https://en.wikipedia.org/wiki/IPhone_18_Pro)) | A16 / 6 GB |
| Model number | iPhone19,2 (the name of the device symbol cache directory in the local Xcode) | iPhone15,2 |
| System | iOS 27.2 (the build number recorded in the local cache is 24B5110a, which looks like a beta build number; need to confirm whether it is now the release) | iOS 27.0.1 |
| TXM? | Yes (iOS 27 treats all devices as TXM) | Yes (already from iOS 26: 15.2 ≥ 14.2) |
| JIT mechanism | The debugger prepares regions; the same code | Same as left |
| Known StikDebug issues | DDI mounting failed on the iPhone 18 Pro series, fixed in 3.1.11 (09-23) by switching to cryptex mounting; on 27.2 there is a report of the tunnel failing to come up, in the end attributed to an old pairing file | On 27.0.x there are reports such as "attach failed E96" and "Husk stuck at attach", which the maintainer mostly attributed to usage problems; no success report found |
| Hardware differences relevant to this project | From A19 on there is MIE (memory tagging), not enabled for third-party apps by default, so it does not affect JIT **[inferred, based on [8ksec](https://8ksec.io/mie-deep-dive-enabling-apps/)]**; the CPU is clearly faster | Half the memory, noticeably slower single-core **[inferred]** |

### 3.5 Public reports of JIT on iOS 27 releases

| Source | System / device | Result | Assessment |
|---|---|---|---|
| [Ios-emul docs/status.md](https://github.com/vytska69/Ios-emul/blob/claude/ipsw-emulator-app/docs/status.md) | **iOS 27.2**, iPhone 16e (A18), StikDebug, new protocol | The QEMU-emulated iPhone 11 reached the home screen and could open Settings | **Success** **[verified as the author's claim]** |
| [StikDebug 3.1.11 release notes](https://github.com/StikDebug/StikDebug/releases) | iPhone 18 Pro series | Fixed DDI mounting | Adapted at the tool level |
| [StikDebug #471](https://github.com/StikDebug/StikDebug/issues/471) | iOS 27.2 / 27.0 | Tunnel failure, solved by deleting the app and replacing the pairing file | Configuration problem |
| [StikDebug #476](https://github.com/StikDebug/StikDebug/issues/476), [#491](https://github.com/StikDebug/StikDebug/issues/491) | iOS 27.0 / 27.0.1 | Attach failed, the app reports JIT not enabled | Closed by the maintainer as "not planned / user error" |
| [Husk #183](https://github.com/Leviidev/Husk/issues/183) | iOS 27.0.1, iPhone 15 | Stuck at attach, several people chimed in, still open | Failure (cause unknown) |
| [Inferno-iOS #8](https://github.com/MakrSas/Inferno-iOS/issues/8) | iOS 27 RC, iPhone 17 | No longer crashes, but hangs before the Apple logo | Uncertain |

Conclusion: **27.2 has one public record of a QEMU-type app succeeding; 27.0.1 has none.** JIT on iOS 27 is "supported by the toolchain and occasionally works", but every link (pairing file, VPN, DDI, script assignment, launch order) can go wrong, and every iOS update may break it again. M1 has to test on both devices. **[inferred]**

---

## 4. Graphics

### 4.1 OpenGLES.framework in the local SDK and on the real device **[verified]**

- `iPhoneOS27.2.sdk/System/Library/Frameworks/OpenGLES.framework` is still there: under `Headers/` are `EAGL.h`, `EAGLDrawable.h`, `EAGLIOSurface.h`, `ES1/`, `ES2/`, `ES3/`; `OpenGLES.tbd` exports 486 symbols, of which **457 are `gl*`**, plus the ObjC classes `EAGLContext` and `EAGLSharegroup`. The ES1 fixed pipeline is all there (`glMatrixMode`, `glOrthof`, `glLightfv`, `glTexEnvf`, `glDrawTexfOES`, `glGenFramebuffersOES`, etc.).
- Every API in the headers is marked `OPENGLES_DEPRECATED(ios(2.0, 12.0))`, i.e. deprecated since iOS 12, but none is marked unavailable; `texImageIOSurface:` (since iOS 11) is also still there.
- In the local `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2 27.2 (24B5110a)/`, the iPhone 18 Pro's real `OpenGLES` binary likewise exports **457 `gl*`**, and also comes with `GLEngine.bundle` (GL on iOS today actually runs on top of Metal).
- One surprise: `glGetTexImage` is **exported in both the tbd and the real binary, but is not in the headers**. The CGL snapshot code depends on exactly this function to read textures back. Whether it works on iOS, and whether it behaves correctly, is completely unknown **[inferred; worth probing in M1 along the way]**.
- The upstream research doc checked against an iPhone 17 + the iOS 26.5 SDK at the time, also 457, consistent with today.

### 4.2 The EAGL route

Pros:
- The guest's API is the host's API (ES 1.1 / 2.0), so no fixed-pipeline emulation or shader translation is needed; the "ES host" conditional branches in `gles-host.c` (`GLES_HOST_EAGL`) have been maintained all along in October because of the ANGLE work (the ANGLE version also defines `GLES_HOST_EAGL`).
- No library to bundle, so the app stays small; IOSurface color attachments avoid per-frame `glReadPixels`.
- UTM's iOS version also has an "EAGL backend" (the [v5.0.3 release notes](https://github.com/utmapp/UTM/releases) fixed a black screen at boot with it), which shows the system OpenGLES is still used by other projects on iOS. Whether that goes through ANGLE's GL backend I have not verified **[inferred]**.

Cons:
- Apple deprecated it in iOS 12, and it could be removed at any time (it has already lingered for 7 years).
- `gles-host-eagl.c` has had no substantial updates since 08-05: **it only creates ES 1.1 contexts**; after iOS 4 the CoreAnimation compositor needs an ES 2.0 context, so contexts have to be created per API version, the way the ANGLE version does it.
- Apple's rule is that "all contexts in the same sharegroup must use the same API version as the first context" ([OpenGL ES Programming Guide](https://developer.apple.com/library/ios/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/WorkingwithOpenGLESContexts/WorkingwithOpenGLESContexts.html)). ANGLE accepts mixing, EAGL does not. Back then the guest ran on real iOS under the same rule, so most likely it does not mix **[inferred]**.
- 3.1.3's CoreAnimation uses `GL_TEXTURE_RECTANGLE`, a target that ES does not have; the ANGLE version already has an adaptation layer that "treats rectangle textures as 2D textures" (`gles-host-angle.c.inc`), which EAGL has to reuse or rewrite.

### 4.3 The ANGLE (Metal) route

Pros:
- Based on Metal, so it is not affected by the OpenGLES deprecation; since 10-21 upstream can have CoreAnimation composite entirely through ANGLE on k48ap 7B500, n81ap 10B500 and n90ap 11D257, with zero rejections ([angle-evaluation.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/angle-evaluation.md)).
- UTM's iOS version uses ANGLE, so there is precedent.

Cons:
- ANGLE has to be bundled (6 dylibs, about 11.6 MB; the full build tree is about 8.7 GB), and the iOS version needs a separate build; upstream has only built it on the Mac, and there it is an "experimental renderer next to CGL", whereas iOS has no CGL to fall back on.
- n72ap 7E18 (3.1.3) still cannot boot on ANGLE (the rectangle texture problem; the doc's 10-21 section says an adaptation was added, but gives no retest result).

### 4.4 Impact on "saving GL state in snapshots": equally hard on both routes **[verified]**

- Current state: only **CGL** can save snapshots that include GL ([1c974f183c](https://github.com/samhenrigold/qemu-ios/commit/1c974f183c23), `gles-host-snapshot.c.inc`). It depends on "a legacy desktop context that has both the fixed and the programmable pipelines", `glGetTexImage` and `glGetTexLevelParameteriv`.
- EAGL: under `GLES_HOST_EAGL`, `gles_begin_context()` registers a migration blocker as soon as there is a live GL context: "Live OpenGL ES state cannot be saved (including accelerated system UI)". ANGLE registers one too. So does the Android EGL host in the blake-lucas fork ([gles-host.c around line 612](https://github.com/blake-lucas/qemu-ios/blob/main/hw/arm/gles-host.c)). **In other words, nobody has yet made snapshots with GL work on an ES host.**
- The to-do list in the ANGLE doc applies equally to EAGL: ES1 and ES2 contexts need their state captured and replayed separately; ES has no `glGetTexImage`, so color textures can be read back by binding them to an FBO, but alpha / luminance textures cannot be color attachments, so either keep a copy from upload time or draw them into RGBA and read that back; ES does not accept RGBA data passed into alpha/luminance storage of undefined size, so replay has to change too. EAGL's only possible shortcut is the private `glGetTexImage` mentioned in 4.1, unverified.
- Fallback: when the GL bridge refuses, the guest falls back to software CoreAnimation compositing (stub comment: "a guest probing the HLE simply falls back to its software renderer"; the iPod touch 2G class of devices also has an MBX2D model that can composite, and with the GL shim off upstream measured a 107 MB snapshot and a 0.11 second restore, see [MBX commit 103d076b09](https://github.com/samhenrigold/qemu-ios/commit/103d076b09c3)). Software compositing is slow, but with no GL context there is no migration blocker. Whether every version can go through software compositing smoothly needs testing **[inferred]**.
- Two other snapshot-related problems that have nothing to do with graphics:
  - **QEMU can be started only once per process**, so on iOS "switching versions" means "save a snapshot → exit → restore in a new process with `-incoming`".
  - Upstream's Mac version measured on 10-22: after restoring with `-incoming` in a new process, the picture moves and the agent responds, **but no taps have any effect** ([LightTouchMac 3f39d80d](https://github.com/samhenrigold/LightTouchMac/commit/3f39d80d), n72ap 3.1.3, "until it is fixed, checks keep cold boots"). As of upstream's last commit on 10-23 it is still not fixed. "Save and keep running" within the same process does work.

### 4.5 Suggestions

- For M1's first boot, **do without host GL at first** (use the stub or have the GL bridge refuse) and go through software compositing, so that "can it boot" and "is GL correct" are verified separately, and snapshots stay usable.
- Then bring up EAGL, add the ES 2.0 context, and reuse the ANGLE version's adaptations for rectangle textures and for choosing OES names by API version. Compared with ANGLE, EAGL means one less big dependency to build, bundle and maintain on iOS.
- Snapshots with GL are a separate M2 work package; EAGL and ANGLE take about the same work there, so ANGLE should not be chosen because of snapshots.
- Keep ANGLE as the fallback for when OpenGLES is removed; `gles-host.c` can already build both, so just keep it compatible.

---

## 5. Signing and resources

### 5.1 Free Apple ID vs paid developer account

| | Free Apple ID (Personal Team) | Paid (99 USD/year) |
|---|---|---|
| Signature validity | 7 days, then re-sign (SideStore can renew on the phone) | 1 year |
| Apps installed at once | 3 (widely stated by third-party sources, not verified in Apple's docs): SideStore + StikDebug + our app fill it exactly | No such limit |
| App IDs | At most 10 at a time, each expires after a week; each app extension takes one ([AltStore FAQ](https://faq.altstore.io/altstore-classic/app-ids)) | No such limit |
| `get-task-allow` | Yes (development signing) | Yes (development signing) |
| `increased-memory-limit` | Works when installed directly from Xcode and with AltStore Classic 2.2 and later; **lost when SideStore signs with a free account** ([SideStore #1616](https://github.com/SideStore/SideStore/issues/1616), unfixed since 2026-09) | Yes |
| `extended-virtual-addressing` | Uncertain **[inferred]** | Yes; we do not need it |
| JIT | The same, both rely on an external debugger | The same |

For M1 development: the user installs directly to the phone from Xcode with their own account, and a free account is enough (re-run from Xcode every 7 days). For release later: each user signs with their own account, the account type is up to the user, and the app has to run even with a free account and with SideStore dropping the entitlement.

### 5.2 Is the per-app memory limit enough

- Known data points: iPhone 15 Pro Max (8 GB, iOS 27.0) about 3.3 GB by default, about 6 GB with `increased-memory-limit` (measured in SideStore #1616); the 12 GB iPhone 16/17 Pro Max about 6144 MB with that entitlement ([Apple Developer Forums](https://developer.apple.com/forums/thread/834805)); Inferno-iOS says it "gets killed at 3 GiB" **[third-party claim]**. No number found for iPhone 14 Pro (6 GB); estimated at 2.5 to 3 GB by default **[inferred]**.
- Estimate for an iPhone 4 guest **[inferred]**: guest memory 512 MB; the TCG code buffer defaults to **1 GiB** (`DEFAULT_CODE_GEN_BUFFER_SIZE`, counted by the pages actually used); the GL bridge caps guest GL objects at 512 MiB (`GLES_MAX_GPU_BYTES`; memory is unified on iOS); framebuffers, snapshot buffers, glib and so on take a few hundred MB. The worst case approaches 2 to 2.5 GB.
- Conclusion: the iPhone 18 Pro has plenty; the iPhone 14 Pro may be close to the edge without the entitlement. Suggest setting `tb-size` to 256 to 512 MB on iOS (Inferno's data shows a TB that is too small drops frames, and blake-lucas measured the code cache at about 400 MB after boot), adding `increased-memory-limit`, and measuring with `os_proc_available_memory()` on both devices in M1. Under TXM the debugger has to "prepare" the whole code region, and the bigger the region, the slower the preparation, which is another reason to shrink `tb-size` **[inferred]**.

---

## 6. Is anyone else already doing the iPhone side

| Project | What it is | Relation to us |
|---|---|---|
| [S5LBox](https://github.com/j0shua-SYSON/S5LBox) (MIT, 60 stars, v1.0 released 10-14, v1.1 on 10-19) | An S5L8900/ARMv6 full-system emulator **written from scratch** that runs the iPhone 3G's iPhone OS 3.1.3 on an ordinary iPhone; pure interpreter, needs no special entitlements; has Legacy Store, Cydia, save and restore | The closest competitor, but only one machine and one version; says itself "not 30 fps", and foreground interaction is often at 0 to 4 fps ([README-DETAILED](https://github.com/j0shua-SYSON/S5LBox/blob/main/docs/README-DETAILED.md)) |
| [pocketTouch](https://github.com/landonjsmith/pocketTouch) | On 10-20 released a 441 MB closed-source IPA and an AltStore source, claiming "Run iPhone OS 1 to iOS 3 on your iPhone"; an unofficial port of Light Touch that uses AltStore's Enable JIT; no source code in the repository | Claims to have done it, but whether it runs is unverified (the release page shows 1 download); a GPL derivative that does not provide source |
| [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) (GPL-3.0, 155 stars) | QEMU (ChefKiss Inferno) emulating an iPhone 11, running iOS 14 on iPhone, StikDebug legacy.js | A different version range, but the technical route most like ours; its build and JIT handling are worth borrowing |
| [Ios-emul](https://github.com/vytska69/Ios-emul) | QEMUAppleSilicon, runs iOS 14 on iPhone; its status table lists iPod touch 1G/2G as "qemu-ios cannot be built into the IPA yet, macOS only" | Has an iOS 27.2 JIT success record; the author considered qemu-ios but did not do it |
| [blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch) (GPL-2.0, 87 stars) | Android/Linux/Windows/macOS version of qemu-ios | No iOS; but its performance docs and EGL host code are very valuable to us |
| [KD3533/qemu-ios-android](https://github.com/KD3533/qemu-ios-android) | Android version under Termux | Irrelevant |
| [heirofIsildur1/LightTouchMac](https://github.com/heirofIsildur1/LightTouchMac) | The description says "LightTouchMac for iOS. I haven't done any work on this yet", and it is identical to upstream | Just a placeholder |
| [c12n/nexttouch](https://github.com/c12n/nexttouch) | An empty repository created on 11-01; the description says it will do iOS 8 to 10, including an iOS platform | Empty |
| Reddit / social media | Nothing relevant found on r/LegacyJailbreak or r/emulation (not indexed by search engines; something may have been missed) | No public announcement found |

Conclusion: **as of 2026-11-01, no open-source project was found that is based on qemu-ios, covers iPhone OS 1 to iOS 7 and runs on iPhone.** The "first" spot is still open, but S5LBox has already claimed the "running 3.1.3 on iPhone" story, and pocketTouch claims to have done 1 to 3. The upstream author has explicitly ruled out an iOS version.

---

## 7. Risk list (from highest to lowest risk)

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **The JIT toolchain is unstable on iOS 27**: pairing file, LocalDevVPN, DDI, manual script assignment, having to launch from StikDebug; if any link fails it falls back to the interpreter, and each iOS update may break it again. No success report on 27.0.1 | Medium-high | High: without JIT there are only one or two fps, and "playable" cannot be reached | Use Xcode + LLDB for M1 development first; switch to the new protocol; test on both devices; consider embedding StikJIT later; build the interpreter version with PGO and keep it always bootable |
| 2 | **Instant snapshot switching cannot be made to work**: nobody has implemented snapshots with GL on an ES host; upstream's bug where taps fail after an `-incoming` restore is not fixed; QEMU can start only once per process, so switching versions needs an app restart, and under StikDebug JIT has to be obtained again | High | High (threatens the core selling point, M2) | In M1, first verify "save → exit → restore in a new process → taps work" with GL off; make the taps-dead-after-restore bug the first M2 work item; evaluate ExtensionKit extension processes |
| 3 | **The QEMU 11 tree fails to build or runs unstably on iOS**: the large amount of code added since August has never been built for iOS; the coroutine backend (sigaltstack or libucontext) is disputed | Medium | Medium (costs time) | Build the interpreter version for the iOS Simulator first for fast iteration; concentrate the changes into patches |
| 4 | **Apple removes EAGL, or it misbehaves**; `gles-host-eagl.c` supports only ES1 and needs ES2 and rectangle textures added | Medium-low (short term) | Medium | Boot without GL first; keep ANGLE buildable as a fallback |
| 5 | **Memory**: the iPhone 14 Pro's default limit is unknown; 1 GiB default code buffer + 512 MB guest + GL | Low-medium | Medium | `tb-size` 256 to 512 MB; `increased-memory-limit`; measure |
| 6 | **Signing and distribution experience**: the free account's 3 apps are filled exactly; SideStore with a free account drops `increased-memory-limit`; re-sign every 7 days | Medium | Low (does not block technical validation) | Document it clearly; embedding StikJIT later frees one slot |
| 7 | **Licensing**: QEMU as a whole is GPL-2.0, so once it is included, the whole app is in practice distributed under GPL-2.0; StikDebug is AGPL-3.0, so its code cannot be compiled in; StikJIT is MPL-2.0, which under MPL's "Secondary License" clause can be combined with GPL-2.0+ | Low | Medium | Invoke StikDebug only via URL and never link its code; check again before embedding StikJIT **[inferred]** |
| 8 | **A competitor gets there first**: if pocketTouch really works, or S5LBox adds more machines | Low-medium | Low (open-source contribution does not mind overlap) | Release a bootable version as early as possible |

---

## 8. M1 execution plan

### 8.1 Which device to try first: iPhone 18 Pro (iOS 27.2)

1. **The only public QEMU-type JIT success record on iOS 27 is on 27.2** (Ios-emul, iPhone 16e); 27.0.x has only failure reports. Establish a "it works" baseline on the system with the higher chance of success first, then troubleshoot on 27.0.1; problems are easier to pinpoint that way.
2. **It has already been paired with this Mac's Xcode**: this machine already has the `iPhone19,2 27.2` device symbol cache (created 10-18, 6.7 GB), so running directly from Xcode and LLDB debugging are available right away; this machine has no symbol cache for the iPhone 14 Pro, so presumably it has never been connected to this Mac's Xcode, and the first connection means waiting for Xcode to copy about 6 to 7 GB of symbols.
3. **12 GB of memory**, which takes the memory limit out of the variables for the first boot.
4. **The fastest CPU**, so the interpreter version's performance on it is the "best case without JIT"; if even that is too slow, better to know early.
5. StikDebug's DDI problem on the iPhone 18 Pro was fixed in 3.1.11.

Then repeat the same steps on the **iPhone 14 Pro (iOS 27.0.1)**, as the low-end baseline (A16, 6 GB) and as a JIT data point for a second iOS minor version. The JIT mechanism is exactly the same on both devices, so the code needs no branching.

Exception: if the iPhone 18 Pro is the user's main phone and they do not want to turn on Developer Mode or install StikDebug and LocalDevVPN on it, reverse the order and use the 14 Pro first; the mechanism is the same, it just means accepting up front that JIT is more likely to have problems on 27.0.1.

### 8.2 Steps

| Phase | Step | Acceptance | Estimate |
|---|---|---|---|
| A Preparation | A1 Read the M0 report: JIT / TCI data and snapshot size for 3GS 6.1.6 on the Mac; get the device catalog LTM has built and the actual QEMU arguments (refer to LTM's `BootRecipe.swift`) | A device that boots on the Mac, plus its full argv | 0.5 days |
| | A2 The user answers the questions in section 9 (phones, accounts, downloads) | Answers received | |
| B Dependencies | B1 Using LTM's `build-package-native.sh` as a template and referring to UTM's cross-compile options, write an iOS arm64 dependency script and build under `work/`: glib, pcre2, proxy-libintl, pixman, libslirp 4.9.4 (two patches), the OpenSSL static library; FFmpeg deferred | Complete sysroot and pkg-config files | 1 to 2 days |
| C Cross-compiling | C1 Recover `build-ios.sh` / `make-dylib.sh` from `af4d255637`, remove TCTI, adapt to QEMU 11 (`--disable-cocoa --disable-coreaudio --audio-drv-list= --disable-opengl --target-list=arm-softmmu` etc.); try sigaltstack for coroutines first | `libqemu-arm-interp.dylib` built | 2 to 4 days |
| | C2 Build the interpreter version for the iOS Simulator and get it booting in the Simulator (fast iteration) | The guest picture is visible in the Simulator | Included above |
| | C3 Build the JIT version `libqemu-arm-jit.dylib` | Both dylibs depend only on frameworks iOS has (checked with `otool -L`) | 0.5 days |
| D App shell | D1 Minimal Xcode project: dlopen the dylib, call `qemu_ios_main` on a background thread, draw frames to CALayer/Metal, wire touch, Home, the power button and foreground/background to the existing ABI | Builds and installs | 2 to 3 days |
| | D2 Use `xcrun devicectl device copy to` to copy the device built on the Mac into the app's Documents (as upstream's `install-images.sh` did), and assemble argv by LTM's rules | Files on the phone, arguments correct | 0.5 days |
| | D3 First boot with host GL off, going through software compositing | | |
| E First boot (the "first") | E1 Cold boot to the lock screen with the interpreter version on the iPhone 18 Pro: record the time taken, CPU and memory usage | Lock screen seen | 1 day |
| | E2 JIT: run from Xcode + LLDB stop hook (change upstream's `lldb_jit.py` to the new protocol, or keep `0x69`) | Boots to the home screen; comparison with E1 recorded | 1 to 2 days |
| | E3 JIT: switch `region.c` to the new protocol (refer to Ios-emul's 0016 patch), assign universal.js manually in StikDebug, launch without the computer | Boots to the home screen with no computer connected | 1 to 2 days |
| | E4 Repeat E1 to E3 on the iPhone 14 Pro | A comparison table for the two devices | 1 day |
| F Probing (tail of M1 / start of M2) | F1 EAGL: add the ES 2.0 context to `gles-host-eagl.c`, verify that CoreAnimation goes through GL | Home screen composited with GL, no rejections | 3 to 5 days |
| | F2 Snapshots: without GL, "save → exit → restore in a new process with `-incoming`", and see whether taps work (reproduce the upstream bug); with GL, confirm the blocker | Results recorded | 1 day |
| | F3 Memory and `tb-size`: compare 128 / 256 / 512 MB, measure `os_proc_available_memory()` on both devices | A recommended default | 1 day |
| | F4 Along the way, probe whether the private iOS `glGetTexImage` can read textures back | Yes / no | 0.5 days |

### 8.3 Rough workload estimate

- A to E (the "first" milestone, both devices booting to the home screen): about **1.5 to 2.5 weeks**.
- Adding F (probing GL and snapshots): about **1 more week**.
- Upstream's experience in August: going from writing the research doc to having data from a real device took only about two days, so the build side's risk is manageable; what really eats time is getting the JIT toolchain working on iOS 27, and GL/snapshots. **[inferred]**

---

## 9. Questions for the user

1. **Is the iPhone 18 Pro your main phone?** Can Developer Mode be turned on, a pairing file imported, and StikDebug and LocalDevVPN installed on it? Is it now on the 27.2 release, or on the 24B5110a in the Xcode cache (which looks like a beta)?
2. **Signing account**: for M1 development, installing directly from Xcode with a free Apple ID is enough (re-sign every 7 days). Buy a paid developer account (99 USD/year) now? Not buying one does not block M1.
3. **Download permission**:
   - Building the iOS dependencies means downloading the source tarballs of glib, pcre2, pixman, libslirp and OpenSSL (and later FFmpeg), about 100 to 200 MB in total, kept in `work/`;
   - The first time the iPhone 14 Pro connects to Xcode, Xcode will automatically copy about 6 to 7 GB of device symbols;
   - Install StikDebug (IPA from GitHub releases) and LocalDevVPN (App Store) on both phones.
4. **Can M1's first boot go without GL acceleration?** (The picture comes from software compositing and will be slow, but it lets "can it boot" be verified separately from "is GL correct".)
5. **Embed StikJIT (MPL-2.0) in the app later**, so users do not have to install StikDebug separately? That adds an app extension, which takes one more App ID under a free account. No need to decide now; decide before M2.
6. External communication (later): ask StikDebug to add our app's name to the automatic script assignment table (this needs a PR sent to them)? No need to decide now.

---

## Appendix: main sources

Upstream (qemu-ios / LightTouchMac)
- The dead-end commit [01ae922092](https://github.com/samhenrigold/qemu-ios/commit/01ae922092d37d029f42427f7aa50025fc6d2a9b); iOS port commits [49f0804cb7](https://github.com/samhenrigold/qemu-ios/commit/49f0804cb70a), [d14b8cc839](https://github.com/samhenrigold/qemu-ios/commit/d14b8cc839a8); research doc commit [20577fdbbb](https://github.com/samhenrigold/qemu-ios/commit/20577fdbbbd9); v10.0.2 rebase [74e9ca7934](https://github.com/samhenrigold/qemu-ios/commit/74e9ca793442); Mac dylib [7615017fe7](https://github.com/samhenrigold/qemu-ios/commit/7615017fe7fe); QEMU 11 port [b18cd1606c](https://github.com/samhenrigold/qemu-ios/commit/b18cd1606c9c); TCTI deletion [74759924a1](https://github.com/samhenrigold/qemu-ios/commit/74759924a121); iOS script deletion [6a9aacff4b](https://github.com/samhenrigold/qemu-ios/commit/6a9aacff4b89)
- [contrib/ios-app](https://github.com/samhenrigold/qemu-ios/tree/af4d25563788929799725b626c3c2f644bbeb58b/contrib/ios-app) before deletion; the [TCTI README](https://github.com/samhenrigold/qemu-ios/blob/f1c24fbbca8faba53cba367a70ede87556a4b119/tcg/aarch64-tcti/README.md) before deletion
- [docs/research/ipod-touch-2g-on-iphone.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/ipod-touch-2g-on-iphone.md), [docs/research/angle-evaluation.md](https://github.com/samhenrigold/qemu-ios/blob/main/docs/research/angle-evaluation.md)
- [tcg/region.c](https://github.com/samhenrigold/qemu-ios/blob/main/tcg/region.c), [hw/arm/gles-host-eagl.c](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/gles-host-eagl.c), [hw/arm/gles-host.c](https://github.com/samhenrigold/qemu-ios/blob/main/hw/arm/gles-host.c), [contrib/ios-app/qemu-ios-entry.c](https://github.com/samhenrigold/qemu-ios/blob/main/contrib/ios-app/qemu-ios-entry.c), [meson.build](https://github.com/samhenrigold/qemu-ios/blob/main/meson.build)
- CGL snapshots [1c974f183c](https://github.com/samhenrigold/qemu-ios/commit/1c974f183c23); taps dead after restore [LightTouchMac 3f39d80d](https://github.com/samhenrigold/LightTouchMac/commit/3f39d80d)
- [LightTouchMac README](https://github.com/samhenrigold/LightTouchMac), [dependencies.json](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/dependencies.json), [build-package-native.sh](https://github.com/samhenrigold/LightTouchMac/blob/main/build-support/recipes/build-package-native.sh), [BootRecipe.swift](https://github.com/samhenrigold/LightTouchMac/blob/main/Packages/HostRuntime/Sources/HostRuntime/BootRecipe.swift)

UTM
- [build_dependencies.sh](https://github.com/utmapp/UTM/blob/main/scripts/build_dependencies.sh), [patches/sources](https://github.com/utmapp/UTM/blob/main/patches/sources), [iOS.entitlements](https://github.com/utmapp/UTM/blob/main/Platform/iOS/iOS.entitlements), [UTMJailbreak.m](https://github.com/utmapp/UTM/blob/main/Services/UTMJailbreak.m), [PR #7908](https://github.com/utmapp/UTM/pull/7908), [release notes](https://github.com/utmapp/UTM/releases), [iOS installation docs](https://docs.getutm.app/installation/ios/)
- utmapp/qemu [region.c](https://github.com/utmapp/qemu/blob/utm-edition/tcg/region.c), [TCTI commits](https://github.com/utmapp/qemu/commits/utm-edition/tcg/aarch64-tcti)

JIT tools
- StikDebug [release notes](https://github.com/StikDebug/StikDebug/releases), [README](https://github.com/StikDebug/StikDebug), [ProcessInfo+TXM.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/ProcessInfo%2BTXM.swift), [AutoScriptAssignments.swift](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Support/AutoScriptAssignments.swift), [universal.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/universal.js), [legacy.js](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Scripts/legacy.js)
- StikDebug issues [#465](https://github.com/StikDebug/StikDebug/issues/465), [#469](https://github.com/StikDebug/StikDebug/issues/469), [#471](https://github.com/StikDebug/StikDebug/issues/471), [#476](https://github.com/StikDebug/StikDebug/issues/476), [#491](https://github.com/StikDebug/StikDebug/issues/491)
- [StikJIT INTEGRATION.md](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md); [Husk #183](https://github.com/Leviidev/Husk/issues/183)
- [builds.io JIT guide](https://builds.io/blog/technologies/ios-technologies/how-to-enable-jit-on-iphone/)

Similar projects
- [S5LBox](https://github.com/j0shua-SYSON/S5LBox), [pocketTouch](https://github.com/landonjsmith/pocketTouch), [Inferno-iOS](https://github.com/MakrSas/Inferno-iOS) ([#5](https://github.com/MakrSas/Inferno-iOS/issues/5), [#8](https://github.com/MakrSas/Inferno-iOS/issues/8)), [Ios-emul](https://github.com/vytska69/Ios-emul), [blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch) ([PERFORMANCE.md](https://github.com/blake-lucas/LightTouch/blob/main/docs/PERFORMANCE.md)), [blake-lucas/qemu-ios](https://github.com/blake-lucas/qemu-ios), [KD3533/qemu-ios-android](https://github.com/KD3533/qemu-ios-android)

Signing, memory, graphics, hardware
- [SideStore #1616](https://github.com/SideStore/SideStore/issues/1616), [AltStore FAQ: App IDs](https://faq.altstore.io/altstore-classic/app-ids), [AltStore Classic release notes](https://faq.altstore.io/release-notes/altstore), [Apple Developer Forums 834805](https://developer.apple.com/forums/thread/834805)
- [Apple OpenGL ES Programming Guide: contexts and sharegroups](https://developer.apple.com/library/ios/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/WorkingwithOpenGLESContexts/WorkingwithOpenGLESContexts.html)
- [iPhone 18 Pro (Wikipedia)](https://en.wikipedia.org/wiki/IPhone_18_Pro), [How third-party apps enable MIE (8ksec)](https://8ksec.io/mie-deep-dive-enabling-apps/)

Local
- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/OpenGLES.framework/`
- `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2 27.2 (24B5110a)/arm64e.x1/Symbols/System/Library/Frameworks/OpenGLES.framework/OpenGLES`
