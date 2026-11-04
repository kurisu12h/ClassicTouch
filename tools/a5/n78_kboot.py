#!/usr/bin/env python3
"""Build a K48KBOOT bundle for the iPod touch 5G (N78AP, A5) or the iPhone 5 (N41AP, A6) from n78_unpack.py's
output. The board is the DT's (its compatible, ipad1_kboot.dt_board): the iPhone 5 differs in its machine,
1 GiB, platform s5l8950x / chip 0x8950, its Swift cores' clocks and a baseband to hide (docs/reports/a6-step1.md).

    n78_kboot.py DECDIR OUT [extra boot-args]

N78_TRUST=a.txt,b.txt (n41, 14G61): add those CDHashes (tools/a5/cdhash.py output) to the kernel's static
trust cache first (tools/a5/n41_trustcache.py; N78_TRUST_KEEP overrides its keep files), since iOS 10's AMFI
takes no ad hoc signature it has not been told about.

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
kb.BOARDS["n41"] = {"machine": "iPhone-5", "fb": (640, 1136), "rotation": 0, "scale": 2,
                    "board-id": 0x00, "model": "MD297", "dram": 0x40000000}
# platform-name and chip-id, and what else each board hides: the iPhone 5's Qualcomm baseband (top-level
# "baseband", AppleBasebandN41) has no model.
SOC = {"n78": ("s5l8942x", 0x8942), "n41": ("s5l8950x", 0x8950)}
# The A6's two JPEG blocks: AppleJPEGHal's reset polls them 10,000 times each and gives up (a6-step1.md 3).
BOARD_HIDDEN = {"n78": [], "n41": ["baseband", "arm-io/jpeg0", "arm-io/jpeg1"]}

# The two M2 scalers: nothing models them, and 9.3.5's SpringBoard panics the kernel resetting scaler 0 (3.17.4).
HIDDEN = ["cpus/cpu1", "arm-io/iop", "arm-io/flash-controller0", "arm-io/ae2", "arm-io/sgx",
          "arm-io/isp", "arm-io/vxd", "arm-io/scaler0", "arm-io/scaler1"]
# N78_HIDE=arm-io/a,arm-io/b: hide more nodes for one build, while bring-up finds which ones block boot.
HIDDEN += [p for p in os.environ.get("N78_HIDE", "").split(",") if p]
# N78_SHOW=arm-io/iop,...: give hidden nodes back to their drivers for one build.
HIDDEN = [p for p in HIDDEN if p not in os.environ.get("N78_SHOW", "").split(",")]
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
# The iPhone 5's Swift cores run at 1.3 GHz: the same table with that as source 1. Nothing here is read off
# an A6 iBoot yet; it only has to give the kernel well-formed states.
CPU_SOURCE_HZ_A6 = {1: 1_300_000_000, 2: 800_000_000}
CPU0_HZ_A6 = dict(CPU0_HZ, **{"clock-frequency": 1_300_000_000})


def fill_cpu_perf(dt, board="n78"):
    src_hz, cpu0 = (CPU_SOURCE_HZ_A6, CPU0_HZ_A6) if board == "n41" else (CPU_SOURCE_HZ, CPU0_HZ)
    vs1 = b"".join(struct.pack("<II", (div * 10**9 << 16) // src_hz[src], 0) for src, div in CPU_STATES)
    cfgs = struct.pack("<3I", *[(src << 28) | div for src, div in CPU_STATES])
    dt.set("arm-io/pmgr", "voltage-states1", vs1)
    if "cpu-clk-cfgs" in dt.props["arm-io/pmgr"]:      # the A6's pmgr has none (boost-performance0/1 instead)
        dt.set("arm-io/pmgr", "cpu-clk-cfgs", cfgs)
    for key, hz in cpu0.items():
        dt.set("cpus/cpu0", key, hz)


# The PPN NAND iBoot would have probed (its nandid.c fill, 0x9ff22338 in n78's iBoot-1940): the props it
# writes into flash-controller0/disk, the PPN ones from the device's parameter page. No unit has been read;
# this is a small device of our own that keeps inside the IOP firmware's _validate_device_parameters ranges
# (H2fmi_ppn.c, 0x7374 in 11D257's IOP image): one bus, one CE of 2 CAUs x 0x420 blocks x 128 pages x 8 KiB
# (2.2 GB), 32 bytes of metadata a page. hw/arm/s5l8940_iop.c serves the same geometry.
N78_NAND = {"#ce": 1, "ce-bitmap": 1, "#databus": 1, "#ce-blocks": 2 * 0x420, "#block-pages": 128,
            "#page-bytes": 0x2000, "#spare-bytes": 0x20, "#die-ce": 1, "bbt-format": 0, "vendor-type": 0,
            "ecc-threshold": 0, "ecc-correctable": 0, "read-setup-clks": 1, "read-hold-clks": 1,
            "read-dccycle-clks": 0, "write-setup-clks": 1, "write-hold-clks": 1,
            "meta-per-logical-page": 0x10, "valid-meta-per-logical-page": 0x10, "logical-page-size": 0x1000,
            "toggle-device": 0, "ppn-device": 1, "ppn-spec-version": 0x10500, "blocks-cau": 0x420, "caus-ce": 2,
            "slc-pages": 64, "mlc-pages": 128, "match-oddeven-caus": 0, "cau-bits": 1, "page-bits": 7,
            "block-bits": 11, "max-transaction-size": 32, "retire-on-invalid-refresh": 0}
N78_NAND_READID = bytes([0x98, 0xde, 0x84, 0x93, 0x72, 0x57, 0x00, 0x00])   # placeholder, Toshiba's maker byte


def fill_nand(dt):
    node = "arm-io/flash-controller0/disk"
    for key, value in N78_NAND.items():
        dt.set(node, key, value)
    dt.set(node, "device-readid", N78_NAND_READID)
    dt.set(node, "ppn-features", struct.pack("<I", 0))     # {length, features[length]}: none


def fill_dt(dt, memory_map, ident, iboot=kb.IBOOT_VERSION, root_matching=kb.ROOT_MATCHING):
    _fill_dt(dt, memory_map, ident, iboot, root_matching)
    board = board_name(dt)
    dt.set("", "platform-name", SOC[board][0])
    dt.set("chosen", "chip-id", SOC[board][1])
    # IONameMatch also matches device_type: 9.3.5's AppleM2ScalerCSCDriver finds arm-io/scaler0 by it ("scaler")
    # after its compatible is gone, then panics resetting a block nothing models (report 3.17.4).
    # cpus/cpu1 keeps its device_type (the kernel counts CPUs by it); "-" fits the shortest one (ae2's "ae2").
    for path in HIDDEN + BOARD_HIDDEN[board]:
        if path in dt.props and "compatible" in dt.props[path]:
            dt.set(path, "compatible", "none")
        if path.startswith("arm-io/") and path in dt.props and "device_type" in dt.props[path]:
            dt.set(path, "device_type", "-")
    dt.set("arm-io/aic", "#main-cpus", 1)
    # imgtools' table is the A4's 55 clocks; the A6's DT has 96 slots, and a device whose clock-id falls past
    # 55 reads 0 Hz: AppleSamsungSPIController::start quits silently on a 0 "nclk", so spi1 (0x13b) and with it
    # the touch sensor never start (a6-step1.md 15.1). The rest at the same peripheral clock as the table's default.
    # (n78's 64 slots stay as they were: only its hidden vxe and the pmgr's list name clocks past 55.)
    if board == "n41":
        _, ln = dt.props["arm-io"]["clock-frequencies"]
        dt.set("arm-io", "clock-frequencies", kb.CLOCKS + [kb.PERIPH_HZ] * (ln // 4 - len(kb.CLOCKS)))
    fill_cpu_perf(dt, board)
    fill_nand(dt)
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


def board_name(dt):
    """"n78" or "n41", from the DT's compatible."""
    return next(k for k, v in kb.BOARDS.items() if v is kb.dt_board(dt) and k in SOC)


