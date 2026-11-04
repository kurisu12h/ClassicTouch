// 一台做好的设备（LightTouchMac 的 FirmwareKit 输出目录）怎么拼 QEMU 的 argv。
// 规则照 LightTouchMac 的 Packages/HostRuntime/Sources/HostRuntime/BootRecipe.swift（iPod、iPod1G、iPad 三种）
// 和本项目 tools/m0/bench.py、tools/timeline/tl.py。支持的开机方式：
//   iboot   iPod touch 2 代：直接进解密过的 iBoot（3.x；2.x 要用打过 patches/firmwarekit-n72-2x-direct-iboot.patch
//           的 FirmwareKit 做，原版给 2.x 做的是要真 SecureROM 的 bootrom 链，这里不支持）
//   kboot   3GS、iPhone 4、iPod touch 3/4 代、初代 iPad：直接进内核
//   s5l8900 初代 iPhone、iPod touch 1 代的 1.x（lock 里没有 boot_strategy，按机型认）：iBoot 加 pflash 的 NOR
//   n78     iPod touch 5 代（A5，7.1.2、9.3.5）：直接进内核，系统卷和数据卷在一块挂 USB 的两分区盘上，NAND（可擦除
//           存储、NVRAM、钥匙包靠它）是 IOP 模型的页存储目录（docs/reports/a5-step1.md 3.13 到 3.17，a5-app.md）
//
// 目录约定（App 的 Documents 下）：
//   devices/<id>/            设备本体，只读：device.lock.json、nand/、nor.bin、kboot.bin 或 iBoot.bin（+ gid-blobs.bin）；
//                            n78 是 device.lock.json、kboot.bin、disk.img、nand/（ce0.pages、ce0.boot）
//   devices/<id>/state/      可写状态：nor.bin（第一次启动从本体克隆）和 overlay/（NAND 页覆盖层）或 nand/（就地写的 NAND）；
//                            n78 是 disk.img 和 nand/ 的克隆
//   devices/<id>/golden-state/  可选：-resetstate 时克隆成 state/ 的起点
//   bootrom/bootrom_240_4    iPod touch 2 代的 SecureROM（可选，见 placeholderBootrom）
//   bootrom/bootrom_s5l8900  S5L8900 的 SecureROM（可选，见 s5l8900Bootrom）
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
    // 有 USB 主机口，但上面挂的是根盘（usb-storage，总线 ehci.0），不挂 usb-kbd，所以这里记 false
    "n78ap": BoardInfo(machine: "iPod-Touch-5G", hasCellular: false, hasUSBHost: false, width: 640, height: 1136),
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
        case "n78ap": return String(localized: "iPod touch（第 5 代）")
        default: return board
        }
    }

    /// iPod touch 2 代用的是占位 SecureROM（见 placeholderBootrom），客体熄屏进深睡后按 Home 唤不醒。以后补唤醒的模拟再去掉。
    /// S5L8900 的两台在上游就没模拟深睡唤醒（qemu-ios docs/ipod1g/README.md 欠账 9），一样标出来。
    var experimentalNote: String? {
        board == "n72ap" || isS5L8900 ? String(localized: "实验性：熄屏后可能卡住") : nil
    }

    /// 初代 iPhone 和 iPod touch 1 代（S5L8900，iPhone OS 1.x），qemu-ios 的 iPhone-2G / iPod-Touch-1G 机型
    var isS5L8900: Bool { board == "m68ap" || board == "n45ap" }

    /// iPod touch 5 代：根盘在 USB 盘上，NAND 是 IOP 的页存储目录
    var isN78: Bool { bootStrategy == "n78" }

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
        // FirmwareKit 给 1.x 的 lock 不写 boot_strategy（Light Touch 按机型的 SoC 分）
        bootStrategy = lock["boot_strategy"] as? String ?? (board == "m68ap" || board == "n45ap" ? "s5l8900" : "kboot")
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

    /// iPod touch 2 代和 S5L8900 的 NAND 是「镜像库」（geometry.json 的 storage_format 为 nand-xor-blank-v2），QEMU
    /// 就地写、不接受 nandrw 覆盖层；照 LightTouchMac 的 PreparedDeviceBoot.liveNAND，第一次启动把它克隆到 state/nand。
    /// 3GS 等 kboot 机型的 NAND 控制器支持页覆盖层（nand-overlay），和 M0 一样用 state/overlay。
    var writesNANDInPlace: Bool { board == "n72ap" || isS5L8900 }

    /// 第一次启动：可写的 NOR 从本体克隆一份，建 NAND 覆盖层或克隆 NAND。已有的状态（比如 Mac 上走完设置向导的）原样用。
    /// APFS 上 FileManager 的复制是克隆，不额外占空间。
    func prepareState() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        if isN78 {
            // 盘和 NAND 都是 QEMU 就地写的：第一次启动各克隆一份（APFS 上是克隆，稀疏文件不展开），先放暂存名再改名
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
        case "n78":
            // tools/a5/n78_run.sh 的参数：内核加设备树的开机包；根盘是挂在 EHCI 上的 USB 大容量存储（两分区，
            // fstab 是 disk1s1、disk1s2）；IOP 模型的 NAND 页存储放在 state/nand。内存用机型默认的 512 MB。
            argv += ["-M", "\(info.machine),kboot=\(path("kboot.bin"))" + options,
                     "-drive", "if=none,id=root,file=\(statePath("disk.img")),format=raw",
                     "-device", "usb-storage,bus=ehci.0,drive=root",
                     "-global", "driver=s5l8940.iop,property=nand,value=\(statePath("nand"))"]
        case "s5l8900":
            // BootRecipe.iPod1G：直接进解密过的 iBoot（初代 iPhone 是 iBoot-159），NOR 是 pflash，内存用机型默认的
            // 128 MB。机型自带基带（初代 iPhone）、Wi-Fi，蓝牙在 UART3。lock 的 machine 里有 imei、wifi-mac。
            var m = "\(info.machine),bootrom=\(DeviceProfile.esc(try s5l8900Bootrom(beside: bootrom).path))"
            m += ",iboot=\(path("iBoot.bin")),nand=\(statePath("nand"))" + options
            argv += ["-M", m, "-drive", "if=pflash,format=raw,file=\(statePath("nor.bin"))"]
        default:
            throw EngineError("\(id)：还不支持 boot_strategy=\(bootStrategy)")
        }
        argv += ["-accel", accel, "-display", "none", "-no-shutdown", "-audio", "driver=none", "-serial", "file:\(serial)"]
        if info.hasUSBHost && usbKeyboard { argv += ["-device", "usb-kbd,bus=usb-bus.0,max-power=20"] }
        // n78 没有网卡，空的 -netdev 只会让 QEMU 报「has no peer」
        if !isN78 { argv += ["-netdev", restricted] }
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

/// S5L8900 的 SecureROM：bootrom/bootrom_s5l8900 有就用，没有就用同样一条「b .」的占位文件。qemu-ios 只把它放在
/// 0x20000000 给 iBoot 的跳转表用，跳转表里 iBoot 要调的两个槽（8900 映像校验、解密）机型自己指到桩上
/// （hw/arm/ipod_touch_1g.c 的 n45_stage_boot_chain），所以占位文件就能开到主屏（2026-11-02 Mac 和模拟器实测）。
/// `bootrom` 是 placeholderBootrom 给的 iPod touch 2 代那份，这里只借它的目录。
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
