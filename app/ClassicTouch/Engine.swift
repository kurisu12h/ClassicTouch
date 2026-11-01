// qemu-ios 引擎：dlopen 嵌在 Frameworks 里的 libqemu-arm-<interp|jit>.dylib，用 dlsym 取它导出的 App ABI
// （upstream qemu-ios contrib/ios-app/qemu-ios-ui.h，常量照抄在下面）。QEMU 不能在一个进程里起两次，
// 所以一次启动只开一台设备，换设备要重开 App。
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
    /// QEMU 线程退出时（虚拟机停下或启动失败）在主线程上调用，参数是 qemu_ios_main 的返回值。
    var onExit: ((Int32) -> Void)?

    private static func path(_ backend: Backend) -> String? {
        Bundle.main.privateFrameworksPath.map {
            ($0 as NSString).appendingPathComponent("libqemu-arm-\(backend.rawValue).dylib")
        }
    }

    /// 提前加载（引用计数，之后 init 里的 dlopen 拿到同一个句柄）。
    static func preload(_ backend: Backend) {
        if let path = path(backend) { _ = dlopen(path, RTLD_NOW | RTLD_LOCAL) }
    }

    init(backend: Backend) throws {
        self.backend = backend
        let name = "libqemu-arm-\(backend.rawValue).dylib"
        guard let path = Engine.path(backend) else { throw EngineError("找不到 App 的 Frameworks 目录") }
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineError("dlopen \(name) 失败：\(String(cString: dlerror()))")
        }
        handle = h
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw EngineError("dylib 里没有 \(name)") }
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

    /// 在一条 8 MB 栈的后台线程上跑 qemu_ios_main；它要到虚拟机停下才返回。
    func start(argv: [String], environment: [String: String]) {
        precondition(!started, "QEMU 一个进程只能起一次")
        started = true
        for (key, value) in environment { setenv(key, value, 1) }
        // 显示监听器在虚拟机有控制台后才真正注册；帧由界面按屏幕刷新去取，回调什么也不用做。
        attach({ _ in }, nil)
        let main = qemuMain
        let thread = Thread { [weak self] in
            // 故意不释放：QEMU 会一直拿着 argv 里的指针。
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

    /// 最新一帧（紧密排列的 BGRA，不拷贝）。serial 传上次见到的编号，没有更新的帧就返回 nil。
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

    /// iOS 会杀掉在后台发 GL 命令的进程，所以要在 willResignActive 时就清掉。
    func setForeground(_ foreground: Bool) {
        if started { foregroundFn(foreground) }
    }

    /// 让虚拟机停下或继续跑（App 进后台、回到列表时停）。停的时候先清前台标志：iOS 会杀掉在后台发 GL 命令的进程，
    /// 而 qemu_ios_ui_pause（QMP stop）是排到 QEMU 主循环上异步做的。继续时 set_foreground(true) 本身就会
    /// 把停住的虚拟机重新跑起来（qemu-ios-ui.c 的 ios_resume_bh），再发一次 QMP cont 没有副作用。
    /// 虚拟机还没起来（qemu_ios_ui_ready 之前）时 pause/resume 什么也不做。
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

    /// 一指沿折线拖动（各段按长度分时间），每 16 毫秒左右一个点，像手指在 60 Hz 屏幕上；时间按客体的虚拟毫秒算。
    func drag(path: [(Double, Double)], milliseconds: Int64) {
        guard path.count >= 2 else { return }
        var lengths: [Double] = []
        for i in 1..<path.count { lengths.append(hypot(path[i].0 - path[i - 1].0, path[i].1 - path[i - 1].1)) }
        let total = max(lengths.reduce(0, +), 1e-6)
        let steps = min(max(Int(milliseconds / 16), 2), 250)   // 一个序列最多 256 个事件（IOS_INPUT_MAX_EVENTS）
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

    /// 一指拖动，时间按客体的虚拟毫秒算（解释器下实际会慢很多，但手势形状不走样）。
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

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 有没有调试器挂着（P_TRACED）。iOS 26 起 TXM 只认调试器「准备」过的代码页，没调试器时 JIT 版会直接报错退出。
func debuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}