def main(dec, out, extra=""):
    dt_blob = open(os.path.join(dec, "DeviceTree.bin"), "rb").read()
    name = board_name(kb.DeviceTree(dt_blob))
    ident = kb.synth_identity("%s-default" % name, board=name)
    args = BOOT_ARGS + (" " + extra if extra else "")
    # N78_RAMDISK=path: boot that raw HFS+ image as md0 (ipad1_kboot puts it after the kernel, adds rd=md0
    # and empties root-matching), e.g. n78_unpack.py's RestoreRamDisk.dmg.
    rd_path = os.environ.get("N78_RAMDISK")
    ramdisk = open(rd_path, "rb").read() if rd_path else None
    kernel = os.path.join(dec, "kernelcache.mach")
    trust = [p for p in os.environ.get("N78_TRUST", "").split(",") if p]
    if trust:
        sys.path.insert(0, HERE)
        import n41_trustcache as tc
        keepfiles = [p for p in os.environ.get("N78_TRUST_KEEP", "work/a6/cdhash-rootfs.txt,work/a6/cdhash-ramdisk.txt")
                     .split(",") if p]
        k = bytearray(open(kernel, "rb").read())
        n = tc.patch(k, [h for f in trust for h in tc.read_hashes(f)], {h for f in keepfiles for h in tc.read_hashes(f)})
        kernel = out + ".kernel"
        open(kernel, "wb").write(k)
        print("trust cache: %d hashes added" % n)
    image, load_pa, entry_pa, args_pa = kb.build(kernel, dt_blob, args, ident, kb.iboot_version(dec), ramdisk)
    if trust:
        os.unlink(kernel)
    # iBoot's boot logo: AppleLogo.bin (n78_unpack.py) centred on black in vram, which boot_args and the
    # machine's display (fb-base) both point at; the loader copies the segments into DRAM at every reset.
    logo = os.path.join(dec, "AppleLogo.bin")
    board = kb.BOARDS[name]
    segments = kb.logo_segments(open(logo, "rb").read(), kb.layout(board)[1], board) if os.path.exists(logo) else []
    with open(out, "wb") as f:
        f.write(image + kb.pack_segments(segments) + kb.TRAILER.pack(b"K48KBOOT", load_pa, entry_pa, args_pa,
                                                                      len(image)))
    top = struct.unpack_from("<I", image, args_pa - load_pa + 0x10)[0]
    print(f"load {load_pa:#x}+{len(image):#x} entry {entry_pa:#x} r0 {args_pa:#x} "
          f"topOfKernelData {top:#x} boot-args [{args}]")


if __name__ == "__main__":
    main(*sys.argv[1:4])
