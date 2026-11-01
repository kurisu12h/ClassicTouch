// 一台做好的设备（LightTouchMac 的 FirmwareKit 输出目录）怎么拼 QEMU 的 argv。
// 规则照 LightTouchMac 的 Packages/HostRuntime/Sources/HostRuntime/BootRecipe.swift（iPod 和 iPad 两种）
// 和本项目 tools/m0/bench.py。M1 只支持 boot_strategy 为 iboot（iPod touch 2 代）和 kboot（3GS、iPhone 4、
// iPod touch 3/4 代、初代 iPad）的设备；初代 iPhone 和 iPod touch 1 代要 pflash，以后再说。
//
// 目录约定（App 的 Documents 下）：
//   devices/<id>/            设备本体，只读：device.lock.json、nand/、nor.bin、kboot.bin 或 iBoot.bin + gid-blobs.bin
//   devices/<id>/state/      可写状态：nor.bin（第一次启动从本体克隆）和 overlay/（NAND 页覆盖层）或 nand/（就地写的 NAND）
//   devices/<id>/golden-state/  可选：-resetstate 时克隆成 state/ 的起点
//   bootrom/bootrom_240_4    iPod touch 2 代的 SecureROM（可选，见 placeholderBootrom）
//   logs/                    QEMU 的 stderr、串口、统计、截图
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct BoardInfo {
    let machine: String
    let hasCellular: Bool
    let hasUSBHost: Bool
    let width: Int
    let height: Int
}

