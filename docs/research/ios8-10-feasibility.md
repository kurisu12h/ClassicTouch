# iOS 8 to 10 feasibility study: emulating A5/A6 machines on iPhone

- Date: 2026-11-02
- Author: the ios8-10-research execution session. Pure research, no emulator code written; no file in the repository was changed except this one.
- Method: read this repository's `docs/`, and the source and docs of `upstream/qemu-ios` (b225694505) and `upstream/LightTouchMac` (b06012fa); used `gh api` to read apple-oss-distributions/xnu (xnu-4570.1.46, the first open-source release with 32-bit ARM code), apple-oss-distributions/dyld (239.4, 353.2.1, 360.22, 421.2, 433.5), tihmstar/fwkeydb, rzxvx/Project-Cascadia, c12n/nexttouch, blake-lucas/LightTouch, axi0mX/ipwndfu and other repositories; the ipsw.me public API (read-only, keys and firmware metadata only); web search. No repository was cloned into `work/research/` (not needed); no Apple firmware was downloaded; the temporary directory holds only the ipsw.me key JSON and one LLVM `ARM.td`.
- Labels: **[verified]** I read the source, repository content, official page or public data directly; **[author's claim]** said by the project's own author, which I cannot verify independently; **[inferred]** my inference, or only indirect or third-party evidence.
- Chip codenames: A5 = S5L8940X (45 nm) / S5L8942X (32 nm), A5X = S5L8945X, A6 = S5L8950X, A6X = S5L8955X; A4 = S5L8930X (the newest generation upstream has today).

---

## 0. Summary of conclusions

1. **It can be done; no hard blocker found so far.**
   - All the firmware can be decrypted: the A5/A6 firmware keys for iOS 5 to 9 are all public (fwkeydb lists them up to iPhone 4S 9.3.6 and iPhone 5 9.3.5); **the iOS 10 firmware images for A6 are not encrypted at all** (iPhone 5 and iPad 4, 10.0 to 10.3.4: none of the 16 images in each version has a KBAG). **[verified]**
   - 32-bit devices have no SEP and no KPP and always use IMG3, so the kernel can be booted directly by FirmwareKit's KBoot the same way as on A4 today, with no need to emulate iBoot. **[KBoot part verified; SEP and KPP from third-party sources plus inference]**
   - QEMU has Cortex-A9, and ARM guests support multithreaded TCG; A6's Swift (ARMv7s) is, at the instruction set level, just ARMv7 plus VFPv4 and hardware divide, so a new model can be defined after Cortex-A15. **[verified]**
   - The GPU does not need emulating: on A5/A6 the iOS 8 to 10 UI still uses OpenGL ES 2.0 (Metal needs A7), so the current approach of "replace OpenGLES in the guest and forward the calls to the host" can be kept. **[inferred; iOS 10 has a loading hurdle, see 3.4]**
2. **But this is a whole new SoC port, not a configuration change.** A5 switched to Apple's own interrupt controller AIC (A4 has 4 PL192s), the system timer is inside AIC, it is dual-core, flash changed to PPN and is still driven by the IOP coprocessor, and memory moved from 0x40000000 to 0x80000000. **Nobody in the public world has emulated A5/A6, and nobody has booted 32-bit iOS 8 to 10 in an emulator.** nexttouch currently has only menus and a catalog; its author writes "no new emulation yet". **[verified, GitHub and web searches as of 2026-11-02]**
3. **Suggested first machine: iPod touch 5 (n78ap, A5 32 nm, S5L8942X).** The iPad mini 1, which has the same chip, has a large body of real-device hardware notes left by Project Cascadia (GPL-2.0, runs mainline Linux on A5); no baseband; the 640×1136 screen is phone-shaped; system versions 6.0 to 9.3.5, so the new machine can first be validated with versions such as 6.1 and 7.1.2 whose user space already works on A4, before climbing to 8.4.1 and 9.3.5. iOS 10 has to wait for the second machine, iPhone 5 (A6). The alternative is iPhone 4S (same screen as iPhone 4, can run iOS 5, but has a Qualcomm baseband and little documentation for its chip).
4. **Workload (one person plus AI sessions) [inferred]:** A5 to the iOS 9 home screen: optimistic 4 to 6 weeks, median 2.5 to 4 months; reaching "playable" adds half a month to 2 months; on top of that, iPhone 5 running iOS 10 adds 1 to 3 months. For comparison: the upstream author took only about 10 days to go from nothing to A4 running iOS 7, but he had existing iPod/3GS code, the A4 register documentation left by openiBoot and iEmu, and a real iPad he could tinker with freely; for A5 we lack all three, or have only part of them.
5. **Performance [inferred]:** with JIT, on iPhone 18 Pro, iOS 9 takes about 45 to 90 seconds to the lock screen, the idle home screen takes about half to most of one core, and dragging and paging are in the same class as iOS 7 today (30 to 60 fps); the experience is roughly like real devices running iOS 9/10 back then, which were sluggish anyway. Without JIT it is unusable.
6. **The three biggest risks:**
   ① **Storage**: PPN flash plus the IOP coprocessor plus Apple's Swiss PPN FTL format; upstream has no existing model, and FirmwareKit's NAND generator only knows A4's YAFTL format;
   ② **No real device for reference**: upstream did A4 by reading registers and taking NAND images and serial logs from a real iPad;
   ③ **Code signing and GL loading on iOS 9/10**: iOS 10's dyld only lets files override libraries in the cache when the shared cache is a "development shared cache", so our current way of installing the GL front end fails on iOS 10 and needs a different plan; whether AMFI on iOS 8 to 10 still honors the boot-args that relax signing is also unverified.
7. **Suggested first step:** send a session to do "step 0": download the iPod touch 5 9.3.5 (1.61 GB) and 7.1.2 (1.29 GB) firmware (requires user approval), decrypt the kernel and device tree with the public keys, inventory all device nodes, kexts and versions, answer the 6 open questions in section 6.4, and write no emulator code. After that, build the new machine skeleton on the Mac, with the target "the kernel prints on serial and stops at Waiting for root device".
8. **Things for the user to decide:** the step 0 download; whether to buy a used A5 device (iPod touch 5 or iPad mini 1, plus a Raspberry Pi Pico for checkm8) or A6 device (iPhone 5, checkm8 directly from the Mac) as a reference device; accepting long-term maintenance of machine code that upstream will not accept.

---

## 1. Which machine first

### 1.1 Candidates

| Machine (board) | Chip | CPU | GPU | RAM | Screen | System range | Baseband | Existing hardware documentation |
|---|---|---|---|---|---|---|---|---|
| iPhone 4S (n94ap) | A5 S5L8940X | 2×Cortex-A9 800 MHz | SGX543MP2 | 512 MB | 640×960 | 5.0 to 9.3.6 | Qualcomm MDM6610 | No dedicated documentation |
| iPad 2 (k93ap etc.) | A5 S5L8940X (iPad2,4 is 8942) | 2×A9 1 GHz | SGX543MP2 | 512 MB | 1024×768 | 4.3 to 9.3.5 / 9.3.6 | None on Wi-Fi models | No dedicated documentation |
| **iPod touch 5 (n78ap)** | **A5 S5L8942X** | 2×A9 800 MHz | SGX543MP2 | 512 MB | **640×1136** | **6.0 to 9.3.5** | **None** | Cascadia (same chip) |
| iPad mini 1 (p105ap etc.) | A5 S5L8942X | 2×A9 1 GHz | SGX543MP2 | 512 MB | 1024×768 | 6.0 to 9.3.5 / 9.3.6 | None on Wi-Fi models | Cascadia is this very device |
| iPad 3 (j1/j2) | A5X S5L8945X | 2×A9 1 GHz | SGX543MP4 | 1 GB | 2048×1536 | 5.1 to 9.3.5 / 9.3.6 | Some models | Little |
| iPhone 5 (n41ap/n42ap) | A6 S5L8950X | 2×Swift 1.3 GHz | SGX543MP3 | 1 GB | 640×1136 | 6.0 to 10.3.4 | Qualcomm MDM9615 | Only the A6X device tree map |
| iPhone 5c (n48/n49) | A6 S5L8950X | Same as above | Same as above | 1 GB | 640×1136 | 7.0 to 10.3.3 | Yes | Same as above |
| iPad 4 (p101 to p103) | A6X S5L8955X | 2×Swift | SGX554MP4 | 1 GB | 2048×1536 | 6.0 to 10.3.3 / 10.3.4 | Some models | Full map in Cascadia issue #6 |

- Chip, GPU, RAM, clock speed: the Wikipedia entries Apple A5 / Apple A6 **[verified]**.
- System range: the version directories in fwkeydb for iPhone4,1 (9A334 to 13G37), iPad2,1 (8F191 to 13G36), iPod5,1 (10A406 to 13G36), iPhone5,2 (10A405 to 14G61), iPad3,4 (10A407 to 14G61) **[verified]**; the ranges for iPad mini 1, iPad 3 and iPhone 5c are from public common knowledge **[inferred]**.
- A6X's CPU is Swift, touch is on spi3, the GPU is SGX554MP4, Wi-Fi is BCM4334 on HSIC: Cascadia issue #6, read by a contributor from a jailbroken iPad 4 (iOS 10.3.4) **[author's claim]**.

