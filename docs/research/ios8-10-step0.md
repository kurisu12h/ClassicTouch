# iOS 8 to 10 step 0: iPod touch 5 firmware inventory

- Date: 2026-11-02
- Author: the ios8-10-research execution session (continuing from `docs/research/ios8-10-feasibility.md`). Read-only analysis: no emulator code written; nothing changed in `upstream/`, `app/`, `scripts/`, `patches/`; no commit, no push; nobody outside was contacted.
- Downloads (approved by the user): iPod5,1 9.3.5 (13G36, 1,609,091,774 bytes, sha1 `8ee90db3…e05a`) and 7.1.2 (11D257, 1,285,647,825 bytes, sha1 `f935397e…a66a`), downloaded from Apple's servers into `work/firmware/`; both sha1s checked out (URLs and sha1s taken from the ipsw.me public API).
- Extracted material: all in `work/research/ipod5/` (kernelcaches, device trees, iBoot, two restore ramdisks, decrypted root filesystems, device tree comparison tables), about 2.7 GB, never goes into the repository. The decrypted iPhone 4 7.1.2 files used for comparison were read directly, read-only, from the FirmwareKit cache `work/cache/decrypted-v2/81da17b3…/`.
- Tools: no third-party programs installed. My own Python scripts are in `work/research/tools/` (`fw.py` decodes IMG3, LZSS, device trees, vfdecrypt and the prelinked kext table; `kc.py` finds strings and code references in kexts; `dsc.py` reads the shared cache; `dtdiff.py` compares device trees; `genpass.py` is a Python rewrite of the xerub/genpass (GPL-2) algorithm; `unpack.py` unpacks an IPSW in one step), all run with `python3 -I`; the Python `cryptography` 50.0.0 already on this machine for AES/3DES; Xcode's bundled `llvm-objdump` and `otool`; `hdiutil` for read-only mounts. The two genpass C sources (posixninja/genpass, xerub/genpass) were only read, into `work/research/genpass-src/`, for reference, and not compiled. Keys from ipsw.me and tihmstar/fwkeydb.
- Labels: **[verified]** read directly in the binaries, device trees or source extracted this time; **[inferred]** my inference, or needs a boot to confirm.

---

## 0. Summary of conclusions

