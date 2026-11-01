// JIT 从哪来、有没有。真机上 JIT 由手机上的 StikDebug 给（docs/reports/m1-stage3-stikdebug.md）：
// 打开 stikjit://enable-jit?bundle-id=…&script-name=universal.js，StikDebug 挂起启动一个新的本 App 进程、挂上调试器、
// 跑 universal.js，QEMU 分配代码区时用 brk #0xf00d 请它准备（patches/ios-txm-jit-protocol.patch），准备完让它脱离。
// StikDebug 启动时不杀已有进程（process_control_launch_app 的 kill_existing 是 false），所以本 App 打开 URL 后要自己退出，
// 新进程读 PendingBoot 知道用户选了哪台，直接开机。这也顺便解决了「一个进程只能起一次 QEMU」：换系统就是再走一遍。
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JIT {
    /// 模拟器里 JIT 不靠调试器，「开 JIT」那段用启动参数 -fakejit 假装：
    /// on 有 JIT；off 没有 JIT、StikDebug 装了（点系统时只写 PendingBoot 然后退出，由宿主带 -fakejit on 再启动，
    /// 模拟 StikDebug 拉起）；nostik 没有 JIT、也没装 StikDebug。不带参数时模拟器当作有 JIT。真机上不认这个参数。
    enum Fake: String { case on, off, nostik }

    static var fake: Fake? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: "fakejit").flatMap(Fake.init(rawValue:))
        #else
        nil
        #endif
    }

    /// 内核的代码签名标志 CS_DEBUGGED（0x10000000）：进程被调试器挂过就一直带着。
    static var csDebugged: Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x1000_0000 != 0
    }

    /// 现在能不能用 JIT 版开机。CS_DEBUGGED 说明拿到过 JIT，但 iOS 26 起的 TXM 只认调试器准备过的代码页：
    /// QEMU 分配代码区时调试器必须还挂着（universal.js 一直挂到 QEMU 发脱离命令），否则 brk #0xf00d 会让进程崩溃。
    /// 所以真机上两样都要有。
    static var ready: Bool {
        if let fake { return fake == .on }
        #if targetEnvironment(simulator)
        return true
        #else
        return csDebugged && debuggerAttached()
        #endif
    }
}

enum StikDebug {
    static var url: URL {
        let id = Bundle.main.bundleIdentifier ?? "org.classictouch.app"
        return URL(string: "stikjit://enable-jit?bundle-id=\(id)&script-name=universal.js")!
    }

    /// 要在 Info.plist 的 LSApplicationQueriesSchemes 里写 stikjit，canOpenURL 才不会一律回 false。
    static var installed: Bool {
        if let fake = JIT.fake { return fake != .nostik }
        return UIApplication.shared.canOpenURL(url)
    }
}

/// 用户选了哪台、要不要 JIT，跨进程记在 Library/Application Support/pending-boot.json（不放 Documents：Finder 里看得见）。
/// 新进程启动时取出并删掉；过期的不算（去 StikDebug 开 JIT 2 分钟，让用户自己重开 App 10 分钟）。
struct PendingBoot: Codable {
    let device: String
    let wantJIT: Bool
    let created: Date

    init(device: String, wantJIT: Bool) {
        self.device = device
        self.wantJIT = wantJIT
        created = Date()
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending-boot.json")
    }

    func save() throws {
        let dir = PendingBoot.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: PendingBoot.url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static func take() -> PendingBoot? {
        defer { clear() }
        guard let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode(PendingBoot.self, from: data)
        else { return nil }
        let age = Date().timeIntervalSince(pending.created)
        return age >= 0 && age < (pending.wantJIT ? 120 : 600) ? pending : nil
    }
}