### 1.2 Why iPod touch 5 is recommended

1. **The most documentation.** On a real iPad mini 1 with the same chip, Cascadia worked out: the AIC1 interrupt controller and its timer, how the second core is released from reset (PMGR `+0x1214`, `+0x1220`; the core starts running at physical address 0), the PL310 L2, PMGR gating (`0x3F101008 + id×4`), the only 24 MHz free-running counter (in the PMGR watchdog block), the whole H2FMI plus PPN flash read path, Z2 touch power-up, I2C/SPI/GPIO, speaker, PMU, battery fuel gauge and the SGX543 power-up sequence, and also wrote a tool that converts Apple device trees (ADT) to Linux DTS. **[author's claim; the corresponding docs and driver files in the repository verified to exist]**
2. **No baseband.** Upstream's baseband model speaks the Infineon SPI protocol (used by iPhone 3GS/4), and the Qualcomm baseband of iPhone 4S/5 is completely different; an iPod needs no baseband activation and no hiding of CommCenter. **[inferred]**
3. **Screen shape.** 640×1136 leaves the smallest black bars on a modern iPhone; a tablet (1024×768) would be shrunk very small on a phone.
4. **The version ladder separates the problems.** iPod touch 5 starts at 6.0, and upstream has already got the 6.1.x and 7.1.2 user space (GL front end, activation, guest tool kit, read-only root partition) working on the A4 iPod touch 4 and iPhone 4. Use these two versions first to separate "machine model problems" from "new system problems", then climb to 8.4.1 and 9.3.5.

Drawbacks: it tops out at 9.3.5 (9.3.6 is only a GPS fix, which does not matter); the board-level peripherals (screen panel, PMU, audio codec) are not exactly the same as on the iPad mini, so the iPod 5's own device tree must be followed. The iPad mini 1 can serve as a "same-chip twin": for SoC-level problems, go straight to Cascadia.

**Alternative: iPhone 4S.** If the user would rather have an "iPhone" and iOS 5: the screen is the same as iPhone 4, and the app is ready for it; 5.1.1 to 7.1.2 can be compared version by version with the existing n90. The cost is turning off the Qualcomm baseband and handling iPhone activation; there is no direct documentation for S5L8940X (it is the 45 nm / 32 nm version of the same design as 8942, so the registers are most likely the same **[inferred]**). nexttouch picked exactly the 4S plus an iPad 2 Wi-Fi as its debugging twins **[author's claim]**.

**Only A6/A6X can run iOS 10.** iPhone 5 is the second machine. From A5 to A6: the CPU needs a Swift model (easy); a batch of peripherals change (L2 is no longer an external PL310, touch moved from spi1 to spi3, etc.); estimate it as "half a new SoC".

---

## 2. What hardware needs adding

### 2.1 Address layout: the base changed, many offsets did not

| Block | A4 (`include/hw/arm/s5l8930.h`) **[verified]** | A5 iPad mini 1 (Cascadia `ADDRESSES.md`) **[author's claim]** |
|---|---|---|
| DRAM | 0x40000000 | 0x80000000 |
| Interrupt controller | VIC0 0xBF200000 (4 PL192s) | AIC 0x3F200000 |
| PMGR | 0xBF100000 | 0x3F100000 |
| GPIO | 0xBFA00000 | 0x3FA00000 |
| UART0 | 0x82500000 | 0x32500000 |

The low 28 bits of PMGR, GPIO, UART0 and the interrupt controller are all the same; the blocks of Samsung lineage (UART, SPI, I2C, GPIO, the PMGR layout) seem to have moved along with the bus as a whole rather than being redesigned **[inferred]**. The A6X AIC is also at 0x3F200000 **[author's claim]**. In the ioreg of a real iPhone 4S, AIC is at 0xF200000 within arm-io, compatible string `aic,1` **[third-party real-device data (GitHub gist)]**.

### 2.2 Item by item

Difficulty: low = a few days at most, medium = one to several weeks, high = several weeks or more, with unknowns.

| Component | What A4 does now (qemu-ios) | What A5/A6 needs | Sources | Difficulty | Can it be left empty at first? |
|---|---|---|---|---|---|
| CPU | `cortex-a8`, single-core | A5: QEMU's existing `cortex-a9` (xnu identifies it as CPUFAMILY_ARM_14). A6: a new Swift model, instruction features after A15 (VFPv4, ARM/Thumb hardware divide, multiprocessing extensions), MIDR implementer 0x61, part number 0x0 | xnu `osfmk/arm/cpuid.h`, `cpuid.c`; the `swift` definition in LLVM `ARM.td` **[verified]** | Low | No |
| Dual-core | The machine already has two CPUs, AP plus IOP, `max_cpus = 2` | A5 has an SCU; the second core is released from reset by PMGR and starts running at physical 0; inter-core interrupts go through AIC. QEMU's ARM guest has `mttcg_supported = true`, and the two vCPUs each take one host thread | Cascadia `p105-smp-bringup.md`; `target/arm/cpu.c` **[verified]** | Medium | Yes: keep only cpu0 in the device tree and boot single-core first **[inferred]** |
| Interrupt controller | 4 daisy-chained PL192s | Write a new AIC model: xnu's open-source `AIC.h` gives all register names and offsets (Rev, Cap0, GlbCfg, MainTim, WhoAmI, Iack and its vector types, IPI set and clear, Tmr config and count); per-line masking and target core follow Cascadia's AIC1 driver | xnu `pexpert/pexpert/arm/AIC.h` **[verified]**; Cascadia `irq-apple-aic1.c` **[author's claim]** | Medium | No |
| System timer | Samsung timer in PMGR | On A5, iOS does not use the Cortex-A9 global timer; it uses the AIC timekeeping and the "shared timestamp" (the AppleInterruptController kext handles `kAICIackVecTypeTimer`); the PMGR watchdog block has a 24 MHz counter | Cascadia `p105-xnu-timer-re.md` **[author's claim]** | Medium | No |
| PMGR, clocks, power domains, frequency scaling | `s5l8930_pmgr.c` | A new PMGR: gating registers, clock table, performance states; KBoot's clock-frequencies table must be refilled for A5 | Cascadia `p105-pmgr-gates.md`, `p105-xnu-pmgr-extract.md`; device tree | Medium | Mostly yes: "treat every write as a success" |
| Chip ID, security info | chipid model | chip-id 0x8942/0x8950, board-id, security epoch; under kboot only what the kernel reads is needed | Device tree | Low | No |
| UART, SPI, I2C, GPIO, PWM | Samsung lineage, A4 has all of them | Addresses changed, registers most likely similar; from iOS 5 on the compatible strings changed to `*-1,samsung`, which upstream already adapted to on A4 for iOS 5 to 7 | Cascadia's `i2c-s5l8940x.c`, `spi-s5l8940x.c`, `pinctrl-s5l8940x-gpio.c` | Low to medium | No |
| PMU (power management chip, on I2C) | D1815 etc. | The iPad mini PMU is at 0x3c on I2C0; the exact iPod 5 model is still to be checked | Cascadia (backlight, charging and shutdown all go through it); device tree | Medium | Mostly can be stubbed |
| Display | `s5l8930_display.c` (DisplayPipe, CLCD, RGBOUT, DSIM, DART2) | A new-generation display pipeline; iPod 5 has a 640×1136 MIPI panel (A6X is eDP); QuartzCore picks the render server by the display driver's class name, so if the class name changes, the GL front end's display path must follow | Cascadia `p105-fb.md`; device tree | Medium to high | No, but it can first be simplified to a fixed framebuffer |
| GPU | SGX535 is not emulated: OpenGLES is replaced in the guest and calls are forwarded to the host (`contrib/gles-public` plus `hw/arm/gles-host*.c`) | Likewise do not emulate SGX543/554. To do: handle the sgx node in the device tree; the GL front end must recognize the OpenGLES and dispatch table of 8.x to 10.x (7.1.2 has 1035 slots, already derived automatically from @encode); report capability limits as SGX543; change the loading method for iOS 10 (3.4) | gles-public README **[verified]**; dyld source **[verified]** | Medium, high for iOS 10 | No: from iOS 7 on, without host GL SpringBoard crashes as soon as it creates a context (measured in step 4 of our M1) |
| **Storage** | H2FMI raw NAND plus IOP (runs the real IOP firmware by default); FirmwareKit generates YAFTL/VSVFL format flash images offline | A5 uses PPN flash (the controller is inside the chip, which reports itself as "PPN" 1.5.5). The iOS stack: `fmi,s5l8920x` → AppleIOPFMI (IOP coprocessor) → AppleSwissPPNFTL → disk0 → LwVM → HFS+. Needs: a new protocol on the IOP side or a new IOP model, the PPN command set, an offline generator for the Swiss PPN FTL format (or let the kernel self-format and then load the system) | Cascadia `p105-nand.md` (the full read path, command sequences) **[author's claim]**; the generator approach in upstream's `gap-nand-genesis-decision.md` **[verified]** | **High (the largest item)** | Early on a ramdisk can be used to boot (KBoot already supports md0), but the iOS 9 system partition is about 1.5 GB and does not fit in 512 MB of RAM, so only a trimmed system would work **[inferred]** |
| Crypto engine, data protection | CDMA's AES filter, SHA1, PKE; faked UID-derived keys | Location and protocol of the A5 AES/SHA blocks still to be checked; from iOS 8 on the data partition is encrypted per file, and the one-time keybag creation (`it_keybag`) must be brought along to 8 to 10 | Device tree, kernel | Medium to high | No: if /private/var cannot be mounted, SpringBoard is never reached |
| Touch | Zephyr2 (`ipod_touch_multitouch.c`) | Still Z2 (on spi1 on iPad mini, on spi3 on A6X, `AppleMultitouchSPIZ2F13`); firmware taken from the IPSW | Cascadia `p105-z2-boot.md` | Low to medium | No |
| Audio | CS42L61, Mikey, I2S, CDMA | A new codec and a new generation of I2S/DMA | Cascadia `p105-audio.md` | Medium | Yes, silent at first |
| USB | DWC OTG (usbmux/AFC), EHCI/OHCI | Also Synopsys dwc2; our app does not rely on usbmux | Cascadia | Low | Yes |
| Wi-Fi, Bluetooth | BCM4329, over the IOP SDIO ring | A5 has BCM4334, which on iPad mini goes over HSIC attached to EHCI, not SDIO | Cascadia | High | Yes (no network in the app at first) |
| Baseband | Infineon SPI model (n90) | iPhone 4S/5 use Qualcomm, so the model is unusable; iPod and the iPad Wi-Fi models have none | | High | Yes: change the node's compatible string to none in the device tree, as n90 does now |
| Sensors | Accelerometer, compass, light sensor | The iPad mini accelerometer is LIS3DSH; the gyroscope is new | Cascadia `p105-sensors.md` | Low to medium | Yes, with a fixed orientation at first |
| L2 cache | None | A5 has a PL310 (QEMU has an l2x0 model) plus Apple's own small CIF block; on A6 it is integrated into the memory subsystem | Cascadia | Low | No (the driver configures it) |
| Camera, ISP, JPEG, video decode | Partly | Leave empty | | | Yes |

### 2.3 How much weight each source carries

- **xnu open source** (32-bit ARM included from xnu-4570 on): gives the AIC registers, CPU identification and how the comm page is filled, but the S5L8940X/8950X board configurations were removed, leaving only the Apple Watch S7002/T8002. **[verified]**
- **Project Cascadia**: the most valuable public material for A5, from real hardware, GPL-2.0; its drivers can be referred to directly when writing models. Note that many of its register sequences were read by disassembling iBEC binaries that its users decrypted themselves, not from leaked source; our writing models from it counts as referring to the GPL code and documentation of a public project. Per the brief, the leaked iBoot source is not touched. **[repository contents verified; the conclusion is the author's claim]**
- **The device trees and kexts themselves**: the DeviceTree and kernelcache in the IPSW (keys are public) are the "ground truth" for each machine, and every step of upstream's A4 work was also read from them. Step 0 is about inventorying them.
- **theiphonewiki / theapplewiki**: neither site could be fetched this time (403, 504); fwkeydb and ipsw.me were used instead.

---

## 3. Boot chain and system

### 3.1 How qemu-ios boots today **[verified]**

Two routes:

1. **Real boot chain**: SecureROM → LLB → iBoot → kernel. The iPod touch 2nd generation needs Apple's bootrom (we got around the cold boot with a 4-byte placeholder); the iPad 1 can also go through the real iBoot-817 (upstream M8).
2. **kboot**: FirmwareKit's `KBoot.swift` does what iBoot does before jumping to the kernel: it decrypts the kernelcache; fills in the device tree the way iBoot does (memory map, chosen, clock table, identity information, MAC addresses, `nvram-proxy-data`); and builds boot_args (the version number is read from the kernel's own check; it is 3 from iOS 4.3 on). The machine puts this bundle into memory and jumps to the kernel entry with the MMU off. iPhone 4 and iPod touch 4 only use kboot. The pitfalls on iOS 6/7 (Epoch Mismatch, the kernel needing physical address 0 mapped, an endless loop caused by all-zero NVRAM proxy data) have all been solved in kboot (`docs/n90/README.md`).

kboot sets `debug-enabled`, `production-cert`, `secure-boot` and others in chosen to 1 (0 on real devices), and pairs that with the boot-args `amfi_allow_any_signature=1 cs_enforcement_disable=1`; only then will the kernel relax code signing, so that the GL front end and the agent in the guest can run (`KBoot.swift` lines 40 and 416).

### 3.2 Can A5/A6 do the same: yes, via kboot only

The iBoot route needs emulation of the DRAM controller, an accurate PMGR, and the signature and security epoch checks. When upstream tried iBoot-1219 (iOS 5) on A4, it got stuck at `miu_init: Epoch Mismatch` and in the PMU shutdown path (`docs/ipad1/ios5.md`) **[verified]**. What kboot must change for A5: memory base 0x80000000, memory size (512 MB / 1 GB), clock table, board ID and chip ID, display parameters, and the NOR/NVRAM handling in the device tree. **[inferred]**

### 3.3 Is there anything in 32-bit iOS 8 to 10 that blocks an emulator

| Item | Situation | Label |
|---|---|---|
| SEP (Secure Enclave) | Only from A7 on; A5/A6 have none | **[inferred (common knowledge)]** |
| KPP (Kernel Patch Protection) | Introduced in iOS 9, only on arm64 devices; the 32-bit kernel can be modified freely, at worst by having the emulator patch kernel memory at boot | **[third-party sources: iOSRE wiki, Promon]** |
| Personalized signing (IMG4, APTicket binding) | 32-bit always uses IMG3; kboot does not go through iBoot's signature check | **[verified: the A6 10.3.4 image file names in fwkeydb are still `.img3`]** |
| Code signing | In the A4 kernels 3.2 to 5.1.1, AMFI's four relaxing arguments only take effect when debug-enabled is nonzero, and 5.1.1 still reads them (the table in `docs/ipad1/ios5.md`); kboot already sets debug-enabled | 3.2 to 5.1.1 **[verified]**; whether 8 to 10 still read them **[inferred: real devices with development fuses need this, so most likely still there]**; if not, patch AMFI in the kernel the way jailbreaks do |
| Dedicated emulator detection | None found. The real risk is "a driver panics or hangs waiting for hardware", which is a model fidelity problem that also came up on A4 | **[inferred]** |
| File system | 32-bit devices upgrading to 10.3 do not convert to APFS and stay on HFS+. nexttouch's roadmap says A6 has to handle APFS; I think that is wrong | **[third-party report (MacStories) plus inference]** |
| Partitions | LwVM from iOS 5 on, already handled by upstream on A4 for 5 to 7 | **[verified]** |
| launchd | iOS 8 switched to a new launchd, and the way daemons and environment variables are loaded may have changed; upstream currently installs the guest tools by dropping plists into LaunchDaemons and changing SpringBoard's environment variables, which must be re-checked on 8 to 10 | **[inferred, to check in step 0]** |
| Activation | iPod needs no baseband; for 7.1.2 upstream uses a pre-baked activation state (FactoryActivated), which must be tried again on 8 to 10 | **[inferred]** |

### 3.4 How the GL front end gets installed on iOS 8 to 10 **[dyld source verified, ways out inferred]**

Current approach: put the OpenGLES built by gles-public in the system's original location, and add a `/System/Library/Caches/com.apple.dyld/enable-dylibs-to-override-cache` file; dyld then uses the library on disk instead of the copy in the shared cache (gles-public README).

The conditions for this switch in the dyld source:

| dyld version | System | Condition |
|---|---|---|
| 239.4 | iOS 7 | The file exists |
| 353.2.1 | iOS 8 | The file exists and is smaller than `ENABLE_DYLIBS_TO_OVERRIDE_CACHE_SIZE` |
| 360.22 | iOS 9 | Same as above |
| 421.2, 433.5 | iOS 10 | Changed to `dylibsCanOverrideCache()`: bit 0 of the comm page `_COMM_PAGE_DEV_FIRM` is 1, **and** the shared cache type is development |

**Correction (2026-11-02, step 0):** the iPod touch 5 9.3.5 actually ships dyld-390.7, which already has the iOS 10 check below, and its shared cache header has `cacheType` = 1, so the override switch already fails on 9.3.x; it does not start with iOS 10. See section 4.3 of `docs/research/ios8-10-step0.md`.

`_COMM_PAGE_DEV_FIRM` is filled in by the kernel with `PE_i_can_has_debugger(NULL)` (xnu `osfmk/arm/commpage/commpage.c` line 104), and kboot sets debug-enabled, so this condition can be met. But the official IPSW ships a production shared cache, **so the override does not take effect on iOS 10, while iOS 8 and 9 still work**.

Ways out for iOS 10 (none tried):

1. Use `DYLD_INSERT_LIBRARIES` to insert a library that uses interposing and take over the GL entry points. Need to confirm that AMFI does not strip the DYLD environment variables of system processes, and that app processes can be injected too.
2. Change the type field in the shared cache header. The cache carries a code signature, so this must go together with relaxed AMFI, or the emulator changes guest memory after the cache is mapped.
3. Hook in at a lower layer, for example by replacing SGX's gld driver bundle. From iOS 5 on, GLEngine and the SGX driver are both in the shared cache (`docs/ipad1/ios5.md`: "bundle dirs empty on disk"), so this probably does not work.

Estimate for the iOS 10 piece alone: 1 to 2 weeks **[inferred]**.

### 3.5 How public the firmware keys are

| System | A5 (4S, iPad 2, iPod 5, iPad mini) | A6 (iPhone 5), A6X (iPad 4) | Source |
|---|---|---|---|
| iOS 5 to 7 | Every version | Every version from 6 to 7 | fwkeydb version directories **[verified]** |
| iOS 8.4.1 (12H321) | Kernel, device tree and iBoot have keys; ipsw.me has no root filesystem key | Same as left | ipsw.me, fwkeydb **[verified]** |
| iOS 9.3.5 (13G36) | All 16 images have KBAGs and keys; ipsw.me has root filesystem keys for 4S, iPad 2, iPod 5, iPad mini | Image keys exist; no root filesystem keys for iPhone 5 and iPad 3 | Same as above **[verified]** |
| iPhone 4S 9.3.6 (13G37) | fwkeydb has them | | **[verified]** |
| iOS 10.0 to 10.3.4 | Not applicable | **None of the 16 images has a KBAG, i.e. they are not encrypted** (14A403, 14G61, and iPad3,4's 14G61 all checked); ipsw.me has no entry for 14G61, and lists entries for 14A403 to 14G60 but with empty keys, for the same reason | fwkeydb, ipsw.me **[verified]** |

- The few missing root filesystem keys: the iOS 8/9 root filesystem keys have historically been computable from the decrypted restore ramdisk with a public tool (genpass) **[inferred, to verify in step 0]**; the iOS 10 root filesystem is not encrypted **[inferred]**.
- nexttouch's roadmap lists "no public keys for iOS 10 on A6" as an open question and says they may have to be extracted from a real device with checkm8 **[author's claim]**. Per the fwkeydb data, this already has an answer: no keys are needed at all.
- As now, the app stores only keys and Apple's download URLs, downloads and decrypts on the phone itself, and we distribute nothing of Apple's (Light Touch's firmware table has a `keys` field) **[verified]**.
- Real-device checkm8: A6/A6X can use ipwndfu directly (it supports s5l8950x and s5l8955x); A5/A5X are on ipwndfu's "future support" list, and in practice need checkm8-a5 with an Arduino plus a USB Host Shield or a Raspberry Pi Pico (Cascadia uses the Pico) **[verified: ipwndfu README, Legacy-iOS-Kit wiki]**. Only needed when reading registers or taking NAND images from a real device.

---

## 4. How much has been done before

| Project | What it did | Relation to A5/A6 and 32-bit iOS 8 to 10 | Label |
|---|---|---|---|
| c12n/nexttouch | Repository created 2026-11-01, v0.1.0 released the same day: a catalog, menus and settings written in Rust, with three shells for Windows/Android/iOS; all iOS 8/9/10 entries marked "Not booting yet" | Only a roadmap (4S 9.3.5, iPhone 5 10.3.4, six boot milestones), no engine code in the repository; the author says plainly "no new emulation yet" and "qemu-ios engine implements no SoC newer than the A4" | Repository contents **[verified]**; plans **[author's claim]** |
| samhenrigold/qemu-ios, LightTouchMac | 8 machines, up to A4 and iOS 7.1.2 | The README states plainly that there will be no machines newer than those listed and no iOS version; all 329 firmware table entries are for these 8 boards, with no A5/A6 entries and no "coming_soon" | **[verified]** |
| blake-lucas/LightTouch, blake-lucas/qemu-ios | A fork of Light Touch that runs on Android, Linux, Windows and macOS; did many engine speedups (the most recent upstream commits were ported from here) | Only up to iOS 7, no iOS app, no A5 | **[verified (README)]** |
| mada-02/iOS-Emulator | "An iOS 1-7 emulator" | None | **[verified (repository description)]** |
| devos50/qemu-ios | iPod touch 1st and 2nd generation, the origin of qemu-ios | None | **[verified (earlier research); nothing A5-related found]** |
| rzxvx/Project-Cascadia | Runs mainline Linux 6.12 on the A5 iPad mini 1: dual-core, interrupts, timers, touch, Wi-Fi, Bluetooth, audio, XFCE, read-only NAND, an SGX543 kernel driver plus Mesa; also A13; issue #6 has an A6X hardware map | Not an emulator, but the best public material on A5 hardware | Repository contents **[verified]**; features **[author's claim]** |
| winocm/xnu (2013 to 2017) | Ported the open-source Darwin kernel to ARMv7/ARMv6/AArch64; it runs on QEMU development boards | Only the open-source kernel, not iOS kernelcaches or the iOS system | **[verified (repository description)]** |
| Corellium (commercial) | Virtual iPhones | Oldest model iPhone 6, lowest version iOS 10, no 32-bit | **[verified (official support page)]** |
| QEMUAppleSilicon, qemu-t8030, Inferno-iOS, alephsecurity xnu-qemu-arm64 | 64-bit models such as iPhone 6s/X/11 | 64-bit, irrelevant to us; qemu-t8030 patches AMFI directly in the kernel rather than relying on boot-args | **[verified (earlier research and the qemu-t8030 wiki)]** |
| iEmu, QEMU-s5l89xx-port (2012) | Early attempts to emulate S5L89xx | Failed, never reached A5 | **[third-party (Emulation General Wiki)]** |

Search scope: GitHub code search for `s5l8940` and `s5l8950` (only jailbreak tools, bootrom exploit tools and documentation); GitHub repository search; web searches for "QEMU A5 S5L8940 iPhone 4S", "32-bit iOS 9/10 emulation" (`32 位 iOS 9/10 模拟`) and so on. **No public A5/A6 emulator was found, and no public record of 32-bit iOS 8 to 10 booting in an emulator.**

---

## 5. Performance

### 5.1 Existing data (iPhone 4, A4 single-core, iOS 7.1.2) **[verified]**

| Item | Value | Source |
|---|---|---|
| Mac M4 Max, JIT, boot to lock screen | 40 seconds (guest main core 35.5 CPU seconds) | `docs/reports/m0-mac-benchmark.md` |
| Mac, pure interpreter (TCI), boot to lock screen | 407 seconds (11.2 times) | Same as above |
| iPhone 18 Pro, JIT, to lock screen / to home screen | 29 seconds / 37 seconds | `docs/reports/m2-gl-eagl.md` |
| 18 Pro, idle home screen | 41% of one core (readback about 13%, guest about 20%, compositing and frame presentation about 7%) | `docs/reports/m2-ios7-perf.md` |
| 18 Pro, lock screen drag / home screen press and drag / page animation | 60 / 49 / 36 fps | Same as above |
| App memory footprint | 1.03 to 1.11 GB (guest 512 MB) | `docs/reports/m2-gl-eagl.md` |

### 5.2 Estimates **[inferred]**

Assumptions:

- Under JIT one guest core runs at roughly the speed of a real A4 (on the 18 Pro, iOS 7 reaches the lock screen in 29 seconds, the same order as a real iPhone 4 back then).
- The total work of booting iOS 9 is about 1.5 to 2 times that of iOS 7, and part of it can go to the second core.
- With dual-core there are two vCPU threads, plus the QEMU main thread and the app main thread; the A20 Pro probably has 2 performance cores plus 4 efficiency cores, so some threads will be pushed onto efficiency cores; GL forwarding also runs on the vCPU threads.
- Readback cost scales with pixels: 640×1136 is 18% more than 640×960.

| | iOS 9.3.5 (iPod touch 5, A5 dual-core) | iOS 10.3.4 (iPhone 5, A6 dual-core, 1 GB) |
|---|---|---|
| Boot to lock screen | 45 to 90 seconds | 50 to 100 seconds |
| Idle home screen CPU (one core = 100%) | 50% to 80% | 55% to 90% |
| Dragging, paging | 30 to 60 fps, mainly limited by GL readback | Same as left |
| Opening an app | 2 to 4 seconds | 2 to 5 seconds |
| App memory | About 1.1 GB | About 1.6 to 1.8 GB |
| Without JIT | Boot takes over ten minutes, unusable | Same as left |

Notes:

- The two vCPU threads will share the JIT code region, which may need to grow from 256 MB to 512 MB; StikDebug's preparation time would go from about 0.7 seconds to 1.5 seconds.
- It is also possible to emulate just one core (keep only cpu0 in the device tree): fewer threads, possibly friendlier to the phone; only testing will tell which is better.
- On iPhone 14 Pro it is roughly twice as slow again, and iOS 10's 1 GB of guest memory will be tight.
- On real hardware, iOS 9 on a 4S and iOS 10 on an iPhone 5 were slow to begin with; expectations for the "nostalgia" experience must be made clear to the user.

---

## 6. Conclusion and roadmap

### 6.1 Can it be done

Yes. No item is "impossible in principle": the firmware can be decrypted, the kernel can be booted directly, there is no SEP and no KPP, the CPU model already exists, and the GPU goes through forwarding. The question is whether it is worth it and how long it takes. This is a complete new SoC port, plus the big job of storage, plus the iOS 10 GL loading problem.

### 6.2 Workload **[inferred]**

| Phase | Content | Deliverable | Optimistic | Median |
|---|---|---|---|---|
| 0 | Unpack, inventory the device tree and kexts, answer the questions in section 6.4 | Inventory document | 1 session | 1 to 2 days |
| 1 | Machine skeleton: single-core A9, AIC and timer, PMGR stub, UART, chipid, kboot changed for A5 | Kernel banner, stops at Waiting for root device | 1 week | 2 to 3 weeks |
| 2 | Storage: IOP, FMI, PPN or an alternative, FTL generation or self-formatting, AES and keybag, PMU | launchd running, /private/var mounted | 2 to 3 weeks | 1 to 2 months |
| 3 | Display pipeline, GL front end climbing from 7.1.2 to 8.4.1 and 9.3.5, touch, activation, guest tool kit | SpringBoard shows a picture and responds to taps | 1 to 2 weeks | 3 to 6 weeks |
| 4 | Dual-core, sound, buttons, sleep and wake, stability | Playable | 1 to 2 weeks | 3 to 6 weeks |
| 5 | Hook into the iPhone app: multithreaded TCG plus JIT, memory | iOS 9 boots on the phone | A few days | 1 to 2 weeks |
| 6 | A6: Swift model, A6 peripheral differences, iOS 10 GL loading | iPhone 5 runs iOS 10 | 3 to 4 weeks | 2 to 3 months |

Total: A5 to the iOS 9 home screen, optimistic 4 to 6 weeks, median 2.5 to 4 months; playable adds another half month to 2 months; A6 and iOS 10 add another 1 to 3 months. At our current pace of "one session advances one small milestone", A5 to playable is about 40 to 100 execution sessions.

Reference points for the estimate:

- **Upstream A4**: the `ipad1` machine was created on 2026-09-26, iOS 3.2 reached the home screen on 09-27 (329 commits that day), and on 10-05 the iPhone 4 on iOS 7.1.2 passed the full set of checks: about 10 days. The preconditions were existing iPod/3GS code, the A4 register documentation from openiBoot and iEmu, and a real iPad (limera1n to read registers and dump NAND and the system partition). **[verified: git log, `docs/archive/ipad1-PLAN.md`]**
- **Upstream 3GS / iPod touch 3rd generation machines**: first commit on 10-04, kernel to launchd the same day (the same SoC generation already had documentation). **[verified]**
- **Cascadia**: repository created on 2026-08-11, worked things out step by step on a real device using checkm8, and only got the GPU to draw something in early October. **[creation date verified, progress is the author's claim]**
- **Ourselves**: M0 to M2 took two days to get through porting, JIT, EAGL and tuning, but that was on an existing machine.

### 6.3 The three biggest risks

1. **Storage (the biggest).** A4's route is: H2FMI raw NAND, the IOP running the real firmware, FirmwareKit generating YAFTL format images offline. A5 switched to PPN plus Swiss PPN FTL; upstream has no model, and Cascadia only did read-only access. Either write a Swiss PPN FTL generator, or let the kernel self-format with `nand-enable-reformat` and then find a way to load the system, or find a shortcut (see question 2 in 6.4: if the A5 kernel still includes the YAFTL stack, could it be made to treat the emulated flash as raw NAND, so the existing generator can be reused directly).
   Mitigation: early on, boot to launchd with a ramdisk, and work on storage in parallel.
2. **No real device for reference.** Every time upstream got stuck, it could go to a real iPad to read register values and compare logs; we have only the device trees, kernel disassembly and Cascadia's notes.
   Mitigation: buy a used iPod touch 5 or iPad mini 1 (price not checked), plus a Raspberry Pi Pico for checkm8-a5 (Cascadia's whole tool set can be used directly); or buy an iPhone 5 (checkm8 directly from the Mac, which also prepares for A6). The user has to decide this.
3. **Code signing and GL loading changed in 9 and 10.** iOS 10's dyld no longer lets files override a production shared cache (3.4), so the GL front end needs a different install method; whether AMFI honors the boot-args on 8 to 10 is unverified, and if it does not, the kernel has to be patched (32-bit has no KPP, so it is doable, but the location has to be found for each version, which violates upstream's "no hand-patching by offset" principle, so it would have to be found automatically by byte pattern).

Other things worth noting: thread contention from dual-core on the phone (5.2); we would have to maintain, long term, a set of machine code that upstream will not accept (the scope statement in the upstream README is very firm); nexttouch claims to be doing the same thing and is currently an empty shell.

### 6.4 Suggested first step

**Step 0 (one session, needs user approval to download about 2.9 GB):** download the iPod touch 5 9.3.5 (13G36, 1.61 GB) and 7.1.2 (11D257, 1.29 GB) from Apple's servers, decrypt the kernelcache, device tree and restore ramdisks with the public keys, and answer these 6 questions:

1. The `compatible`, `reg` and `interrupts` of every node in the device tree, compared item by item with iPhone 4 7.1.2: which drivers were renamed and which blocks are new.
2. The NAND stack in the kernelcache: besides AppleSwissPPNFTL, does it still include AppleNANDFTL (YAFTL/VSVFL)? Which version are the IOP firmware and the mailbox protocol? If the A5 kernel can be made to use the emulated flash as raw NAND, FirmwareKit's A4 generator can be reused directly, saving the biggest piece of work.
3. Does AMFI still read `amfi_allow_any_signature`, `cs_enforcement_disable` and `amfi_get_out_of_my_way` (FirmwareKit's FitCheck does exactly this string check).
4. Is the `__GLIFunctionDispatchRec` @encode of OpenGLES still in the shared cache; which display driver class name does QuartzCore recognize.
5. How the iOS 9 launchd loads daemons and environment variables (this decides how the guest tools are installed).
6. Can the root filesystem keys missing for 8.4.1 and 9.3.5 be computed from the ramdisks with public tools.

**Step 1 (on the Mac, 1 to 3 weeks):** build a new A5 machine skeleton (single-core Cortex-A9, AIC plus timer, PMGR stub, UART, chipid), and make kboot support the A5 memory layout. Target: both the iPod touch 5 9.3.5 and 7.1.2 kernels print a banner on serial and stop at Waiting for root device. This step touches neither the phone nor the app.

### 6.5 Things the user needs to decide

1. Whether to do it: this is a long-term track measured in months, and it does not block M2 to M4.
2. The step 0 download (about 2.9 GB, from Apple's servers).
3. First machine: iPod touch 5 (recommended) or iPhone 4S.
4. Whether to buy a reference device: a used iPod touch 5 / iPad mini 1 plus a Raspberry Pi Pico, or an iPhone 5.
5. Where the code goes: under the current rules, the A5 machine goes into `patches/` as patches; upstream will not accept it, and maintaining it ourselves under the GPL is no problem.

---

## 7. Sources

Local (read-only):

- `upstream/qemu-ios`: `README.md`, `docs/n90/README.md`, `docs/ipad1/README.md`, `docs/ipad1/ios5.md`, `docs/archive/ipad1-PLAN.md`, `docs/research/ref-a4-soc.md`, `docs/research/web-sgx.md`, `docs/research/gap-unsigned-guest-code-3.2.md`, `docs/research/gap-nand-genesis-decision.md`, `contrib/gles-public/README.md`, `include/hw/arm/s5l8930.h`, `hw/arm/ipad1.c`, `hw/arm/s5l8930_h2fmi.c`, `target/arm/tcg/cpu32.c`, `target/arm/cpu.c`, `accel/tcg/tcg-all.c`, and `git log`.
- `upstream/LightTouchMac`: `README.md` (Scope), `LightTouchMac/Resources/firmware-catalog.json`, `Packages/FirmwareKit/Sources/FirmwareKit/KBoot/KBoot.swift`.
- This repository: `docs/plan.md`, `docs/research/m1-iphone-feasibility.md`, `docs/reports/m0-mac-benchmark.md`, `docs/reports/m2-gl-eagl.md`, `docs/reports/m2-ios7-perf.md`.

GitHub (`gh api`):

- [apple-oss-distributions/xnu @ xnu-4570.1.46](https://github.com/apple-oss-distributions/xnu/tree/xnu-4570.1.46): `pexpert/pexpert/arm/AIC.h`, `board_config.h`, `osfmk/arm/cpuid.h`, `cpuid.c`, `osfmk/arm/commpage/commpage.c`, `pexpert/arm/pe_identify_machine.c`
- [apple-oss-distributions/dyld](https://github.com/apple-oss-distributions/dyld): `src/dyld.cpp` @ dyld-239.4, 353.2.1, 360.22, 421.2, 433.5
- [tihmstar/fwkeydb](https://github.com/tihmstar/fwkeydb): `keys/firmware/iPhone5,2/0x8950/*`, `iPhone4,1/0x8940/*`, `iPad2,1/0x8940/*`, `iPod5,1/0x8942/*`, `iPad3,4/0x8955/*`
- [rzxvx/Project-Cascadia](https://github.com/rzxvx/Project-Cascadia): README, `docs/research/ADDRESSES.md`, `p105-nand.md`, `p105-xnu-timer-re.md`, [issue #6 (A6X hardware map)](https://github.com/rzxvx/Project-Cascadia/issues/6)
- [c12n/nexttouch](https://github.com/c12n/nexttouch): README, `docs/ROADMAP.md`, file tree
- [blake-lucas/LightTouch](https://github.com/blake-lucas/LightTouch), [mada-02/iOS-Emulator](https://github.com/mada-02/iOS-Emulator), [devos50/qemu-ios](https://github.com/devos50/qemu-ios), [winocm/xnu](https://github.com/winocm/xnu)
- [axi0mX/ipwndfu](https://github.com/axi0mX/ipwndfu): README (SoCs supported by checkm8)
- [llvm/llvm-project @ llvmorg-17.0.6 `ARM.td`](https://github.com/llvm/llvm-project/blob/llvmorg-17.0.6/llvm/lib/Target/ARM/ARM.td): the `swift` processor definition

Web:

- [ipsw.me API](https://api.ipsw.me/v4/keys/ipsw/iPhone5,2/14G61) (keys and firmware metadata)
- [Apple A5 - Wikipedia](https://en.wikipedia.org/wiki/Apple_A5), [Apple A6 - Wikipedia](https://en.wikipedia.org/wiki/Apple_A6)
- [ioreg from iPhone 4S (gist)](https://gist.github.com/fergy/3844426)
- [Corellium iOS support page](https://support.corellium.com/devices/ios)
- [qemu-t8030 wiki: Bringing up the emulator](https://github.com/TrungNguyen1909/qemu-t8030/wiki/Bringing-up-the-emulator)
- [Legacy-iOS-Kit wiki: checkm8-a5](https://github.com/LukeZGD/Legacy-iOS-Kit/wiki/checkm8-a5)
- [iOSRE wiki: Kernel Patch Protection](https://github.com/kpwn/iOSRE/blob/master/wiki/Kernel-Patch-Protection-(KPP).md), [Promon jailbreak overview](https://promon.co/?p=1338)
- [iOS 10.3 and APFS (MacStories excerpt)](https://pxlnv.com/linklog/apple-releases-ios-10-3/)
- [Emulation General Wiki: iOS emulators](https://emulation.gametechwiki.com/index.php/IOS_emulators)
