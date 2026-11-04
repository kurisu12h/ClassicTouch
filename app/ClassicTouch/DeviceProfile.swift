// How a finished device (the output folder of LightTouchMac's FirmwareKit) becomes QEMU's argv.
// The rules follow LightTouchMac's Packages/HostRuntime/Sources/HostRuntime/BootRecipe.swift (iPod, iPod1G and iPad)
// and this project's tools/m0/bench.py and tools/timeline/tl.py. Supported boot strategies:
//   iboot   iPod touch 2nd gen: boots straight into the decrypted iBoot (3.x; 2.x needs a FirmwareKit with
//           patches/firmwarekit-n72-2x-direct-iboot.patch applied, because stock FirmwareKit makes 2.x a bootrom chain
//           that needs a real SecureROM, which is not supported here)
//   kboot   3GS, iPhone 4, iPod touch 3rd and 4th gen, original iPad: boots straight into the kernel
//   s5l8900 original iPhone and iPod touch 1st gen on 1.x (the lock has no boot_strategy, so it is recognized by the
//           board): iBoot plus the NOR in pflash
//   n78     iPod touch 5th gen (A5, 7.1.2, 9.3.5): boots straight into the kernel; the system and data volumes are two
//           partitions of one USB disk, and the NAND (which effaceable storage, NVRAM and the keybag depend on) is the
//           IOP model's page store folder (docs/reports/a5-step1.md 3.13 to 3.17, a5-app.md)
//           The iPhone 5 (n41ap, A6, iOS 10.3.4) boots the same way on the iPhone-5 machine (docs/reports/a6-app.md).
//
// Folder layout (under the app's Documents):
//   devices/<id>/            the device itself, read-only: device.lock.json, nand/, nor.bin, kboot.bin or iBoot.bin
//                            (+ gid-blobs.bin); for n78: device.lock.json, kboot.bin, disk.img, nand/ (ce0.pages, ce0.boot)
//   devices/<id>/state/      writable state: nor.bin (cloned from the device on first boot) and overlay/ (NAND page
//                            overlay) or nand/ (NAND written in place); for n78, clones of disk.img and nand/
//   devices/<id>/golden-state/  optional: the starting point cloned into state/ on -resetstate
//   bootrom/bootrom_240_4    the iPod touch 2nd gen SecureROM (optional, see placeholderBootrom)
//   bootrom/bootrom_s5l8900  the S5L8900 SecureROM (optional, see s5l8900Bootrom)
//   logs/                    QEMU's stderr, serial, stats, screenshots
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct BoardInfo {
    let machine: String
    let hasCellular: Bool
    let hasUSBHost: Bool
    let width: Int
    let height: Int
}

