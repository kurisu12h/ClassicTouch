// The qemu-ios engine: dlopens the libqemu-arm-<interp|jit>.dylib embedded in Frameworks and gets the app ABI it exports
// with dlsym (upstream qemu-ios contrib/ios-app/qemu-ios-ui.h; the constants are copied below). QEMU cannot start twice
// in one process, so one launch opens only one device, and switching devices means reopening the app.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum QemuButton: Int32 {
    case home = 0, power = 1, volumeUp = 2, volumeDown = 3
}

enum TouchPhase: Int32 {
    case begin = 0, update = 1, end = 2
}

final class Engine {
    enum Backend: String {
        case interp, jit
    }

    private typealias MainFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias AttachFn = @convention(c) (FrameCallback?, UnsafeMutableRawPointer?) -> Void
    private typealias FrameFn = @convention(c) (
        UnsafeMutablePointer<UnsafeRawPointer?>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
        UnsafeMutablePointer<UInt64>?
    ) -> Bool
    private typealias TouchFn = @convention(c) (Int32, Int32, Double, Double) -> Void
    private typealias ButtonFn = @convention(c) (Int32, Bool) -> Void
    private typealias SetBoolFn = @convention(c) (Bool) -> Void
    private typealias GetBoolFn = @convention(c) () -> Bool
    private typealias GetIntFn = @convention(c) () -> Int32
    private typealias GetStringFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias VoidFn = @convention(c) () -> Void
    private typealias SequenceFn = @convention(c) (
        UInt64, Int, UnsafePointer<Int64>?, UnsafePointer<Int32>?, UnsafePointer<Int32>?, UnsafePointer<Int32>?,
        UnsafePointer<Double>?, UnsafePointer<Double>?
    ) -> Bool

    let backend: Backend
    private let handle: UnsafeMutableRawPointer
    private let qemuMain: MainFn
    private let attach: AttachFn
    private let frameFn: FrameFn
    private let touchFn: TouchFn
    private let buttonFn: ButtonFn
    private let foregroundFn: SetBoolFn
    private let readyFn: GetBoolFn
    private let sleepingFn: GetBoolFn
    private let backlightFn: GetIntFn
    private let quitFn: VoidFn
    private let pauseFn: VoidFn
    private let resumeFn: VoidFn
    private let sequenceFn: SequenceFn
    let buildID: String
    private var sequenceID: UInt64 = 1
    private(set) var started = false
    /// Called on the main thread when the QEMU thread exits (the VM stopped or failed to start), with the return value of qemu_ios_main.
    var onExit: ((Int32) -> Void)?

    private static func path(_ backend: Backend) -> String? {
        Bundle.main.privateFrameworksPath.map {
            ($0 as NSString).appendingPathComponent("libqemu-arm-\(backend.rawValue).dylib")
        }
    }

    /// Loads early (reference counted; the dlopen in init later gets the same handle).
    static func preload(_ backend: Backend) {
        if let path = path(backend) { _ = dlopen(path, RTLD_NOW | RTLD_LOCAL) }
    }