1. **Device tree (question 1):** iPod 5 9.3.5 vs iPhone 4 7.1.2: among the first-level nodes under arm-io, 33 are unchanged, 28 renamed, 32 added, 45 gone (most of the gone ones are board-level peripherals: baseband, compass, fuel gauge, etc.). The A5 address layout is "A4's arm-io offsets unchanged, window moved from 0x80000000 to 0x30000000": CDMA, AES, FMI, EHCI, SGX, PMGR, GPIO and the watchdog have the same low 28 bits within the window as on A4. On A5 many nodes are still claimed by A4 (S5L8930X) generation drivers (GPIO, DART, USB, watchdog, CDMA), or by generic Samsung drivers (UART, SPI, I2S, PKE, MIPI-DSI). What really needs new code is AIC (`aic,1`), PMGR (`pmgr,s5l8940x`), I2C (`i2c,s5l8940x`), DWI, PL310, PMU (D1881), display (CLCD moved address, the pipeline was renamed H4P), plus the AE2 audio coprocessor and IOP (`AppleA5IOP`). **[verified]**
2. **NAND (question 2, the biggest risk): the emulated flash cannot be treated as raw NAND, and the A4 generator is unusable; but flash can be bypassed entirely by putting the system disk on USB mass storage.**
   - The YAFTL/VSVFL raw NAND code used by A4 exists only in `AppleNANDLegacyFTL` (matched on `ppn-device = false`). Neither the iPod 5 7.1.2 kernel nor the 9.3.5 kernel has this kext; only `AppleSwissPPNFTL` is left (requires `ppn-device = true`, `ppn-ftl-ver = 2`). **[verified]**
   - The IOP firmware is likewise built from the iBoot source tree: 7.1.2 is iBoot-1940.10.58, the same as A4, and 9.3.5 is iBoot-2817.60.2. But the A5 IOP is an **ARMv7 core** (A4's is ARMv5, which upstream emulates with arm946), so the "run the real IOP firmware" route needs a different core. **[verified]**
   - **Workaround:** the 9.3.5 kernel has a full USB host stack and `IOUSBMassStorageDriver`, which matches generically on USB interface class 8, subclass 6 (SCSI), and QEMU's built-in `usb-storage` is exactly that type. The EHCI driver, compatible string and register offsets are all the same as on A4 (`usb-synopsys_ehci,s5l8930x`, 0x300000 inside usb-complex), and upstream already built an EHCI host model for the A4 USB keyboard. The 7.1.2 kernel also has `IOUSBMassStorageClass`. Effaceable storage can go on NOR (the kernel has `AppleEffaceableNOR`, and the A4 kboot already grafts a NOR node onto boards that have no NOR). Verified at the driver level; whether the kernel will mount root from a USB disk and whether data protection goes smoothly can only be known by booting **[inferred]**.
   - The proper PPN route (emulate PPN and write a Swiss PPN FTL generator, or let the kernel self-format with `nand-enable-reformat`) comes later and does not block booting.
3. **AMFI (question 3):** the AMFI in both 7.1.2 and 9.3.5 still reads `amfi_allow_any_signature`, `cs_enforcement_disable`, `amfi_get_out_of_my_way` and `amfi_unrestrict_task_for_pid`, each with code references and a "disabled by boot-arg" log message. Before reading them it calls `PE_i_can_has_debugger(NULL)` (the 9.3.5 kernel ships with its symbol table, so function names are visible directly), and that reads exactly the `chosen/debug-enabled` that kboot sets to 1. The existing kboot approach still holds on 9.3.5. **[verified]**
4. **GL and display (question 4):**
   - The @encode of `__GLIFunctionDispatchRec` is still there, and it is **byte-for-byte identical** in the three shared caches of iPhone 4 7.1.2, iPod 5 7.1.2 and iPod 5 9.3.5 (1035 slots). gles-public's method of deriving the dispatch table from @encode applies directly. **[verified]**
   - QuartzCore: 7.1.2 uses `H3CLCDDisplay` / `H4CLCDDisplay`; 9.3.5 changed to `AppleCLCDDisplay` and moved the class name matching into the IOMobileFramebuffer framework, but it still looks for `AppleCLCD` (in the kernel the class is called `AppleMobileCLCD` in both generations). **[verified]**
   - **New problem:** the 9.3.5 dyld is dyld-390.7, not the dyld-360 that my previous report inferred from the open-source releases. It already has the iOS 10 style `dylibsCanOverrideCache()` check: it first reads the development firmware bit at comm page 0xFFFF4084, then requires `cacheType` at shared cache header +0x68 to be 0 (development), while the cache shipped with 9.3.5 has 1 (production). So **the override switch gles-public uses today already fails on 9.3.5**; the 7.1.2 dyld-324.1 has no such check. **[verified]** For ways out see section 4.3; the simplest is to change this cache header field to 0 when preparing the device **[inferred, needs testing whether signature validation lets it through]**.
5. **launchd (question 5):** 9.3.5 switched to the new libxpc launchd (765.50.8). At boot it reads the daemon list from `xpcd_cache.dylib` in the shared cache, where all 260 plists are precompiled. Whether it still scans `/System/Library/LaunchDaemons` for plists added later cannot be seen statically **[inferred: most likely it only honors the cache]**. The old 7.1.2 launchd reads the directory directly, so upstream's install method of dropping a plist into the directory works on 7.1.2 and must be tested first on 9.3.5. Fallbacks: wrap the executable of an existing daemon, or, once the cache header change works, override `xpcd_cache.dylib` as well.
6. **Root filesystem keys (question 6): yes.** My Python rewrite of genpass, run on the two 9.3.5 restore ramdisks with the platform name `s5l8942x`, computed a root filesystem key bit-for-bit identical to the public value on ipsw.me; the same holds for 7.1.2 and for iPhone 4 7.1.2 (`s5l8930x`). The 8.4.1 and 9.3.5 models that lack root filesystem keys (fwkeydb has their ramdisk keys) can all be computed this way. **[verified (9.3.5, 7.1.2); extending to 8.4.1 is inferred]**
7. **Cheapest way to do step 1:** derive an `n78` machine from the A4 machine code, single-core Cortex-A9. In the device tree, first hide cpu1, IOP, the flash controller, AE2, SGX, ISP and the video codecs (set the compatible string to none, as upstream does for the baseband). Write new code only for AIC (including timers) and PMGR, and reuse the A4 models for the rest with new base addresses; add an n78 board to kboot. Target: the 9.3.5 and 7.1.2 kernels print on uart1 and stop at Waiting for root device. Right after that, attach a `usb-storage` and see whether the kernel recognizes the USB disk. Details in section 7.
8. **Newly surfaced blockers:** no hard blocker. Three new issues to handle: dyld-390's cache override check (affects the GL front end and the launchd workaround, from 9.3.x on); 9.3.5 replaced the whole USB host stack with the new IOUSBHostFamily (the A4 EHCI model has only been verified on the old stack); the A5 IOP is an ARMv7 core.

---

## 1. Device tree comparison (question 1)

The full comparison table is in `work/research/ipod5/dtdiff-n90-712-vs-n78-935.md` (plus two more: n78 7.1.2 vs 9.3.5, and n90 7.1.2 vs n78 7.1.2). Each row has the `compatible` of both sides, the iPod 5 `reg` and `interrupts`, and which kernel class claims the node, computed from `IONameMatch`.

### 1.1 Overall

| Comparison | Unchanged | Renamed | Added | Gone |
|---|---|---|---|---|
| iPhone 4 7.1.2 → iPod 5 9.3.5 (all nodes) | 33 | 28 | 32 | 45 |
| iPod 5 7.1.2 → iPod 5 9.3.5 | 90 | 1 | 2 | 2 |

The iPod 5's own 7.1.2 and 9.3.5 device trees are almost identical (only `sgx` is renamed to `gpu,s5l8940x`, `scaler` is split into `scaler0/1`, and `rgbout` is gone), so once the machine is built, both versions share it. **[verified]**

### 1.2 Address layout **[verified]**

| | iPhone 4 (A4) | iPod 5 (A5) |
|---|---|---|
| arm-io `ranges` | 0x0 → 0x80000000, length 0x40000000 | 0x0 → 0x30000000, length 0x10000000 |
| Kernel link base | 0x80001000 | 0x80001000 |
| Kernel version | xnu-2423.10.71 (7.1.2) | xnu-2423.10.71 (7.1.2), xnu-3248.61.1 (9.3.5), RELEASE_ARM_S5L8942X |
| Board ID / chip ID | 0x00 / 0x8930 | 0x00 / 0x8942 (BuildManifest) |
| Minimum system partition | 1664 MiB (upstream measured that it needs to be this large) | 2012 MB (9.3.5 BuildManifest) |

Blocks whose offset within the window is unchanged: CDMA (0x7000000, version 2 → 3), AES (0x7800000), FMI (six ranges starting at 0x1200000), EHCI (0x300000 inside usb-complex), SGX base (0x5100000, length changed from 0x1000 to 0x18000), PMGR (low 28 bits 0xF100000), watchdog (low 28 bits 0xF103020), GPIO. CLCD moved from 0x9000000 to 0xA100000, and IOP from 0x6300000 to 0xF300000.

### 1.3 Block-by-block classification **[verified]**

| Category | Nodes (the class that claims it on iPod 5 9.3.5) |
|---|---|
| Still A4-generation drivers | gpio (`AppleS5L8930XGPIOIC`), dart-rt/nrt (`AppleS5L8930XDART`), usb-complex (`AppleS5L8930XUSBArbitrator`), otgphyctrl (`AppleS5L8930XUSBPhy`), wdt (`AppleS5L8930XWatchDogTimer`), cdma (`AppleCDMA`), pwm (`AppleS5L8920XPWM`), jpeg, scaler0/1 (`AppleM2ScalerCSCDriver`), flash-controller0 (`AppleIOPFMI`) |
| Generic Samsung drivers (models already exist on A4) | uart1 to uart4 (`AppleSamsungSerial`), spi1/spi2 (`AppleSamsungSPIController`), i2s0/i2s2 (`AppleSamsungI2SController`), pke (`AppleSamsungPKE`), mipi-dsim (`AppleSamsungMIPIDSIController`) |
| New SoC-level blocks | aic (`AppleInterruptController`, replaces the PL192 VIC), pmgr (`AppleS5L8940XPerformanceController`), i2c0/i2c2 (`AppleS5L8940XI2CController`), dwi (`AppleS5L8940XDWI`, replaces swi), pl310 (`AppleS5L8940XPL310`), iop (`AppleA5IOP`, replaces `AppleARM7M`), sgx (`SGXDriver543`), clcd (`AppleMobileCLCD`, the kext is `AppleH4PCLCD`), sha2 (`sha,s5l8940x`, replaces sha1), perfcounter, trace |
| New audio structure | ae2 (`AppleA5AE2`, audio coprocessor), mca0/mca1 (`AppleAE2MCA`), i2s-switch (`AppleAE2I2SSwitch2`), codec cs42l81, amplifier cs35l19 |
| Board level | PMU changed from D1815 to D1881 (9.3.5 adds the `AppleDialogPMU` kext); accelerometer `ap3dsh`; gyroscope `ap3gdl`, same as iPhone 4; touch `multi-touch,n78` still on spi1; screen `lcd,pinot` on mipi-dsim; Wi-Fi on the EHCI HSIC port (`AppleBCMWLANBusInterfaceHSIC`) |
| Gone | vic, uart0, uart5/6, spi0, swi, sdio, ceata, amc, rgbout, sha1, baseband-related, compass, fuel gauge, GPS |

AIC node properties: `reg 0xF200000 0x10000`, `#main-cpus 2`, `use-ldrex 1`, `ipid-mask`, `target-destinations`. Both CPU nodes are `ARM,cortex-a9`. **[verified]**

**Serial:** there is no uart0 in the device tree. XNU's `serial_init()` looks for `boot-console`, `uart0`, `uart1` in that order (xnu-4570 `pexpert/arm/pe_serial.c`), and these strings are also in the 9.3.5 kernel, so the console will land on uart1 (0x32600000). **[verified in source; that the 9.3.5 binary follows the same logic is inferred]**

---

## 2. NAND stack (question 2)

### 2.1 Kexts **[verified]**

| | iPhone 4 7.1.2 | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|---|
| FMI | `AppleIOPFMI` (`fmi,s5l8920x`) | Same | Same (AppleIOPFMI-95) |
| Raw NAND FTL | `AppleNANDLegacyFTL` (`ppn-device = false`), containing Whimory's yaFTL and VFL | **None** | **None** |
| PPN FTL | None | `AppleSwissPPNFTL` (`ppn-device = true`, `ppn-ftl-ver = 2`), WhimoryPPN's SFTL and PPNVFL | Same (IOFlashStorage-730) |
| `AppleNANDFTL` | Common library, no matching entry | Same | Same |
| IOP firmware | `IOP_s5l8930x_firmware`, iBoot-1940.10.58, ARMv5 | `IOP_s5l8942xiop_firmware`, iBoot-1940.10.58 | Same name, iBoot-2817.60.2, 0x23000 bytes, ARMv7 |
| IOP driver | `AppleARM7M` + `EmbeddedIOP` | `AppleA5IOP` (`iop,s5l8940x`) + `EmbeddedIOP` | Same |
| effaceable | NAND or NOR | `AppleEffaceableNAND` / `AppleEffaceableNOR` | Same |

The A5 IOP firmware has 53 dsb/dmb/isb instructions and the v7 wfi; the A4 one has none of them (it uses the old CP15 wfi). Both start with a classic ARM exception vector table. So the A5 IOP is an ARMv7 core (the exact model was not checked; possibly a Cortex-A5 or an R-series core **[inferred]**).

### 2.2 Assessment

1. **The emulated flash cannot be used as raw NAND, and FirmwareKit's A4 generator (YAFTL/VSVFL format) is unusable.** The raw NAND FTL exists only in `AppleNANDLegacyFTL`, and the A5 kernel does not have this kext; when `ppn-device` reports false, no FTL takes over, so disk0 never appears. **[verified]**
2. **Work needed for the proper PPN route:** either emulate at a high level at the IOP mailbox layer, implementing the read, write and erase semantics of `IOPPNCommand` plus a page store (the A4 HLE implements the raw NAND command ring, so the protocol has to be redone); or switch to an ARMv7 IOP core to run the real firmware, plus register-level models of H2FMI and PPN (Cascadia documented the PPN command sequences). For the system disk contents, either write an offline Swiss PPN FTL generator (Cascadia has a read-only implementation to refer to), or use `nand-enable-reformat` (the 9.3.5 SwissPPNFTL accepts this parameter, **[verified]**) to let the kernel self-format and then find a way to load the system in. Estimated at several weeks. **[inferred]**
3. **Recommended workaround: put the system disk on USB mass storage.**
   - The 9.3.5 kernel has `IOUSBMassStorageDriver`. Its `IOUSBMassStorageInterfaceNubSCSI` matches any IOUSBHostInterface generically on `bInterfaceClass 8`, `bInterfaceSubClass 6`, after which `IOSCSIPeripheralDeviceType00` publishes a block device. QEMU's `usb-storage` is exactly 8/6/0x50. **[verified]**
   - The 7.1.2 kernel has `IOUSBMassStorageClass`. **[verified, matching conditions not examined closely]**
   - EHCI: the compatible string `usb-synopsys_ehci,s5l8930x`, the driver `AppleS5L8930XUSBEHCI` and the register offsets are all the same as on A4. Upstream built an EHCI host for the iPad and iPhone 4 USB keyboard, and the iPhone 4 on iOS 7 can enumerate QEMU's USB keyboard (in our M0 test it popped up "Cannot Use Device", which shows the host stack is working). **[verified]**
   - The kernel supports LwVM (`LightweightVolumeManager` matches on an IOMedia that is `Whole`); a plain partition table also works, with fstab in the rootfs changed to match.
   - Effaceable on NOR: the kernel has `AppleEffaceableNOR` (`effaceable,nor`, under `nor-flash,spi`), and the A4 kboot already grafts K48's NOR node onto N81/N90, which have no NOR. **[verified]**
   - Not verified, can only be known by booting: whether the kernel refuses to mount root from a USB disk (for example by requiring root to be on internal storage), whether content protection for the data partition can set up a keybag on a USB disk, and whether 9.3.5's new USB host stack gets along with the A4 EHCI model. **[inferred]**
   - A ramdisk (kboot already supports `md0`) is only good for booting as far as launchd: the 9.3.5 minimum system partition is 2012 MB, which does not fit in 512 MB of RAM.

---

## 3. AMFI boot-args (question 3) **[verified]**

I used `kc.py refs` to find the strings in the AMFI kext, then their references in Thumb code via "ldr from literal pool + add pc" (this is how the kernels of these generations load strings).

| Argument | iPhone 4 7.1.2 | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|---|
| `amfi` (master switch) | Referenced | Referenced | Referenced |
| `amfi_unrestrict_task_for_pid` | Yes | Yes | Yes |
| `amfi_allow_any_signature` | Yes | Yes | Yes, log "signature enforcement disabled by boot-arg" |
| `amfi_get_out_of_my_way` | Yes | Yes | Yes |
| `cs_enforcement_disable` | Yes | Yes | Yes, log "cs_enforcement disabled by boot-arg" |
| `cs_debug` | In AMFI | In AMFI | Moved to the base kernel |

The code in the 9.3.5 AMFI before it reads the arguments is `movs r0, #0; bl <stub>; cmp r0, #0; beq skip`. The stub jumps via `__nl_symbol_ptr` to the kernel's `_PE_i_can_has_debugger` (the kernel has symbols, so `llvm-objdump` shows the function name directly). In other words, as in 3.2 to 5.1.1, these arguments are read only when `debug-enabled` is nonzero, and kboot already sets it to 1. The 9.3.5 AMFI also adds an interface for loading trust caches (`loadTrustCache`), which is not needed this time.

---

## 4. GL dispatch table, display class names, dyld override (question 4)

### 4.1 Dispatch table **[verified]**

Each of the three shared caches has one `{__GLIFunctionDispatchRec=…}`, 4195 bytes long, and it is **byte-for-byte identical** across iPhone 4 7.1.2, iPod 5 7.1.2 and iPod 5 9.3.5 (1035 function pointer slots, matching the 7.1.2 slot count recorded in `docs/n90/README.md`). gles-public's method of counting slots from @encode still holds on 9.3.5. For the step that decodes slot names from the OpenGLES export trampolines, I have not yet checked whether the shape of the trampoline instructions changed in 9.3.5 **[inferred: the compiler moved on a generation, so more decoding shapes may need to be added]**.

In 9.3.5, `GLEngine.bundle/GLEngine` and `IMGSGX543GLDriver` are both in the shared cache; the cache also contains `Metal.framework` (there is no Metal device on A5; the framework is merely present).

### 4.2 Display class names **[verified]**

| | Where the display is matched | Strings |
|---|---|---|
| iPhone 4 7.1.2, iPod 5 7.1.2 | QuartzCore (`open()` of `CA::WindowServer::H3CLCDDisplay`, `H4CLCDDisplay`) | `AppleCLCD`, `AppleRGBOUT` |
| iPod 5 9.3.5 | QuartzCore has only the `AppleCLCDDisplay` class left; the `AppleCLCD` and `AppleRGBOUT` strings moved to IOMobileFramebuffer, VideoToolbox and UIKit | `AppleCLCD` |

On the kernel side, the CLCD class is called `AppleMobileCLCD` in both generations (the A4 kext is called AppleCLCD, the A5 one AppleH4PCLCD). So user space always looks for the screen as `AppleCLCD`, and upstream's A4 display path needs no conceptual change; what needs changing is the register model of the A5 display pipeline (CLCD moved address, DisplayPipe was renamed).

### 4.3 dyld override switch: already broken on 9.3.5 **[verified]**

| | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|
| dyld version | dyld-324.1 | dyld-390.7 |
| Shared cache header | `mappingOffset 0x68`, no `cacheType` field | `mappingOffset 0x98`, `cacheType` (+0x68) = 1 (production) |
| Reads the comm page development firmware bit (0xFFFF4084) | No | In two places: `mapSharedCache()` and `loadPhase5()` |

The check in the 9.3.5 dyld's `loadPhase5()` (disassembly, starting at address 0x1fe07824): read bit 0 of 0xFFFF4084, and if it is 0, override is not allowed; then take `sSharedCache` and read the 64-bit `cacheType` at its +0x68, and if it is nonzero, override is not allowed either. This is the inlined version of `dylibsCanOverrideCache()` from the dyld-421 (iOS 10) open source. kboot can satisfy the first condition (the kernel writes `PE_i_can_has_debugger()` into this bit), but not the second.

**Conclusion:** what gles-public relies on today, "drop an `enable-dylibs-to-override-cache` file so dyld uses the OpenGLES on disk", does not take effect on 9.3.5; 7.1.2 still works. My previous report said "iOS 8 and 9 still work, only iOS 10 breaks", inferred from the open-source dyld-360, but 9.3.x actually uses dyld-390, so that is corrected here. The 8.4.1 dyld version was not downloaded and verified **[inferred: dyld-353, override still works]**.

Ways out (none tried):

1. **When preparing the device, change shared cache header +0x68 to 0** (or save a separate copy named `dyld_shared_cache_armv7.development` and change that; the 9.3.5 dyld recognizes this file name). This changes a documented header field, not a hand-found code offset. The risk is the cache file's code signature: the hash of the page that holds the header will no longer match, and whether the kernel lets it through with `cs_enforcement_disable` on needs testing. **[inferred]**
2. Patch `/usr/lib/dyld` to skip the `cacheType` check, found by byte pattern (ad hoc re-sign). Feasible, but it violates upstream's "no hand-patched bytes" principle. **[inferred]**
3. Use `DYLD_INSERT_LIBRARIES` instrumentation to take over the GL entry points. This first requires being able to change the environment variables of backboardd and apps, and the 9.3.5 launchd job definitions are in the cache (section 5), which leads back to the same problem. **[inferred]**

Option 1 is the cheapest. I suggest doing a small experiment alongside step 1: change only this byte, boot, and see whether dyld loads the stand-in library on disk.

---

## 5. launchd (question 5)

| | iPod 5 7.1.2 | iPod 5 9.3.5 |
|---|---|---|
| launchd | Old launchd (154,736 bytes); its strings only have `overrides.plist`, no xpcd cache | New libxpc launchd, libxpc_executables-765.50.8, "Darwin Bootstrapper Version 3.4.0", 240,896 bytes |
| Daemon list cache | The shared cache has `xpcd_cache.dylib` (193 LaunchDaemons), used by xpcd | The shared cache has `xpcd_cache.dylib`; its `__TEXT,__xpcd_cache` section holds plists: the full contents of 260 LaunchDaemons, 91 AppExtensions, `SystemLibraryTreeState` |
| `/System/Library/LaunchDaemons` | 194 files | 260 files |
| `/Library/LaunchDaemons` | Does not exist | Does not exist |

The strings of the 9.3.5 launchd, in order: the xpcd cache path and section name, `No daemons in cache`, `No tree state entry in cache`, and only then `/System/Library/LaunchDaemons` and `/System/Library/NanoLaunchDaemons`. It also supports `EnvironmentVariables`, `disabled.plist` and `overrides.plist` (in `/private/var/db/com.apple.xpc.launchd`). **[verified]**

Assessment: at boot 9.3.5 uses the cache first; whether it still scans the directories for plists added later cannot be seen statically **[inferred: most likely it only honors the cache, in which case upstream's method of dropping plists into the directory does not take effect on 9.3.5; it still works on 7.1.2]**. Dropping in a minimal test job after booting in step 1 will confirm it. Fallbacks:

1. Wrap a daemon that is already in the cache and is not critical: replace its executable with our launcher, which starts the guest tools first and then execs the original program (AMFI is already relaxed, so ad hoc signatures run).
2. Once the cache header change (4.3 option 1) works, dyld will also load a modified `xpcd_cache.dylib` from disk, so jobs can be added to its plist and environment variables added for SpringBoard and backboardd. **[inferred]**

---

## 6. Root filesystem keys (question 6) **[verified]**

How genpass works: from the SHA-1 of the platform name plus four constants, compute the locations of four "salts" in the ramdisk; SHA-256 over the whole ramdisk plus these segments gives the asr passphrase; then the passphrase (the first 24 bytes as the 3DES key, the last 8 bytes as the IV) unwraps the vfdecrypt key wrapped inside the encrypted DMG header. I rewrote xerub/genpass (asr4.c, pass2key.c) in Python as `work/research/tools/genpass.py`; it needs only the first 64 KB of the encrypted root filesystem DMG.

| Firmware | Ramdisk | Platform name | Result |
|---|---|---|---|
| iPod 5 9.3.5 | 058-49111-036 (Erase), 058-49421-036 (Update) | `s5l8942x` | Both equal the ipsw.me public value `edf6e096…cb8d0` |
| iPod 5 9.3.5 | Same as above | `s5l8940x` | Fails to decrypt (the platform name must be right) |
| iPod 5 7.1.2 | 058-4322-012 | `s5l8942x` | Equals the public value `13f5a0a0…f0aa` |
| iPhone 4 7.1.2 | 058-4107-013, 058-4266-010 | `s5l8930x` | Equals the public value `38d0320d…3684` |

So as long as the restore ramdisk key is available, the root filesystem key can be computed. fwkeydb has ramdisk keys for iPhone 5 9.3.5 and for iPhone 4S and iPhone 5 8.4.1 (checked in the previous report), so the missing root filesystem keys can all be filled in this way **[inferred, not actually run on these versions]**. The app can copy this algorithm as is, with no need to store root filesystem keys.

---

## 7. Cheapest way to do step 1 (machine skeleton)

Goal: the iPod 5 9.3.5 and 7.1.2 kernels print a banner on serial and stop at Waiting for root device; along the way, confirm the USB disk is recognized. Mac only, no phone and no app. **[everything below is a suggestion, inferred]**

1. **Machine:** derive `n78` from the upstream A4 machine (the `hw/arm/ipad1.c` family), as a patch in `patches/`. DRAM 512 MB from 0x80000000, arm-io window 256 MB from 0x30000000.
2. **CPU:** single-core `cortex-a9` first. Remove cpu1 from the device tree and change AIC's `#main-cpus` to 1 (done in kboot). Dual-core comes later.
3. **Models to write new (only far enough that the kernel does not hang):**
   - AIC (0x3F200000): follow the registers in xnu-4570 `pexpert/pexpert/arm/AIC.h`, plus per-line masking and target core, IACK, timers and timestamp (the kernel's timekeeping lives here; see the Cascadia notes cited in the previous report).
   - PMGR (0x3F100000): first make it "every write succeeds, reads return reasonable values"; the 24 MHz counter in the watchdog block (0x3F103020) has to tick.
   - I2C (`i2c,s5l8940x`) plus a stub of the D1881 PMU, and stubs for DWI and PL310.
4. **Reuse the A4 models, changing only the base address:** uart1 (console), GPIO, chipid (set to 0x8942), watchdog, CDMA and AES (version number changes from 2 to 3; not needed yet), SPI.
5. **Hide in the device tree for now** (set the compatible string to none): iop, flash-controller0, ae2, mca0/1, i2s-switch, sgx, isp, vxd, vxe, jpeg, displayport, tv-out, Wi-Fi. Display and touch move to step 3.
6. **kboot:** add an n78 board to FirmwareKit's KBoot: memory base and size, board ID 0x00, chip ID 0x8942, the A5 clock table (fill it in like A4's first, and change it if the kernel reads it wrong), 640×1136 screen parameters, `debug-enabled` and the rest as before, `nvram-proxy-data` filled the same way as for 7.x. Boot-args as before, adding `serial=3 debug=0x8`.
7. **Try the USB disk right after:** enable the A4 EHCI model and attach a QEMU `usb-storage` whose contents are FirmwareKit's existing system volume image. See whether 9.3.5's new USB stack can enumerate it and publish an IOMedia, then point `root-matching` at it. If this works, step 2 (getting launchd running) basically does not need to touch flash.
8. **Two small side experiments:** whether dyld loads the stand-in library on disk after the shared cache header `cacheType` is changed to 0 (4.3); whether launchd loads plists added later to the directory (section 5).

Estimate for step 1: 1 to 2 weeks (unchanged from the previous report). If the USB disk route works, step 2 can shrink from "1 to 2 months" to a few weeks, because the biggest piece (PPN storage) is postponed. **[inferred]**

---

## 8. Corrections and additions to the previous report

1. **dyld override switch:** 9.3.x already needs a development shared cache, like iOS 10 (dyld-390.7); it does not start with iOS 10. A line pointing to this document has been added to section 3.4 of `docs/research/ios8-10-feasibility.md`.
2. **Storage:** the low-effort route of "making the A5 kernel treat the emulated flash as raw NAND and reusing the A4 generator" is ruled out. It is replaced by the even cheaper route of "USB mass storage as the system disk", and PPN is postponed.
3. **AMFI:** the previous report marked it "8 to 10 not verified"; now 9.3.5 is verified to still honor the boot-args, and the gating is unchanged.
4. **USB host stack:** 9.3.5 uses the new IOUSBHostFamily (`com.apple.driver.usb.AppleUSBEHCI` etc.); 7.1.2 and A4 use the old IOUSBFamily.
5. **IOP:** A5 is an ARMv7 core, A4 is ARMv5.

---

## 9. File list (all in `work/`, not in the repository)

| Path | Contents |
|---|---|
| `work/firmware/iPod5,1_{7.1.2_11D257,9.3.5_13G36}_Restore.ipsw` (plus `.sha1`) | The two firmwares |
| `work/research/ipod5/{7.1.2,9.3.5}/` | Decrypted kernelcache (`.mach`), device tree (`.bin`, `dt.txt`, `dt.json`), iBoot, the two restore ramdisks, root filesystem (`rootfs.dmg`, UDIF, mountable with `hdiutil attach -readonly`), kext table `kexts.txt` |
| `work/research/ipod5/dtdiff-*.md` | The three device tree comparison tables |
| `work/research/ipod5/keys/` | Key JSON from ipsw.me and fwkeydb |
| `work/research/n90-7.1.2/` | iPhone 4 7.1.2 device tree text and kext table (the decrypted files stay in the FirmwareKit cache, used read-only) |
| `work/research/tools/` | The scripts from this session |
| `work/research/genpass-src/` | The two genpass C sources, read-only reference |
