#!/usr/bin/env python3
"""Build a K48KBOOT bundle for the iPod touch 5G (N78AP, A5) from n78_unpack.py's output.

    n78_kboot.py DECDIR OUT [extra boot-args]

Everything is imgtools/ipad1_kboot.py (qemu-ios, at 22f4f72746^); this only swaps in what the A5 does
differently: DRAM at 0x80000000 (the 7.x/9.x kernels link at 0x80001000, so V=P), the N78 board (640x1136
Retina panel, 512 MiB), platform-name/chip-id, and the blocks step 1 has no model for hidden from their
drivers (compatible "none", as ipad1_kboot does to the A4's SGX). One CPU: cpu1 is unmatched, the AIC told
it has one main CPU, and cpus=1 passed.
"""
import hashlib, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# imgtools as of qemu-ios 22f4f72746^: next to this script, or where tools/a5/README.md unpacks it.
IMGTOOLS = os.environ.get("IMGTOOLS") or next(
    (p for p in (os.path.join(HERE, "imgtools"), os.path.join(HERE, "../../work/a5/imgtools"))
     if os.path.isdir(p)), os.path.join(HERE, "imgtools"))
sys.path.insert(0, IMGTOOLS)
import ipad1_kboot as kb  # noqa: E402

kb.PHYS_BASE = 0x80000000
kb.BOARDS["n78"] = {"machine": "iPod-Touch-5G", "fb": (640, 1136), "rotation": 0, "scale": 2,
                    "board-id": 0x00, "model": "MD717", "dram": 0x20000000}

HIDDEN = ["cpus/cpu1", "arm-io/iop", "arm-io/flash-controller0", "arm-io/ae2", "arm-io/sgx",
          "arm-io/isp", "arm-io/vxd"]
# N78_HIDE=arm-io/a,arm-io/b: hide more nodes for one build, while bring-up finds which ones block boot.
HIDDEN += [p for p in os.environ.get("N78_HIDE", "").split(",") if p]
BOOT_ARGS = kb.DEFAULT_BOOT_ARGS + " cpus=1"

_fill_dt = kb.fill_dt

# The CPU's performance states as n78's iBoot-1940 pmgr_update_device_tree (0x9ff1f82c in 11D257) fills
# them. Its tables (0x9ff41b0c, 0x9ff41b18) give each state a clock source and a divider: (1, 2), (2, 1),
# (1, 1). voltage-states1[i] is {the CPU clock period in ns, 16.16 fixed point, 0}: divider * 1e9 << 16 /
# the source's Hz. cpu-clk-cfgs[i] is the PMGR+0x38 CPU clock config for the state: source in bits 28-29,
# divider in bits 0-4, the rest kept from the live register (0 here). Left zero, the kernel finds no states
# and IOReporter panics "can't free 1 channels of dimension 0". iPad 2's ioreg (1 GHz A5) reads periods
# 2.0, 1.25, 1.0, i.e. source 1 = 1 GHz, source 2 = 800 MHz. N78 runs at 800 MHz (its DT's
# nominal-performance1 is 0x14000, 1.25 ns), so source 1 is taken as 800 MHz; source 2's 600 MHz is a guess.
CPU_SOURCE_HZ = {1: 800_000_000, 2: 600_000_000}
CPU_STATES = [(1, 2), (2, 1), (1, 1)]
# /cpus/cpu0 as iPad 2's ioreg has them, the CPU at N78's 800 MHz; fixed and timebase are the 24 MHz crystal.
CPU0_HZ = {"clock-frequency": 800_000_000, "bus-frequency": 250_000_000, "memory-frequency": 400_000_000,
           "peripheral-frequency": 102_600_000, "fixed-frequency": 24_000_000, "timebase-frequency": 24_000_000}