    init(backend: Backend) throws {
        self.backend = backend
        let name = "libqemu-arm-\(backend.rawValue).dylib"
        guard let path = Engine.path(backend) else { throw EngineError("Cannot find the app's Frameworks folder") }
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineError("dlopen \(name) failed: \(String(cString: dlerror()))")
        }
        handle = h
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw EngineError("\(name) is missing from the dylib") }
            return unsafeBitCast(p, to: T.self)
        }
        qemuMain = try sym("qemu_ios_main", MainFn.self)
        attach = try sym("qemu_ios_ui_attach", AttachFn.self)
        frameFn = try sym("qemu_ios_ui_frame", FrameFn.self)
        touchFn = try sym("qemu_ios_ui_touch", TouchFn.self)
        buttonFn = try sym("qemu_ios_ui_button", ButtonFn.self)
        foregroundFn = try sym("qemu_ios_set_foreground", SetBoolFn.self)
        readyFn = try sym("qemu_ios_ui_ready", GetBoolFn.self)
        sleepingFn = try sym("qemu_ios_ui_display_sleeping", GetBoolFn.self)
        backlightFn = try sym("qemu_ios_ui_backlight_level", GetIntFn.self)
        quitFn = try sym("qemu_ios_ui_quit", VoidFn.self)
        pauseFn = try sym("qemu_ios_ui_pause", VoidFn.self)
        resumeFn = try sym("qemu_ios_ui_resume", VoidFn.self)
        sequenceFn = try sym("qemu_ios_ui_input_sequence", SequenceFn.self)
        let build = try sym("qemu_ios_build_id", GetStringFn.self)
        buildID = build().map { String(cString: $0) } ?? "?"
    }

    /// Runs qemu_ios_main on a background thread with an 8 MB stack; it returns only when the VM stops.
    func start(argv: [String], environment: [String: String]) {
        precondition(!started, "QEMU can start only once per process")
        started = true
        for (key, value) in environment { setenv(key, value, 1) }
        // The display listener registers only once the VM has a console; the UI pulls frames on each screen refresh, so the callback has nothing to do.
        attach({ _ in }, nil)
        let main = qemuMain
        let thread = Thread { [weak self] in
            // Deliberately not freed: QEMU keeps the pointers in argv.
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cargs.append(nil)
            let status = cargs.withUnsafeMutableBufferPointer { main(Int32(argv.count), $0.baseAddress) }
            DispatchQueue.main.async { self?.onExit?(status) }
        }
        thread.name = "qemu"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    var ready: Bool { started && readyFn() }
    var displaySleeping: Bool { sleepingFn() }
    var backlightLevel: Int32 { backlightFn() }

    /// The latest frame (tightly packed BGRA, not copied). Pass the last serial seen; returns nil if there is no newer frame.
    func frame(after serial: inout UInt64) -> (pixels: UnsafeRawPointer, width: Int, height: Int)? {
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0
        var h: Int32 = 0
        guard frameFn(&pixels, &w, &h, &serial), let p = pixels, w > 0, h > 0 else { return nil }
        return (p, Int(w), Int(h))
    }

    func touch(_ phase: TouchPhase, x: Double, y: Double) {
        touchFn(0, phase.rawValue, min(max(x, 0), 1), min(max(y, 0), 1))
    }

    func button(_ button: QemuButton, down: Bool) { buttonFn(button.rawValue, down) }

    /// iOS kills a process that sends GL commands in the background, so this has to be cleared as early as willResignActive.
    func setForeground(_ foreground: Bool) {
        if started { foregroundFn(foreground) }
    }

    /// Stops or resumes the VM (it stops when the app goes to the background or back to the list). Stopping clears the
    /// foreground flag first: iOS kills a process that sends GL commands in the background, and qemu_ios_ui_pause
    /// (QMP stop) runs asynchronously on the QEMU main loop. On resume, set_foreground(true) by itself restarts the stopped
    /// VM (ios_resume_bh in qemu-ios-ui.c), and sending QMP cont again has no side effects.
    /// Before the VM is up (before qemu_ios_ui_ready), pause and resume do nothing.
    func setRunning(_ running: Bool) {
        guard started else { return }
        if running {
            foregroundFn(true)
            resumeFn()
        } else {
            foregroundFn(false)
            pauseFn()
        }
    }

    func quit() { if ready { quitFn() } }

    /// One finger drags along a polyline (each segment timed by its length), a point about every 16 ms, like a finger on a 60 Hz screen; times are in the guest's virtual milliseconds.
    func drag(path: [(Double, Double)], milliseconds: Int64) {
        guard path.count >= 2 else { return }
        var lengths: [Double] = []
        for i in 1..<path.count { lengths.append(hypot(path[i].0 - path[i - 1].0, path[i].1 - path[i - 1].1)) }
        let total = max(lengths.reduce(0, +), 1e-6)
        let steps = min(max(Int(milliseconds / 16), 2), 250)   // a sequence holds at most 256 events (IOS_INPUT_MAX_EVENTS)
        var at: [Int64] = [], kind: [Int32] = [], value: [Int32] = [], phase: [Int32] = []
        var xs: [Double] = [], ys: [Double] = []
        for i in 0...steps {
            var d = total * Double(i) / Double(steps), seg = 0
            while seg < lengths.count - 1 && d > lengths[seg] { d -= lengths[seg]; seg += 1 }
            let t = lengths[seg] > 0 ? min(d / lengths[seg], 1) : 1
            at.append(milliseconds * Int64(i) / Int64(steps))
            kind.append(1)
            value.append(0)
            phase.append(i == 0 ? TouchPhase.begin.rawValue : TouchPhase.update.rawValue)
            xs.append(path[seg].0 + (path[seg + 1].0 - path[seg].0) * t)
            ys.append(path[seg].1 + (path[seg + 1].1 - path[seg].1) * t)
        }
        at.append(milliseconds + 16)
        kind.append(1)
        value.append(0)
        phase.append(TouchPhase.end.rawValue)
        xs.append(path.last!.0)
        ys.append(path.last!.1)
        sequenceID += 1
        _ = sequenceFn(sequenceID, at.count, at, kind, value, phase, xs, ys)
    }

    /// One-finger drag, timed in the guest's virtual milliseconds (much slower in real time under the interpreter, but the gesture keeps its shape).
    func drag(from a: (Double, Double), to b: (Double, Double), milliseconds: Int64 = 600, steps: Int = 20) {
        var at: [Int64] = [], kind: [Int32] = [], value: [Int32] = [], phase: [Int32] = []
        var xs: [Double] = [], ys: [Double] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            at.append(milliseconds * Int64(i) / Int64(steps))
            kind.append(1)
            value.append(0)
            phase.append(i == 0 ? TouchPhase.begin.rawValue : TouchPhase.update.rawValue)
            xs.append(a.0 + (b.0 - a.0) * t)
            ys.append(a.1 + (b.1 - a.1) * t)
        }
        at.append(milliseconds + 50)
        kind.append(1)
        value.append(0)
        phase.append(TouchPhase.end.rawValue)
        xs.append(b.0)
        ys.append(b.1)
        sequenceID += 1
        _ = sequenceFn(sequenceID, at.count, at, kind, value, phase, xs, ys)
    }
}

/// An error the user may see. `description` is the text in the app's language, for the UI; `english` is the same text
/// in English, for events.log and import.log (scripts read those).
struct EngineError: Error, CustomStringConvertible {
    let description: String
    let english: String

    init(_ message: LocalizedStringResource) {
        description = String(localized: message)
        var english = message
        english.locale = Locale(identifier: "en")
        self.english = String(localized: english)
    }
}

extension Error {
    /// The error as events.log and import.log record it: English for EngineError, "\(error)" otherwise
    var logText: String { (self as? EngineError)?.english ?? "\(self)" }
}

/// Whether a debugger is attached (P_TRACED). Since iOS 26, TXM only accepts code pages a debugger has "prepared"; without a debugger the JIT build reports an error and exits.
func debuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}
