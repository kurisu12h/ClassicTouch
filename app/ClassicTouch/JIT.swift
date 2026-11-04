// Where JIT comes from and whether it is there. On a real phone, StikDebug on the phone provides JIT
// (docs/reports/m1-stage3-stikdebug.md): opening stikjit://enable-jit?bundle-id=…&script-name=universal.js makes
// StikDebug launch a new suspended process of this app, attach a debugger and run universal.js; when QEMU allocates its
// code region it asks for preparation with brk #0xf00d (patches/ios-txm-jit-protocol.patch), and after that the debugger
// detaches. StikDebug does not kill the existing process when launching (kill_existing in process_control_launch_app is
// false), so this app exits by itself after opening the URL, and the new process reads PendingBoot to know which device
// the user picked and boots it. This also gets around "QEMU can start only once per process": switching systems just
// goes through it again.
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JIT {
    /// In the simulator JIT needs no debugger, so the "turn on JIT" part is faked with the launch argument -fakejit:
    /// on: JIT is there; off: no JIT, StikDebug installed (tapping a system only writes PendingBoot and exits, and the
    /// host relaunches with -fakejit on, as if StikDebug launched it); nostik: no JIT and no StikDebug. Without the
    /// argument the simulator counts as having JIT. Real phones ignore this argument.
    enum Fake: String { case on, off, nostik }

    static var fake: Fake? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: "fakejit").flatMap(Fake.init(rawValue:))
        #else
        nil
        #endif
    }

    /// The kernel's code signing flag CS_DEBUGGED (0x10000000): a process keeps it once a debugger has attached.
    static var csDebugged: Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x1000_0000 != 0
    }

    /// Whether the JIT build can boot now. CS_DEBUGGED means JIT was granted, but since iOS 26 TXM only accepts code
    /// pages a debugger prepared: the debugger must still be attached when QEMU allocates its code region (universal.js
    /// stays attached until QEMU sends the detach command), or brk #0xf00d crashes the process.
    /// So a real phone needs both.
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

    /// stikjit has to be in LSApplicationQueriesSchemes in Info.plist, or canOpenURL always returns false.
    static var installed: Bool {
        if let fake = JIT.fake { return fake != .nostik }
        return UIApplication.shared.canOpenURL(url)
    }
}

/// Which device the user picked and whether it wants JIT, kept across processes in
/// Library/Application Support/pending-boot.json (not in Documents, which Finder shows).
/// The new process reads and deletes it at launch; stale ones do not count (2 minutes for a trip to StikDebug for JIT,
/// 10 minutes for the user to reopen the app).
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