/// 和 qemu-ios 的 qemu_ios_device_info()（LightTouchMac tests/fixtures/machines.json）一致。
let boards: [String: BoardInfo] = [
    "n45ap": BoardInfo(machine: "iPod-Touch-1G", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "m68ap": BoardInfo(machine: "iPhone-2G", hasCellular: true, hasUSBHost: false, width: 320, height: 480),
    "n72ap": BoardInfo(machine: "iPod-Touch", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "n18ap": BoardInfo(machine: "n18", hasCellular: false, hasUSBHost: false, width: 320, height: 480),
    "n88ap": BoardInfo(machine: "n88", hasCellular: true, hasUSBHost: false, width: 320, height: 480),
    "k48ap": BoardInfo(machine: "ipad1", hasCellular: false, hasUSBHost: true, width: 1024, height: 768),
    "n81ap": BoardInfo(machine: "iPod-Touch-4G", hasCellular: false, hasUSBHost: true, width: 640, height: 960),
    "n90ap": BoardInfo(machine: "iPhone-4", hasCellular: true, hasUSBHost: true, width: 640, height: 960),
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
    var title: String { "\(board) \(productVersion)（\(build)）" }

    /// 列表里显示的名字，如「iPhone 3GS · iOS 6.1.6」。4.0 以前苹果叫 iPhone OS。
    var displayName: String { "\(modelName) · \(systemName)" }

    var systemName: String {
        let major = Int(productVersion.split(separator: ".").first ?? "") ?? 0
        return major > 0 && major < 4 ? "iPhone OS \(productVersion)" : "iOS \(productVersion)"
    }

    var modelName: String {
        switch board {
        case "n45ap": return String(localized: "iPod touch（第 1 代）")
        case "m68ap": return String(localized: "iPhone（初代）")
        case "n72ap": return String(localized: "iPod touch（第 2 代）")
        case "n18ap": return String(localized: "iPod touch（第 3 代）")
        case "n88ap": return "iPhone 3GS"
        case "k48ap": return String(localized: "iPad（初代）")
        case "n81ap": return String(localized: "iPod touch（第 4 代）")
        case "n90ap": return "iPhone 4"
        default: return board
        }
    }

    /// iPod touch 2 代用的是占位 SecureROM（见 placeholderBootrom），客体熄屏进深睡后按 Home 唤不醒。以后补唤醒的模拟再去掉。
    var experimentalNote: String? {
        board == "n72ap" ? String(localized: "实验性：熄屏后可能卡住") : nil
    }

    /// 客体主版本号（iOS 7 在解释器下基本不能用，提示要更重）
    var majorVersion: Int { Int(productVersion.split(separator: ".").first ?? "") ?? 0 }

    /// 设备目录实际占用的字节数（NAND 是稀疏文件，按已分配的块算；state/ 是 APFS 克隆，和本体共用的块也会算进去）。
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
        else { throw EngineError("\(id)：device.lock.json 读不懂") }
        guard let info = boards[board] else { throw EngineError("\(id)：不认识的机型 \(board)") }
        self.board = board
        self.info = info
        bootStrategy = lock["boot_strategy"] as? String ?? "kboot"
        productVersion = lock["product_version"] as? String ?? "?"
        build = lock["build"] as? String ?? "?"
        dieID = (lock["identity"] as? [String: Any])?["die_id"] as? String
        machineOptions = (lock["machine"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
    }

    /// devices/ 下所有读得懂的设备，按系统版本、再按机型排
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

    /// 冷启动测量用：删掉 state/；有 golden-state/（比如 M0 在 Mac 上走完设置向导的状态）就克隆它。
    func resetState() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: state)
        let golden = base.appendingPathComponent("golden-state", isDirectory: true)
        if fm.fileExists(atPath: golden.path) { try fm.copyItem(at: golden, to: state) }
    }

    /// iPod touch 2 代的 NAND 是「镜像库」（geometry.json 的 storage_format 为 nand-xor-blank-v2），QEMU 就地写、
    /// 不接受 nandrw 覆盖层；照 LightTouchMac 的 PreparedDeviceBoot.liveNAND，第一次启动把它克隆到 state/nand。
    /// 3GS 等 kboot 机型的 NAND 控制器支持页覆盖层（nand-overlay），和 M0 一样用 state/overlay。
    var writesNANDInPlace: Bool { bootStrategy == "iboot" }

    /// 第一次启动：可写的 NOR 从本体克隆一份，建 NAND 覆盖层或克隆 NAND。已有的状态（比如 Mac 上走完设置向导的）原样用。
    /// APFS 上 FileManager 的复制是克隆，不额外占空间。
    func prepareState() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
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

    /// argv（不含程序名以外的宿主参数）和环境变量。backend 决定 -accel：JIT 版在 iOS 上只能用 split-wx 的双映射
    /// （MAP_JIT 要私有权限），代码缓冲默认 1 GiB 太大，压到 tbSize MB。
    /// usbKeyboard：有 USB 主机口的机型照 Light Touch 挂一个 USB 键盘。App 还不往里送按键，而 iOS 7 一解锁就弹
    /// 「Cannot Use Device / QEMU USB Keyboard」挡住触摸和 Home 键（M0 报告第 7 节），所以默认不挂。
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
            // BootRecipe.iPod：直接进解密过的 iBoot，跳过 SecureROM 和 LLB。bootrom 文件冷启动时只是放进内存，
            // 只有深睡唤醒才会执行它。boot-args 是 Light Touch 的默认值（DeviceOptions.bootArgs）。
            var m = "\(info.machine),boot-args=amfi_allow_any_signature=1 cs_enforcement_disable=1"
            m += ",direct-iboot=\(path("iBoot.bin")),direct-llb="
            m += ",bootrom=\(DeviceProfile.esc(bootrom.path)),nand=\(statePath("nand")),nor=\(path("nor.bin"))"
            m += ",nor-rw=\(statePath("nor.bin")),wifi=on"
            m += ",gid-blobs=\(path("gid-blobs.bin"))" + options
            // 默认的 amc-mode=decode 要 libavcodec；M1 不编 FFmpeg、也不出声，只做音频握手。
            m += ",amc-mode=handshake"
            argv += ["-M", m, "-m", "128M"]
            // 3.1.3 没有它开不了机（BootRecipe.iPod 的注释）
            env["IT_TVOUT_READY"] = "1"
        case "kboot":
            // BootRecipe.iPad 的 .kernel 分支
            var m = "\(info.machine),kboot=\(path("kboot.bin")),nor-rw=\(statePath("nor.bin"))"
            m += ",nand=\(path("nand")),nand-overlay=\(statePath("overlay"))"
            if let dieID { m += ",die-id=\(DeviceProfile.esc(dieID))" }
            if info.hasCellular { m += ",baseband=on" }
            m += options
            argv += ["-M", m]
        default:
            throw EngineError("\(id)：M1 还不支持 boot_strategy=\(bootStrategy)")
        }
        argv += ["-accel", accel, "-display", "none", "-no-shutdown", "-audio", "driver=none", "-serial", "file:\(serial)"]
        if info.hasUSBHost && usbKeyboard { argv += ["-device", "usb-kbd,bus=usb-bus.0,max-power=20"] }
        argv += ["-netdev", restricted]
        if info.hasCellular { argv += ["-netdev", restricted.replacingOccurrences(of: "id=wifi0", with: "id=cell0")] }
        return (argv + extra, env)
    }
}

/// 没有真 SecureROM 时用的占位 bootrom：一条 ARM「b .」原地跳转。iPod touch 2 代走 direct-iboot 冷启动时
/// QEMU 只把 bootrom 放进地址 0、从不执行（hw/arm/ipod_touch_2g.c 的 ipod_touch_cpu_reset），所以能开机；
/// 但深睡唤醒会从 bootrom 走真正的启动链，用占位文件时机器会停在这条跳转上。苹果的 SecureROM 不进仓库、不打包。
func placeholderBootrom(in documents: URL) throws -> URL {
    let dir = documents.appendingPathComponent("bootrom", isDirectory: true)
    let real = dir.appendingPathComponent("bootrom_240_4")
    if FileManager.default.fileExists(atPath: real.path) { return real }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let placeholder = dir.appendingPathComponent("placeholder-b-self.bin")
    try Data([0xFE, 0xFF, 0xFF, 0xEA]).write(to: placeholder)
    return placeholder
}
