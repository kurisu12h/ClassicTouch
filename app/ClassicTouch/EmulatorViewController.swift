// 模拟器画面：客体画面、Home 键和电源键，左上「返回列表」，顶上一行状态（运行时间、CPU、内存、帧数）。触摸是单指，
// 坐标按客体屏幕归一化。开哪台、什么时候暂停由 RootViewController 管（一个进程只开一台，见 Engine.swift）。
//
// 脚本用的测试入口（启动参数，Xcode 的 Arguments、simctl launch 或 devicectl process launch 都能传；没有参数时读
// Documents/autostart.json，同名键，见 LaunchOptions.swift，从 StikDebug 拉起时用）。真实用户从列表开机时这些都不开：
//   -device <id>        直接开 Documents/devices/<id>
//   -select <id>        像用户在列表里点了这一台（走完整的选系统流程，没有 JIT 时会去 StikDebug），见 RootViewController
//   -tcg interp|jit     后端；默认有调试器时 JIT，否则解释器。真机上没调试器却要 JIT 时退回解释器
//   -tbsize <MB>        TCG 代码缓冲，默认 256
//   -autounlock <秒>    从第几秒起每 20 秒按一次 Home、5 秒后滑动解锁（最多 8 次），0 为关
//   -guestpng <秒>      每隔几秒把客体画面存成 PNG（画面有变化才存）；测试入口默认 5，从列表开机默认不存
//   -qemuargs "<...>"   追加给 QEMU 的参数，空格分隔
//   -resetstate YES     开机前删掉 state/，从 golden-state/（有的话）或设备本体重来，用于冷启动测量
//   -waitdebugger YES   和 -tcg jit 一起用：先等调试器挂上（最多 120 秒）再起 QEMU
//   -autodrive YES      App 自己认锁屏和主屏、解锁、待机 -idle 秒（默认 40）后退出（第三阶段，见 autodrive()）
//   -opensettings YES   和 -autodrive 一起用：待机结束后点开「设置」再按 Home 回主屏，然后退出（第四步，见 settingsTrip()）
//   -swipetest YES      和 -autodrive 一起用：锁屏和主屏上的滑动测试，分段记帧数和 CPU（M2 性能，见 swipeLock()、swipeHome()）
//   -perf YES           QEMU 每秒在 qemu.log 里记 GL 桥、显示和发布帧的耗时（IT_PERF=1，patches/ios-gles-perf.patch）
//   -qemuenv "A=1 B=2"  给 QEMU 的额外环境变量（autostart.json 里写成对象），比如 IT_GLES_STRICT=0
//   -usbkbd YES         有 USB 主机口的机型挂 USB 键盘（默认不挂，见 DeviceProfile.boot）
//   -jitprotocol legacy 真机 JIT 用旧的 brk #0x69 协议（默认是通用协议 brk #0xf00d）
//   -fakejit on|off|nostik  只在模拟器里：假装有没有 JIT、装没装 StikDebug（见 JIT.swift）
// 每次运行的记录放在 Documents/logs/<时间>-<设备>-<后端>/：qemu.log（stderr）、serial.log、stats.csv、
// events.log、argv.json、threads.csv（按线程的 CPU），测试入口还有 guest-*.png、app-*.png。宿主可以往 Documents/control/ 放命令文件（见 pollControl）。
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

final class EmulatorViewController: UIViewController {
    private(set) var engine: Engine?
    private(set) var profile: DeviceProfile?
    /// QEMU 已经退出，或开机失败
    private(set) var stopped = false
    var engineStarted: Bool { engine?.started == true }
    var onBackToList: (() -> Void)?
    var onEngineStarted: (() -> Void)?
    var onStopped: (() -> Void)?
    /// control/ 里 Root 处理的命令：back、resume、select（参数是文件内容）
    var onControl: ((String, String) -> Void)?

    private let deviceID: String
    private let requestedBackend: Engine.Backend?
    /// 脚本的测试入口（-device 或 autostart.json），不是用户从列表开的
    private let test: Bool
    private let documents: URL
    private let defaults: LaunchOptions
    private var afterExit: (() -> Void)?

    private let screen = ScreenView()
    private let status = UILabel()
    private let backButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let powerButton = UIButton(type: .system)