def fill_cpu_perf(dt):
    vs1 = b"".join(struct.pack("<II", (div * 10**9 << 16) // CPU_SOURCE_HZ[src], 0) for src, div in CPU_STATES)
    cfgs = struct.pack("<3I", *[(src << 28) | div for src, div in CPU_STATES])
    dt.set("arm-io/pmgr", "voltage-states1", vs1)
    dt.set("arm-io/pmgr", "cpu-clk-cfgs", cfgs)
    for key, hz in CPU0_HZ.items():
        dt.set("cpus/cpu0", key, hz)


def fill_dt(dt, memory_map, ident, iboot=kb.IBOOT_VERSION, root_matching=kb.ROOT_MATCHING):
    _fill_dt(dt, memory_map, ident, iboot, root_matching)
    dt.set("", "platform-name", "s5l8942x")
    dt.set("chosen", "chip-id", 0x8942)
    for path in HIDDEN:
        if path in dt.props and "compatible" in dt.props[path]:
            dt.set(path, "compatible", "none")
    dt.set("arm-io/aic", "#main-cpus", 1)
    fill_cpu_perf(dt)
    # The dock port powered as a built-in one (port-type 0), not left off until a host cable (2): what the
    # A4 machine does to 6.x/7.x DTs (hw/arm/ipad1.c, docs/ipad1/usb-keyboard.md), so the EHCI sees a
    # device on port 1 (-device usb-storage,bus=ehci.0).
    port1 = "arm-io/usb-complex/usb-ehci/usb-ehci-port1"
    if port1 in dt.props and "port-type" in dt.props[port1]:
        dt.set(port1, "port-type", 0)
    # Device mode from the start, as on a Mac's cable: the arbitrator takes a no-pmu usb-complex as
    # "USBHost" (AppleEmbeddedUSBArbitrator::start, docs/ipad1/usb-keyboard.md) and publishes the OTG
    # device nub, where it otherwise waits for the PMU's cable detect (the D1881 model reports Detached).
    # Without it restored_external finds no device configuration ("enable_usb_connections failed") and exits.
    if "arm-io/usb-complex" in dt.props and "no-pmu" not in dt.props["arm-io/usb-complex"]:
        dt.add("arm-io/usb-complex", "no-pmu")
    # iBoot puts 64 bytes of entropy here; 9.3.5 panics "EntropyData needed 64 bytes, but got 0" on the
    # IPSW's zeros. Derived from the unit's ECID so a boot is reproducible.
    dt.set("chosen", "random-seed", hashlib.sha512(b"n78-random-seed" + ident["unique-chip-id"].encode()).digest())
    # Bit 31 of a property's length marks a slot iBoot fills from syscfg and clears the bit on. The 9.3.5 DT
    # ships two (chosen/marketing-{hardware,software}-behavior); the kernel's property walk adds the raw length,
    # so a set bit sends it 2 GiB past the tree (data abort at 0x8038783c, DFAR 0x0124dbbc). 7.1.2 has none.
    for props in dt.props.values():
        for off, _ in props.values():
            raw = struct.unpack_from("<I", dt.buf, off + 32)[0]
            if raw & 0x80000000:
                struct.pack_into("<I", dt.buf, off + 32, raw & 0x7FFFFFFF)


kb.fill_dt = fill_dt


def main(dec, out, extra=""):
    dt_blob = open(os.path.join(dec, "DeviceTree.bin"), "rb").read()
    ident = kb.synth_identity("n78-default", board="n78")
    args = BOOT_ARGS + (" " + extra if extra else "")
    # N78_RAMDISK=path: boot that raw HFS+ image as md0 (ipad1_kboot puts it after the kernel, adds rd=md0
    # and empties root-matching), e.g. n78_unpack.py's RestoreRamDisk.dmg.
    rd_path = os.environ.get("N78_RAMDISK")
    ramdisk = open(rd_path, "rb").read() if rd_path else None
    image, load_pa, entry_pa, args_pa = kb.build(os.path.join(dec, "kernelcache.mach"), dt_blob, args, ident,
                                                 kb.iboot_version(dec), ramdisk)
    # iBoot's boot logo: AppleLogo.bin (n78_unpack.py) centred on black in vram, which boot_args and the
    # machine's display (fb-base) both point at; the loader copies the segments into DRAM at every reset.
    logo = os.path.join(dec, "AppleLogo.bin")
    board = kb.BOARDS["n78"]
    segments = kb.logo_segments(open(logo, "rb").read(), kb.layout(board)[1], board) if os.path.exists(logo) else []
    with open(out, "wb") as f:
        f.write(image + kb.pack_segments(segments) + kb.TRAILER.pack(b"K48KBOOT", load_pa, entry_pa, args_pa,
                                                                      len(image)))
    top = struct.unpack_from("<I", image, args_pa - load_pa + 0x10)[0]
    print(f"load {load_pa:#x}+{len(image):#x} entry {entry_pa:#x} r0 {args_pa:#x} "
          f"topOfKernelData {top:#x} boot-args [{args}]")


if __name__ == "__main__":
    main(*sys.argv[1:4])