/// Matches qemu-ios's qemu_ios_device_info() (LightTouchMac tests/fixtures/machines.json).
let boards: [String: BoardInfo] = [
    "n45ap": BoardInfo(machine: "iPod-Touch-1G", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "m68ap": BoardInfo(machine: "iPhone-2G", hasCellular: true, hasUSBHost: false, width: 320, height: 480),
    "n72ap": BoardInfo(machine: "iPod-Touch", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "n18ap": BoardInfo(machine: "n18", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "n88ap": BoardInfo(machine: "n88", hasCellular: true, hasUSBHost: false, width: 320, height: 480),
    "k48ap": BoardInfo(machine: "ipad1", hasCellular: false, hasUSBHost: true, width: 1024, height: 768),
    "n81ap": BoardInfo(machine: "iPod-Touch-4G", hasCellular: false, hasUSBHost: true, width: 640, height: 960),
    "n90ap": BoardInfo(machine: "iPhone-4", hasCellular: true, hasUSBHost: true, width: 640, height: 960),
    // Has a USB host port, but it carries the root disk (usb-storage on bus ehci.0) and no usb-kbd, so this is false
    "n78ap": BoardInfo(machine: "iPod-Touch-5G", hasCellular: false, hasUSBHost: false, width: 640, height: 1136),
    // The iPhone 5: the same USB root disk, and no baseband (the boot bundle hides it, CommCenter is disabled on the disk)
    "n41ap": BoardInfo(machine: "iPhone-5", hasCellular: false, hasUSBHost: false, width: 640, height: 1136),
]

struct DeviceProfile {
    let id: String
    let base: URL
    let board: String
    let info: BoardInfo
    let bootStrategy: String
    let productVersion: String
    let build: String
    let dieID: String?
    let machineOptions: [String: String]

    var state: URL { base.appendingPathComponent("state", isDirectory: true) }
    var title: String { "\(board) \(productVersion) (\(build))" }

    /// The name shown in lists, such as "iPhone 3GS · iOS 6.1.6". Before 4.0 Apple called it iPhone OS.
    var displayName: String { "\(modelName) · \(systemName)" }

    var systemName: String {
        let major = Int(productVersion.split(separator: ".").first ?? "") ?? 0
        return major > 0 && major < 4 ? "iPhone OS \(productVersion)" : "iOS \(productVersion)"
    }

    var modelName: String {
        switch board {
        case "n45ap": return String(localized: "iPod touch (1st generation)")
        case "m68ap": return String(localized: "iPhone (1st generation)")
        case "n72ap": return String(localized: "iPod touch (2nd generation)")
        case "n18ap": return String(localized: "iPod touch (3rd generation)")
        case "n88ap": return "iPhone 3GS"
        case "k48ap": return String(localized: "iPad (1st generation)")
        case "n81ap": return String(localized: "iPod touch (4th generation)")
        case "n90ap": return "iPhone 4"
        case "n78ap": return String(localized: "iPod touch (5th generation)")
        case "n41ap": return "iPhone 5"
        default: return board
        }
    }

    /// The iPod touch 2nd gen uses the placeholder SecureROM (see placeholderBootrom), so once the guest turns its screen
    /// off and enters deep sleep, Home does not wake it. Remove this once wake-up is emulated.
    /// Upstream never emulated deep-sleep wake-up for the two S5L8900 devices (qemu-ios docs/ipod1g/README.md, debt 9),
    /// so they are flagged too.
    var experimentalNote: String? {
        board == "n72ap" || isS5L8900 ? String(localized: "Experimental: may freeze after the screen turns off") : nil
    }

    /// The original iPhone and iPod touch 1st gen (S5L8900, iPhone OS 1.x), qemu-ios's iPhone-2G / iPod-Touch-1G machines
    var isS5L8900: Bool { board == "m68ap" || board == "n45ap" }

    /// iPod touch 5th gen: the root disk is on a USB disk and the NAND is the IOP's page store folder
    var isN78: Bool { bootStrategy == "n78" }

    /// The guest's major version (iOS 7 is barely usable under the interpreter, so the warning is stronger)
    var majorVersion: Int { Int(productVersion.split(separator: ".").first ?? "") ?? 0 }

    /// Bytes the device folder actually uses (NAND files are sparse, so allocated blocks are counted; state/ is an APFS clone, and blocks it shares with the device are counted too).
    func allocatedSize() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    init(base: URL) throws {
        self.base = base
        id = base.lastPathComponent
        let data = try Data(contentsOf: base.appendingPathComponent("device.lock.json"))
        guard let lock = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let board = lock["board"] as? String
        else { throw EngineError("\(id): cannot read device.lock.json") }
        guard let info = boards[board] else { throw EngineError("\(id): unknown board \(board)") }
        self.board = board
        self.info = info
        // FirmwareKit's lock for 1.x has no boot_strategy (Light Touch picks by the board's SoC)
        bootStrategy = lock["boot_strategy"] as? String ?? (board == "m68ap" || board == "n45ap" ? "s5l8900" : "kboot")
        productVersion = lock["product_version"] as? String ?? "?"
        build = lock["build"] as? String ?? "?"
        dieID = (lock["identity"] as? [String: Any])?["die_id"] as? String
        machineOptions = (lock["machine"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
    }

    /// Every readable device under devices/, sorted by system version, then by device id
    static func all(in documents: URL) -> [DeviceProfile] {
        let dir = documents.appendingPathComponent("devices", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .compactMap { try? DeviceProfile(base: dir.appendingPathComponent($0)) }
            .sorted {
                let order = $0.productVersion.compare($1.productVersion, options: .numeric)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// For cold-boot measurements: deletes state/ and clones golden-state/ if there is one (for example the state M0 reached after finishing Setup on the Mac).
    func resetState() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: state)
        let golden = base.appendingPathComponent("golden-state", isDirectory: true)
        if fm.fileExists(atPath: golden.path) { try fm.copyItem(at: golden, to: state) }
    }

    /// The NAND of the iPod touch 2nd gen and the S5L8900 is an "image library" (storage_format nand-xor-blank-v2 in
    /// geometry.json) that QEMU writes in place and that takes no nandrw overlay; as in LightTouchMac's
    /// PreparedDeviceBoot.liveNAND, the first boot clones it to state/nand.
    /// The NAND controller of the 3GS and the other kboot devices supports a page overlay (nand-overlay); like M0, they use state/overlay.
    var writesNANDInPlace: Bool { board == "n72ap" || isS5L8900 }

    /// First boot: clones a writable NOR from the device and creates the NAND overlay or clones the NAND. Existing state
    /// (such as one that finished Setup on the Mac) is used as is. On APFS, FileManager copies are clones and take no extra space.
    func prepareState() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        if isN78 {
            // QEMU writes both the disk and the NAND in place: the first boot clones each (a clone on APFS, so sparse files do not expand), under a staging name first, then renames it
            for name in ["disk.img", "nand"] {
                let live = state.appendingPathComponent(name)
                if fm.fileExists(atPath: live.path) { continue }
                let staged = state.appendingPathComponent(".staging-\(name)")
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: base.appendingPathComponent(name), to: staged)
                try fm.moveItem(at: staged, to: live)
            }
            return
        }
        let nor = state.appendingPathComponent("nor.bin")
        if !fm.fileExists(atPath: nor.path) {
            try fm.copyItem(at: base.appendingPathComponent("nor.bin"), to: nor)
        }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nor.path)
        if writesNANDInPlace {
            let live = state.appendingPathComponent("nand", isDirectory: true)
            if !fm.fileExists(atPath: live.path) {
                let staged = state.appendingPathComponent(".nand-staging", isDirectory: true)
                try? fm.removeItem(at: staged)
                try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                for name in try fm.contentsOfDirectory(atPath: base.appendingPathComponent("nand").path) {
                    let target = staged.appendingPathComponent(name)
                    try fm.copyItem(at: base.appendingPathComponent("nand/\(name)"), to: target)
                    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                }
                try fm.moveItem(at: staged, to: live)
            }
        } else {
            try fm.createDirectory(at: state.appendingPathComponent("overlay"), withIntermediateDirectories: true)
        }
    }

    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ",,") }
    private func path(_ name: String) -> String { DeviceProfile.esc(base.appendingPathComponent(name).path) }
    private func statePath(_ name: String) -> String { DeviceProfile.esc(state.appendingPathComponent(name).path) }
    private var options: String {
        machineOptions.sorted { $0.key < $1.key }.map { ",\($0.key)=\(DeviceProfile.esc($0.value))" }.joined()
    }

    /// argv (with no host arguments beyond the program name) and environment variables. backend decides -accel: on iOS the
    /// JIT build can only use split-wx double mapping (MAP_JIT needs a private entitlement), and the default 1 GiB code
    /// buffer is too big, so it is cut to tbSize MB.
    /// usbKeyboard: devices with a USB host port get a USB keyboard as in Light Touch. The app does not send it keys yet,
    /// and right after unlocking iOS 7 shows "Cannot Use Device / QEMU USB Keyboard", which blocks touch and the Home
    /// button (M0 report, section 7), so it is off by default.
    func boot(backend: Engine.Backend, bootrom: URL, logs: URL, run: String, tbSize: Int, usbKeyboard: Bool,
              extra: [String]) throws -> (argv: [String], environment: [String: String])
    {
        let serial = DeviceProfile.esc(logs.appendingPathComponent("serial-\(run).log").path)
        var accel = "tcg,tb-size=\(tbSize)"
        if backend == .jit { accel += ",split-wx=on" }
        let restricted = "user,id=wifi0,restrict=on,lan=off"
        var argv = ["qemu-system-arm"]
        var env: [String: String] = [:]
        switch bootStrategy {
        case "iboot":
            // BootRecipe.iPod: boots straight into the decrypted iBoot, skipping SecureROM and LLB. On a cold boot the
            // bootrom file is only placed in memory; only deep-sleep wake-up runs it. boot-args are Light Touch's
            // defaults (DeviceOptions.bootArgs).
            var m = "\(info.machine),boot-args=amfi_allow_any_signature=1 cs_enforcement_disable=1"
            m += ",direct-iboot=\(path("iBoot.bin")),direct-llb="
            m += ",bootrom=\(DeviceProfile.esc(bootrom.path)),nand=\(statePath("nand")),nor=\(path("nor.bin"))"
            m += ",nor-rw=\(statePath("nor.bin")),wifi=on"
            m += ",gid-blobs=\(path("gid-blobs.bin"))" + options
            // The default amc-mode=decode needs libavcodec; M1 builds no FFmpeg and plays no sound, so only the audio handshake runs.
            m += ",amc-mode=handshake"
            argv += ["-M", m, "-m", "128M"]
            // 3.1.3 cannot boot without it (comment in BootRecipe.iPod)
            env["IT_TVOUT_READY"] = "1"
        case "kboot":
            // The .kernel branch of BootRecipe.iPad
            var m = "\(info.machine),kboot=\(path("kboot.bin")),nor-rw=\(statePath("nor.bin"))"
            m += ",nand=\(path("nand")),nand-overlay=\(statePath("overlay"))"
            if let dieID { m += ",die-id=\(DeviceProfile.esc(dieID))" }
            if info.hasCellular { m += ",baseband=on" }
            m += options
            argv += ["-M", m]
        case "n78":
            // The arguments of tools/a5/n78_run.sh: a boot bundle of kernel plus device tree; the root disk is USB mass
            // storage on EHCI (two partitions, fstab says disk1s1 and disk1s2); the IOP model's NAND page store is in
            // state/nand. Memory is the machine default of 512 MB.
            // The iPhone-5 machine's default is 1 GiB.
            argv += ["-M", "\(info.machine),kboot=\(path("kboot.bin"))" + options,
                     "-drive", "if=none,id=root,file=\(statePath("disk.img")),format=raw",
                     "-device", "usb-storage,bus=ehci.0,drive=root",
                     "-global", "driver=s5l8940.iop,property=nand,value=\(statePath("nand"))"]
        case "s5l8900":
            // BootRecipe.iPod1G: boots straight into the decrypted iBoot (iBoot-159 on the original iPhone); the NOR is
            // pflash, and memory is the machine default of 128 MB. The machine has its own baseband (original iPhone) and
            // Wi-Fi, with Bluetooth on UART3. The lock's machine section has imei and wifi-mac.
            var m = "\(info.machine),bootrom=\(DeviceProfile.esc(try s5l8900Bootrom(beside: bootrom).path))"
            m += ",iboot=\(path("iBoot.bin")),nand=\(statePath("nand"))" + options
            argv += ["-M", m, "-drive", "if=pflash,format=raw,file=\(statePath("nor.bin"))"]
        default:
            throw EngineError("\(id): boot_strategy=\(bootStrategy) is not supported yet")
        }
        argv += ["-accel", accel, "-display", "none", "-no-shutdown", "-audio", "driver=none", "-serial", "file:\(serial)"]
        if info.hasUSBHost && usbKeyboard { argv += ["-device", "usb-kbd,bus=usb-bus.0,max-power=20"] }
        // n78 has no network card; an empty -netdev only makes QEMU report "has no peer"
        if !isN78 { argv += ["-netdev", restricted] }
        if info.hasCellular { argv += ["-netdev", restricted.replacingOccurrences(of: "id=wifi0", with: "id=cell0")] }
        return (argv + extra, env)
    }
}

/// The placeholder bootrom used without a real SecureROM: one ARM "b ." branch to itself. When the iPod touch 2nd gen
/// cold-boots via direct-iboot, QEMU only places the bootrom at address 0 and never runs it (ipod_touch_cpu_reset in
/// hw/arm/ipod_touch_2g.c), so it boots; but deep-sleep wake-up goes through the real boot chain from the bootrom, and
/// with the placeholder the machine stops on that branch. Apple's SecureROM is never in the repository or the app.
func placeholderBootrom(in documents: URL) throws -> URL {
    let dir = documents.appendingPathComponent("bootrom", isDirectory: true)
    let real = dir.appendingPathComponent("bootrom_240_4")
    if FileManager.default.fileExists(atPath: real.path) { return real }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let placeholder = dir.appendingPathComponent("placeholder-b-self.bin")
    try Data([0xFE, 0xFF, 0xFF, 0xEA]).write(to: placeholder)
    return placeholder
}

/// The S5L8900 SecureROM: bootrom/bootrom_s5l8900 if present, otherwise a placeholder with the same "b ." instruction.
/// qemu-ios only places it at 0x20000000 for iBoot's jump table, and the machine points the two slots iBoot calls there
/// (8900 image verification and decryption) at stubs (n45_stage_boot_chain in hw/arm/ipod_touch_1g.c), so the placeholder
/// boots to the home screen (tested on the Mac and in the simulator, 2026-11-02).
/// `bootrom` is the iPod touch 2nd gen one from placeholderBootrom; only its folder is used here.
func s5l8900Bootrom(beside bootrom: URL) throws -> URL {
    let dir = bootrom.deletingLastPathComponent()
    let real = dir.appendingPathComponent("bootrom_s5l8900")
    if FileManager.default.fileExists(atPath: real.path) { return real }
    let placeholder = dir.appendingPathComponent("placeholder-s5l8900-b-self.bin")
    if !FileManager.default.fileExists(atPath: placeholder.path) {
        try Data([0xFE, 0xFF, 0xFF, 0xEA]).write(to: placeholder)
    }
    return placeholder
}