    private var displayLink: CADisplayLink?
    private var timer: Timer?
    private var serial: UInt64 = 0
    private var frames = 0
    private var guestSize = CGSize(width: 320, height: 480)
    private var lastImage: CGImage?
    private var savedSerial: UInt64 = 0

    private var runDir: URL?
    private var stats: StatsLog?
    private var events: FileHandle?
    private var start: Double = 0
    private var lastGuestPNG: Double = -1000
    private var lastAppPNG: Double = -1000
    private var unlockAttempts = 0
    private var lastUnlock: Double = -1000
    private var sawBacklight = false
    private var waitedForDebugger = false
    // autodrive：App 自己认锁屏和主屏（GuestText），解锁、待机、退出，全程不用 Mac 插手
    private let ocrQueue = DispatchQueue(label: "guest-ocr", qos: .utility)
    private var ocrBusy = false
    private var lockSeenAt: Double?
    private var homeSeenAt: Double?
    private var autoUnlocks = 0
    private var lastAutoUnlock: Double = -1000
    // opensettings：待机结束后点「设置」、认出设置页、按 Home、认回主屏
    private var idleEndAt: Double?
    private var settingsIcon: CGPoint?
    private var settingsTapAt: Double?
    private var settingsTaps = 0
    private var settingsSeenAt: Double?
    private var homePressAt: Double?
    private var homePresses = 0
    private var tripDoneAt: Double?
    // swipetest：锁屏静止、来回拖动、解锁；主屏静止、翻页、按住来回拖、再静止。每段的起止记进 events.log
    // （seg <名> begin|end serial= cpu=），scripts/ios/summarize-swipe.py 算每段的帧数和 CPU
    private var threads: ThreadLog?
    private var swipeLockAt: Double?
    private var swipeLockDoneAt: Double?
    private var swipeHomeStarted = false
    private var swipeDone = false
    private var inSegment = false

    init(deviceID: String, backend: Engine.Backend?, test: Bool, options: LaunchOptions, documents: URL) {
        self.deviceID = deviceID
        requestedBackend = backend
        self.test = test
        defaults = options
        self.documents = documents
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = UIColor(white: 1, alpha: 0.75)
        status.numberOfLines = 2
        status.textAlignment = .center
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7
        view.addSubview(status)

        screen.backgroundColor = UIColor(white: 0.05, alpha: 1)
        screen.layer.magnificationFilter = .linear
        screen.isHidden = true
        view.addSubview(screen)

        backButton.setTitle(String(localized: "‹ 返回列表"), for: .normal)
        backButton.tintColor = .white
        backButton.titleLabel?.font = .systemFont(ofSize: 15)
        backButton.contentHorizontalAlignment = .left
        backButton.addAction(UIAction { [weak self] _ in
            self?.event("back_to_list")
            self?.onBackToList?()
        }, for: .touchUpInside)
        view.addSubview(backButton)

        homeButton.setTitle("Home", for: .normal)
        powerButton.setTitle(String(localized: "电源"), for: .normal)
        for (button, target) in [(homeButton, QemuButton.home), (powerButton, QemuButton.power)] {
            button.tintColor = .white
            button.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
            button.layer.borderWidth = 1
            button.isHidden = true
            button.addAction(UIAction { [weak self] _ in self?.engine?.button(target, down: true) }, for: .touchDown)
            for up: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                button.addAction(UIAction { [weak self] _ in self?.engine?.button(target, down: false) }, for: up)
            }
            view.addSubview(button)
        }
        homeButton.layer.cornerRadius = 28
        powerButton.layer.cornerRadius = 6

        screen.onTouch = { [weak self] phase, x, y in self?.engine?.touch(phase, x: x, y: y) }
        boot(id: deviceID, backend: requestedBackend)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        backButton.frame = CGRect(x: safe.minX + 12, y: safe.minY, width: 96, height: 32)
        status.frame = CGRect(x: backButton.frame.maxX, y: safe.minY, width: safe.width - 2 * 108, height: 32)
        let area = CGRect(x: safe.minX, y: status.frame.maxY + 4, width: safe.width, height: safe.height - 32 - 4 - 96)
        let scale = min(area.width / guestSize.width, area.height / guestSize.height)
        let size = CGSize(width: guestSize.width * scale, height: guestSize.height * scale)
        screen.frame = CGRect(x: area.midX - size.width / 2, y: area.minY + (area.height - size.height) / 2,
                              width: size.width, height: size.height)
        homeButton.frame = CGRect(x: safe.midX - 28, y: screen.frame.maxY + 20, width: 56, height: 56)
        powerButton.frame = CGRect(x: screen.frame.maxX - 64, y: screen.frame.maxY + 32, width: 64, height: 32)
    }

    /// 回到列表或 App 进后台时停（reason 记进 events.log），回来时继续
    func setRunning(_ running: Bool, reason: String) {
        guard let engine, engine.started, !stopped else { return }
        engine.setRunning(running)
        displayLink?.isPaused = !running
        event(running ? "vm_resume" : "vm_pause reason=\(reason)")
    }

    /// 让 QEMU 正常退出（qmp quit），退出后调 then；还没起来就直接调
    func quitEngine(then: @escaping () -> Void) {
        guard let engine, engine.ready, !stopped else { return then() }
        afterExit = then
        engine.quit()   // 停着的虚拟机也能 quit

    }

    // MARK: 开机

    private func boot(id: String, backend requested: Engine.Backend?) {
        // JIT 要调试器在 QEMU 分配代码区之前挂上（region.c 那时就要 brk #0x69 请它准备代码区）。
        // 用 devicectl --start-stopped 挂会留下一个挂起的 SIGSTOP，所以改成 App 正常启动、在这里等。
        if requested == .jit, defaults.bool(forKey: "waitdebugger"), !debuggerAttached(), !waitedForDebugger {
            // 等调试器之前先把 JIT 版的库加载好：挂上之后再 dlopen 34 MB 的库，LLDB 要在内部处理 dyld 的加载通知，
            // 和调试器脚本发的「继续」撞上就会 Resume timed out 卡死（第二阶段约一半的挂载这样失败）。
            Engine.preload(.jit)
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            status.text = String(localized: "JIT：等待调试器挂上（最多 120 秒）…")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                if debuggerAttached() || ProcessInfo.processInfo.systemUptime > deadline {
                    t.invalidate()
                    self.waitedForDebugger = true
                    self.boot(id: id, backend: requested)
                }
            }
            return
        }
        start = ProcessInfo.processInfo.systemUptime
        do {
            let profile = try DeviceProfile(base: documents.appendingPathComponent("devices/\(id)", isDirectory: true))
            self.profile = profile
            guestSize = CGSize(width: profile.info.width, height: profile.info.height)
            var backend = requested ?? (debuggerAttached() ? .jit : .interp)
            var note = ""
            #if !targetEnvironment(simulator)
            if backend == .jit && !debuggerAttached() {
                backend = .interp
                note = "（没有调试器，JIT 退回解释器）"
            }
            #endif

            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let run = "\(stamp.string(from: Date()))-\(id)-\(backend.rawValue)"
            let dir = documents.appendingPathComponent("logs/\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            runDir = dir
            // QEMU 的报错都打在 stderr/stdout；启动失败时它会直接 exit，留下的只有这个文件。
            freopen(dir.appendingPathComponent("qemu.log").path, "a", stderr)
            freopen(dir.appendingPathComponent("qemu.log").path, "a", stdout)
            setvbuf(stderr, nil, _IONBF, 0)
            setvbuf(stdout, nil, _IOLBF, 0)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("events.log").path, contents: nil)
            events = try FileHandle(forWritingTo: dir.appendingPathComponent("events.log"))
            stats = StatsLog(url: dir.appendingPathComponent("stats.csv"))
            threads = ThreadLog(url: dir.appendingPathComponent("threads.csv"))

            if defaults.bool(forKey: "resetstate") { try profile.resetState() }
            try profile.prepareState()
            let bootrom = try placeholderBootrom(in: documents)
            // 不用 UserDefaults：它把以「-」开头的值（比如 "-qmp tcp:…"）当成下一个键，这里直接取 -qemuargs 后面那一项
            let launch = ProcessInfo.processInfo.arguments
            let raw = launch.firstIndex(of: "-qemuargs").flatMap { $0 + 1 < launch.count ? launch[$0 + 1] : nil }
            let extra = (raw ?? "").split(separator: " ").map(String.init)
            let tb = defaults.integer(forKey: "tbsize")
            let usbKeyboard = defaults.bool(forKey: "usbkbd")
            var (argv, env) = try profile.boot(backend: backend, bootrom: bootrom, logs: dir, run: "0",
                                               tbSize: tb > 0 ? tb : 256, usbKeyboard: usbKeyboard, extra: extra)
            // tcg/region.c（patches/ios-txm-jit-protocol.patch）：legacy 时用旧的 brk #0x69
            if let jitProtocol = defaults.string(forKey: "jitprotocol") { env["QEMU_IOS_JIT_PROTOCOL"] = jitProtocol }
            if defaults.bool(forKey: "perf") { env["IT_PERF"] = "1" }
            env.merge(defaults.environment(forKey: "qemuenv")) { _, new in new }
            try JSONSerialization.data(withJSONObject: ["argv": argv, "env": env], options: .prettyPrinted)
                .write(to: dir.appendingPathComponent("argv.json"))

            let engine = try Engine(backend: backend)
            self.engine = engine
            engine.onExit = { [weak self] code in
                guard let self else { return }
                self.event("qemu_exit status=\(code)")
                self.stopped = true
                self.displayLink?.isPaused = true
                self.status.text = String(format: String(localized: "已关机（%d），记录在 logs/%@/qemu.log"), code, run)
                self.onStopped?()
                self.afterExit?()
                self.afterExit = nil
            }
            start = ProcessInfo.processInfo.systemUptime
            // QEMU 的 [perf] 行记的是开机以来的秒数（CLOCK_UPTIME_RAW），减掉这个就是本文件的时间
            event(String(format: "clock up0=%.3f", start))
            let source = test ? (defaults.fromFile ? "autostart.json" : "arguments") : "list"
            event("boot config=\(source) device=\(id) board=\(profile.board) version=\(profile.productVersion) backend=\(backend.rawValue) "
                  + "build=\(engine.buildID) debugger=\(debuggerAttached()) bootrom=\(bootrom.lastPathComponent) "
                  + "usbkbd=\(profile.info.hasUSBHost && usbKeyboard)\(note)")
            #if targetEnvironment(simulator)
            engine.start(argv: argv, environment: env)
            onEngineStarted?()
            #else
            if backend == .jit {
                // QEMU 一起来就请调试器准备代码区，这期间整个 App 被调试器停住、画面不动（StikDebug 不到 1 秒）。
                // 先把这句画出来再起 QEMU。
                status.text = String(localized: "JIT：StikDebug 在准备代码区，画面会停一下")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    engine.start(argv: argv, environment: env)
                    self?.onEngineStarted?()
                }
            } else {
                engine.start(argv: argv, environment: env)
                onEngineStarted?()
            }
            #endif

            screen.isHidden = false
            homeButton.isHidden = false
            powerButton.isHidden = false
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
            view.setNeedsLayout()
        } catch {
            status.text = String(format: String(localized: "开机失败：%@"), "\(error)")
            event("boot_failed \(error)")
            stopped = true
            onStopped?()
        }
    }

    func event(_ text: String) {
        let line = String(format: "%.1f %@\n", ProcessInfo.processInfo.systemUptime - start, text)
        events?.write(Data(line.utf8))
    }

    // MARK: 画面

    @objc private func tick() {
        guard let engine, engine.started, let f = engine.frame(after: &serial) else { return }
        let bytesPerRow = f.width * 4
        let data = Data(bytes: f.pixels, count: bytesPerRow * f.height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        if frames == 0 { event("first_frame \(f.width)x\(f.height)") }
        frames += 1
        lastImage = image
        if CGSize(width: f.width, height: f.height) != guestSize {
            guestSize = CGSize(width: f.width, height: f.height)
            view.setNeedsLayout()
        }
        screen.layer.contents = image
    }

    private func everySecond() {
        guard let engine, let stats else { return }
        let sample = ProcessSample.now(since: start)
        let backlight = engine.ready ? engine.backlightLevel : -1
        let pct = stats.append(sample, serial: serial, backlight: backlight)
        threads?.append(wall: sample.wall)
        if backlight > 0 && !sawBacklight {
            sawBacklight = true
            event("backlight_on level=\(backlight)")
        }
        let minutes = Int(sample.wall) / 60, seconds = Int(sample.wall) % 60
        if !stopped {
            status.text = String(
                format: String(localized: "%@ · %@ · %d:%02d\nCPU %.0f%%（累计 %.0f 秒）· 占用 %.0f MB · 可用 %.0f MB · 帧 %d"),
                profile?.displayName ?? "", engine.backend == .jit ? "JIT" : String(localized: "解释器（慢）"), minutes, seconds,
                pct, sample.cpuSeconds, Double(sample.footprint) / 1_048_576, Double(sample.available) / 1_048_576, frames)
        }

        // 存图只给脚本用：测试入口默认每 5 秒存一张客体画面、每 15 秒一张窗口截图；从列表开机时不存（除非指定 -guestpng）
        let given = defaults.double(forKey: "guestpng")
        let every = given > 0 ? given : (test ? 5 : 0)
        if every > 0, !inSegment, let image = lastImage, serial != savedSerial, sample.wall - lastGuestPNG >= every {
            savedSerial = serial
            lastGuestPNG = sample.wall
            save(UIImage(cgImage: image), name: String(format: "guest-%04d.png", Int(sample.wall)))
        }
        if test, !inSegment, sample.wall - lastAppPNG >= 15, let window = view.window {
            lastAppPNG = sample.wall
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            save(shot, name: String(format: "app-%04d.png", Int(sample.wall)))
        }

        let unlockFrom = defaults.double(forKey: "autounlock")
        if unlockFrom > 0, sample.wall >= unlockFrom, unlockAttempts < 8, sample.wall - lastUnlock >= 20, engine.ready {
            unlockAttempts += 1
            lastUnlock = sample.wall
            event("unlock_attempt \(unlockAttempts)")
            unlock(engine)
        }
        pollControl(engine)
        if defaults.bool(forKey: "autodrive") { autodrive(engine, at: sample.wall) }
    }

    /// 锁屏几秒不碰就熄屏，熄屏时滑动无效：先按一下 Home 叫醒，等解释器把屏点亮再滑。
    /// 每秒认一次客体画面：看到锁屏就解锁（熄屏时 unlock 先按 Home 叫醒），每 12 秒重试；认出主屏后停止识别，
    /// 待机 idle 秒（默认 40）后让 QEMU 退出（opensettings 时先走一趟 settingsTrip）。
    /// lock_seen、home_seen 的时间就是开机测量的锁屏、主屏时间。
    private func autodrive(_ engine: Engine, at now: Double) {
        let swipe = defaults.bool(forKey: "swipetest")
        if let home = homeSeenAt {
            if swipe && !swipeHomeStarted {
                swipeHomeStarted = true
                swipeHome(engine)
            }
            let idle = defaults.double(forKey: "idle")
            guard now - home >= (idle > 0 ? idle : 40), engine.ready, !swipe || swipeDone else { return }
            if defaults.bool(forKey: "opensettings"), tripDoneAt == nil {
                settingsTrip(engine, at: now)
            } else if now - (tripDoneAt ?? 0) >= 5 {
                event("auto_quit")
                engine.quit()
            }
            return
        }
        if swipe, lockSeenAt != nil, swipeLockAt == nil {
            swipeLockAt = now
            swipeLock(engine)
        }
        // 滑动测试的锁屏段自己解锁；它做完 12 秒还没到主屏才照常重试
        let swipeHolds = swipe && lockSeenAt != nil && (swipeLockDoneAt.map { now - $0 < 12 } ?? true)
        if !swipeHolds, let lock = lockSeenAt, now - lastAutoUnlock >= 12, now - lock < 300, autoUnlocks < 12 {
            autoUnlocks += 1
            lastAutoUnlock = now
            event("auto_unlock \(autoUnlocks)")
            unlock(engine)
        }
        // 锁屏段测量时不跑文字识别（它也算在本进程的 CPU 里）
        guard !ocrBusy, !(swipe && lockSeenAt != nil && swipeLockDoneAt == nil), let image = lastImage else { return }
        ocrBusy = true
        ocrQueue.async { [weak self] in
            let texts = GuestText.recognize(image).texts
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrBusy = false
                let t = ProcessInfo.processInfo.systemUptime - self.start
                if self.lockSeenAt == nil, GuestText.isLockScreen(texts) {
                    self.lockSeenAt = t
                    self.event(String(format: "lock_seen %.1f", t))
                    self.lastAutoUnlock = -1000  // 马上解锁，别等到它熄屏进深睡
                } else if self.lockSeenAt != nil, self.homeSeenAt == nil, GuestText.isHomeScreen(texts) {
                    self.homeSeenAt = t
                    self.event(String(format: "home_seen %.1f", t))
                }
            }
        }
    }

    /// 滑动测试的分段标记：events.log 记「seg <名> begin|end serial=<帧编号> cpu=<本进程 CPU 秒>」。
    private func segment(_ name: String, _ edge: String) {
        inSegment = edge == "begin"
        let cpu = ProcessSample.now(since: start).cpuSeconds
        event(String(format: "seg %@ %@ serial=%llu cpu=%.2f", name, edge, serial, cpu))
    }

    /// 按开始时间排好的一串动作（秒，从现在起）
    private func schedule(_ steps: [(Double, () -> Void)]) {
        for (at, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, !self.stopped else { return }
                step()
            }
        }
    }

    /// 滑动测试的锁屏段（认出锁屏后马上开始）：静止 4 秒（iOS 7 的「滑动解锁」微光是连续动画）；
    /// 3 次在锁屏底部按住往右拖到 0.55 再拖回来松手（1.6 秒一次，不解锁，iOS 7 整个锁屏跟着手走，3.x、6.x 是滑块）；
    /// 然后慢慢滑动解锁。期间不按 Home、不做文字识别。
    private func swipeLock(_ engine: Engine) {
        let y = 0.9
        var steps: [(Double, () -> Void)] = [(0, { self.segment("lock_static", "begin") }),
                                              (4, { self.segment("lock_static", "end"); self.segment("lock_drag", "begin") })]
        for i in 0..<3 {
            steps.append((4.2 + 2.0 * Double(i), {
                engine.drag(path: [(0.15, y), (0.55, y), (0.15, y)], milliseconds: 1600)
            }))
        }
        steps.append((10.4, { self.segment("lock_drag", "end") }))
        steps.append((10.6, {
            self.event("swipe_unlock")
            engine.drag(path: [(0.12, y), (0.95, y)], milliseconds: 700)
        }))
        steps.append((11.5, { self.swipeLockDoneAt = ProcessInfo.processInfo.systemUptime - self.start }))
        schedule(steps)
    }

    /// 滑动测试的主屏段（认出主屏后）：3 秒后静止 6 秒；6 次翻页（左右交替，每次 0.25 秒，间隔 1.5 秒）；
    /// 按住在 0.3 和 0.7 之间来回拖 4 秒（M0 的拖动测法）；松手 1 秒后再静止 10 秒。然后照常待机、退出。
    private func swipeHome(_ engine: Engine) {
        let y = 0.45
        var steps: [(Double, () -> Void)] = [(3, { self.segment("home_static", "begin") }),
                                              (9, { self.segment("home_static", "end"); self.segment("home_swipe", "begin") })]
        for i in 0..<6 {
            let path = i % 2 == 0 ? [(0.8, y), (0.2, y)] : [(0.2, y), (0.8, y)]
            steps.append((9.2 + 1.5 * Double(i), { engine.drag(path: path, milliseconds: 250) }))
        }
        steps.append((18.5, { self.segment("home_swipe", "end"); self.segment("home_drag", "begin") }))
        steps.append((18.6, {
            engine.drag(path: [(0.5, y), (0.7, y), (0.3, y), (0.7, y), (0.3, y), (0.5, y)], milliseconds: 4000)
        }))
        steps.append((22.7, { self.segment("home_drag", "end") }))
        steps.append((24, { self.segment("home_static2", "begin") }))
        steps.append((34, { self.segment("home_static2", "end"); self.swipeDone = true }))
        schedule(steps)
    }

    /// 第四步：确认触摸和 Home 键在客体里能用。待机段到此为止（idle_end，scripts/ios/summarize-run.py 的待机 CPU
    /// 截到这里）。主屏上认出「Settings」字样就点它上方的图标（M0 bench.py 的做法），认出设置页后存下这张客体画面
    /// （settings-*.png），2 秒后按 Home，认回主屏再存一张（home-back-*.png），5 秒后退出。
    /// 点图标和按 Home 各 20 秒没反应就再来一次，最多各 3 次；整段超过 150 秒就记 settings_trip_timeout 照常退出。
    private func settingsTrip(_ engine: Engine, at now: Double) {
        if idleEndAt == nil {
            idleEndAt = now
            event("idle_end")
        }
        if let begun = idleEndAt, now - begun > 150 {
            event("settings_trip_timeout")
            tripDoneAt = now
            return
        }
        if settingsSeenAt == nil {
            if let icon = settingsIcon, settingsTaps < 3, now - (settingsTapAt ?? -1000) >= 20 {
                settingsTaps += 1
                settingsTapAt = now
                // 字样中心往上 0.06：iPhone 4 上约 58 像素，320x480 的机型上约 29 像素，都落在图标里
                let x = Double(icon.x), y = Double(icon.y) - 0.06
                event(String(format: "tap_settings %d at %.3f,%.3f", settingsTaps, x, y))
                engine.touch(.begin, x: x, y: y)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { engine.touch(.end, x: x, y: y) }
            }
        } else if let seen = settingsSeenAt, now - seen >= 2, homePresses < 3, now - (homePressAt ?? -1000) >= 20 {
            homePresses += 1
            homePressAt = now
            event("home_press \(homePresses)")
            pressHome(engine)
        }
        guard !ocrBusy, let image = lastImage else { return }
        ocrBusy = true
        ocrQueue.async { [weak self] in
            let reading = GuestText.recognize(image, locate: ["Settings"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrBusy = false
                let t = ProcessInfo.processInfo.systemUptime - self.start
                if self.settingsSeenAt == nil {
                    if GuestText.isSettingsScreen(reading.texts) {
                        self.settingsSeenAt = t
                        self.event(String(format: "settings_seen %.1f", t))
                        self.save(UIImage(cgImage: image), name: String(format: "settings-%04d.png", Int(t)))
                    } else if self.settingsIcon == nil, GuestText.isHomeScreen(reading.texts),
                              let icon = reading.places["Settings"] {
                        self.settingsIcon = icon
                        self.event(String(format: "settings_label %.3f,%.3f", icon.x, icon.y))
                    }
                } else if self.homePressAt != nil, self.tripDoneAt == nil, GuestText.isHomeScreen(reading.texts) {
                    self.tripDoneAt = t
                    self.event(String(format: "home_back %.1f", t))
                    self.save(UIImage(cgImage: image), name: String(format: "home-back-%04d.png", Int(t)))
                }
            }
        }
    }

    private func unlock(_ engine: Engine) {
        pressHome(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { engine.drag(from: (0.18, 0.9), to: (0.92, 0.9)) }
    }

    private func pressHome(_ engine: Engine) {
        engine.button(.home, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { engine.button(.home, down: false) }
    }

    /// 宿主（scripts/ios/sim-boot.sh、device-boot.sh）的控制通道：往 Documents/control/ 放一个文件，文件名就是命令。
    /// unlock：按 Home 后滑动解锁；home：按一下 Home；quit：让 QEMU 正常退出；
    /// back：返回列表；resume：从列表回到画面；select：像用户在列表里点了文件内容写的那台（换系统，不弹确认）。
    private func pollControl(_ engine: Engine) {
        let dir = documents.appendingPathComponent("control", isDirectory: true)
        for command in ["unlock", "home", "quit", "back", "resume", "select"] {
            let file = dir.appendingPathComponent(command)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let argument = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: file)
            event("control \(command)")
            switch command {
            case "unlock": unlock(engine)
            case "home": pressHome(engine)
            case "quit": engine.quit()
            // 脚本每次写进不同的内容（devicectl 会跳过没变过的文件），select 取第一个词
            default: onControl?(command, String(argument.split(separator: " ").first ?? ""))
            }
        }
    }

    private func save(_ image: UIImage, name: String) {
        guard let dir = runDir, let png = image.pngData() else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }
}

/// 客体屏幕：单指触摸转成归一化坐标。
final class ScreenView: UIView {
    var onTouch: ((TouchPhase, Double, Double) -> Void)?
    private weak var tracked: UITouch?

    private func send(_ phase: TouchPhase, _ touch: UITouch) {
        let p = touch.location(in: self)
        onTouch?(phase, Double(p.x / bounds.width), Double(p.y / bounds.height))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let t = touches.first else { return }
        tracked = t
        send(.begin, t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = tracked, touches.contains(t) { send(.update, t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = tracked, touches.contains(t) {
            send(.end, t)
            tracked = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}
