// 顶层：决定一启动做什么，在系统列表和模拟器画面之间切换，管虚拟机什么时候跑。
//
// 一启动：
//   1. 有启动参数或 Documents/autostart.json 指定设备（脚本的测试入口）：等导入完直接开这台，和 M1 以来一样；
//   2. 有 PendingBoot（用户在列表里选了一台，App 去 StikDebug 开 JIT 或让用户重开后，这是新进程）：直接开那台；
//   3. 否则显示列表。
// 选系统（select）：
//   - 这个进程还没起过 QEMU：有 JIT 就开；没有 JIT 但装了 StikDebug，记下 PendingBoot、打开 stikjit://、自己退出，
//     StikDebug 会挂着调试器拉起一个新进程；没装 StikDebug 就说明一下，可以选解释器开机。
//   - 起过 QEMU（一个进程只能起一次）：同一台就回去继续；换别的要新进程：有 StikDebug 同上，没有就请用户重开 App。
// 虚拟机只在 App 处于前台、而且正显示模拟器画面时跑（updateRun）：进后台、回到列表都暂停。
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

final class RootViewController: UIViewController {
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var options = LaunchOptions(documents: documents)
    private lazy var imports = ImportManager(documents: documents)
    private lazy var library = LibraryViewController(documents: documents, imports: imports)
    private lazy var nav = UINavigationController(rootViewController: library)
    private(set) var emulator: EmulatorViewController?
    private var shown: UIViewController?
    private var appActive = false
    private var running: Bool?
    private var exiting = false

    override var childForStatusBarHidden: UIViewController? { shown }
    override var childForHomeIndicatorAutoHidden: UIViewController? { shown }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { shown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        library.onSelect = { [weak self] in self?.select($0, confirm: true) }
        library.onResume = { [weak self] in self?.showEmulator() }
        library.onJITHelp = { [weak self] in self?.showJITHelp() }
        imports.onChange = { [weak self] in self?.library.reload() }
        show(nav)
        refreshLibrary()
        imports.start()
        pruneLogs()

        if let id = options.string(forKey: "device") {
            PendingBoot.clear()
            let backend = options.string(forKey: "tcg").flatMap(Engine.Backend.init(rawValue:))
            whenImportsIdle { [weak self] in self?.boot(id, backend: backend, test: true) }
        } else if let pending = PendingBoot.take() {
            bootPending(pending)
        } else if let id = options.string(forKey: "select") {
            // 测试入口：模拟用户在列表里点了这一台（走完整的选系统流程，包括去 StikDebug）
            whenImportsIdle { [weak self] in
                guard let self, let device = self.device(id) else { return }
                self.select(device, confirm: false)
            }
        }
    }

    private func whenImportsIdle(_ then: @escaping () -> Void) {
        if imports.idle { return then() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.imports.idle {
                t.invalidate()
                then()
            }
        }
    }

    private func device(_ id: String) -> DeviceProfile? {
        try? DeviceProfile(base: documents.appendingPathComponent("devices/\(id)", isDirectory: true))
    }

    // MARK: 前后台

    func setAppActive(_ active: Bool) {
        appActive = active
        if active { imports.scan() }
        updateRun()
    }

    private func updateRun() {
        guard let emulator, emulator.engineStarted else { return }
        let run = appActive && shown === emulator
        guard run != running else { return }
        running = run
        emulator.setRunning(run, reason: appActive ? "list" : "background")
    }

    // MARK: 切换画面

    private func show(_ vc: UIViewController) {
        guard vc !== shown else { return }
        let old = shown
        // 先登记再取 vc.view：模拟器画面的 viewDidLoad 里就开机，引擎一起来就会问 updateRun「现在在不在显示」
        shown = vc
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        old?.willMove(toParent: nil)
        old?.view.removeFromSuperview()
        old?.removeFromParent()
        // 模拟器画面开着时不让手机自动锁屏；列表页照常
        UIApplication.shared.isIdleTimerDisabled = vc is EmulatorViewController
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    private func showEmulator() {
        guard let emulator else { return }
        show(emulator)
        updateRun()
    }

    private func backToList() {
        show(nav)
        refreshLibrary()
        updateRun()
    }

    private func refreshLibrary() {
        if let emulator, let profile = emulator.profile {
            library.current = CurrentSystem(id: profile.id, name: profile.displayName, stopped: emulator.stopped)
        } else {
            library.current = nil
        }
        if let engine = emulator?.engine, engine.started {
            library.jitState = engine.backend == .jit ? .inUse : (StikDebug.installed ? .needStik : .noStik)
        } else {
            library.jitState = JIT.ready ? .ready : (StikDebug.installed ? .needStik : .noStik)
        }
        imports.busyDevice = emulator?.engineStarted == true ? emulator?.profile?.id : nil
    }

    // MARK: 开机

    private func boot(_ id: String, backend: Engine.Backend?, test: Bool) {
        let vc = EmulatorViewController(deviceID: id, backend: backend, test: test, options: options, documents: documents)
        vc.onBackToList = { [weak self] in self?.backToList() }
        vc.onControl = { [weak self] command, argument in self?.control(command, argument) }
        vc.onEngineStarted = { [weak self] in
            self?.running = true
            self?.refreshLibrary()
            self?.updateRun()
        }
        vc.onStopped = { [weak self] in self?.refreshLibrary() }
        emulator = vc
        show(vc)
        updateRun()
    }

    /// StikDebug 拉起的新进程，或用户按提示重开的 App。StikDebug 是挂起启动、先挂上调试器再放行的，所以多半一起来就有 JIT；
    /// 保险起见等 5 秒。等不到就回列表说明。
    private func bootPending(_ pending: PendingBoot) {
        guard let device = device(pending.device) else { return }
        guard pending.wantJIT, !JIT.ready else {
            return boot(device.id, backend: JIT.ready ? .jit : .interp, test: false)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if JIT.ready {
                t.invalidate()
                self.boot(device.id, backend: .jit, test: false)
            } else if ProcessInfo.processInfo.systemUptime > deadline {
                t.invalidate()
                self.noJITAfterStikDebug(device)
            }
        }
    }

    /// 用户在列表里点了一台。confirm 为 false 时跳过「换系统」的确认（测试入口 -select、control/select 用）。
    private func select(_ device: DeviceProfile, confirm: Bool) {
        guard !exiting else { return }
        if let emulator, emulator.engineStarted {
            if emulator.profile?.id == device.id && !emulator.stopped { return showEmulator() }
            return switchSystem(to: device, confirm: confirm)
        }
        if JIT.ready { return boot(device.id, backend: .jit, test: false) }
        if StikDebug.installed { return relaunch(into: device, viaStikDebug: true) }
        askInterpreter(for: device, title: String(localized: "没有 JIT"),
                       message: String(localized: "没找到 StikDebug，拿不到 JIT。"))
    }

    private func switchSystem(to device: DeviceProfile, confirm: Bool) {
        let viaStikDebug = StikDebug.installed
        guard confirm else { return relaunch(into: device, viaStikDebug: viaStikDebug) }
        let running = emulator?.stopped == false ? emulator?.profile?.displayName : nil
        var message = viaStikDebug
            ? String(localized: "一次只能开一个系统。App 会跳到 StikDebug 开 JIT，再自动回来开这台。")
            : String(format: String(localized: "一次只能开一个系统，换系统要重新打开 App。点「关闭 App」后，在主屏幕上再点一次本 App 的图标（或者从多任务里划掉再打开），就会直接用解释器开 %@。"), device.displayName)
        if let running {
            message += "\n" + String(format: String(localized: "正在运行的 %@ 会被关掉，相当于直接拔电池。"), running)
        }
        let alert = UIAlertController(title: String(format: String(localized: "换成 %@？"), device.displayName),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: viaStikDebug ? String(localized: "换系统") : String(localized: "关闭 App"),
                                      style: .destructive) { [weak self] _ in
            self?.relaunch(into: device, viaStikDebug: viaStikDebug)
        })
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        present(alert, animated: true)
    }

    /// 换进程：记下要开的那台；QEMU 在跑就先让它正常退出（落盘），再去 StikDebug（或直接退出，等用户重开）。
    private func relaunch(into device: DeviceProfile, viaStikDebug: Bool) {
        exiting = true
        do {
            try PendingBoot(device: device.id, wantJIT: viaStikDebug).save()
        } catch {
            exiting = false
            return alert(String(localized: "出错了"), "\(error)")
        }
        emulator?.event("relaunch device=\(device.id) stikdebug=\(viaStikDebug)")
        stopQEMU { [weak self] in
            guard let self else { return }
            guard viaStikDebug else { exit(0) }
            if JIT.fake != nil {
                // 模拟器：假装 StikDebug 收到了请求。宿主再带 -fakejit on 启动 App，就是 StikDebug 拉起的新进程
                exit(0)
            }
            // StikDebug 不杀已有进程就去启动本 App，所以 URL 一交出去就得退出
            UIApplication.shared.open(StikDebug.url) { ok in
                if ok { exit(0) }
                PendingBoot.clear()
                self.exiting = false
                self.alert(String(localized: "打不开 StikDebug"),
                           String(localized: "请确认装了 StikDebug，然后重新打开本 App 再试。"))
            }
        }
    }

    /// 让 QEMU 走正常的退出（qmp quit，块设备落盘），最多等 2 秒
    private func stopQEMU(_ then: @escaping () -> Void) {
        guard let emulator, emulator.engineStarted, !emulator.stopped else { return then() }
        var done = false
        let finish = { if !done { done = true; then() } }
        emulator.quitEngine(then: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    private func noJITAfterStikDebug(_ device: DeviceProfile) {
        let alert = UIAlertController(
            title: String(localized: "没拿到 JIT"),
            message: String(localized: "StikDebug 没有给本 App 开 JIT。请确认 LocalDevVPN 开着、StikDebug 里导入过配对文件，再试一次。"),
            preferredStyle: .alert)
        if StikDebug.installed {
            alert.addAction(UIAlertAction(title: String(localized: "再试一次"), style: .default) { [weak self] _ in
                self?.relaunch(into: device, viaStikDebug: true)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "用解释器开机（很慢）"), style: .default) { [weak self] _ in
            self?.boot(device.id, backend: .interp, test: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        present(alert, animated: true)
    }

    private func askInterpreter(for device: DeviceProfile, title: String, message: String) {
        var text = message + "\n"
        text += device.majorVersion >= 7
            ? String(localized: "也可以用解释器开机，但 iOS 7 在解释器下基本不能用。")
            : String(localized: "也可以用解释器开机，但会慢很多：iPhone OS 3 约 1 分钟、iOS 6 约 2 分钟才到锁屏，用起来也卡。")
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "用解释器开机（很慢）"), style: .default) { [weak self] _ in
            self?.boot(device.id, backend: .interp, test: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "怎么装 StikDebug"), style: .default) { [weak self] _ in
            self?.showJITHelp()
        })
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        present(alert, animated: true)
    }

    private func showJITHelp() {
        alert(String(localized: "JIT 和 StikDebug"), String(localized: """
            JIT 让系统快 5 到 10 倍。iPhone 不直接给侧载 App 开 JIT，要靠开源的 StikDebug 在手机上给。
            一次性准备：侧载装好 StikDebug；从 App Store 装 LocalDevVPN；照 StikDebug 的说明在电脑上生成一次配对文件、导入 StikDebug。
            以后每次：打开 LocalDevVPN，回到本 App 点系统，会自动跳到 StikDebug，开好 JIT 后回来开机。StikDebug 可能会弹一次确认，点确认即可。
            """))
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        present(alert, animated: true)
    }

    // MARK: 测试入口：Documents/control/ 里 back、resume、select（文件内容是设备 id）

    private func control(_ command: String, _ argument: String) {
        switch command {
        case "back": backToList()
        case "resume": showEmulator()
        case "select":
            if let device = device(argument.trimmingCharacters(in: .whitespacesAndNewlines)) {
                select(device, confirm: false)
            }
        default: break
        }
    }

    /// 每次开机都在 Documents/logs/ 下建一个运行目录，只留最近 30 个
    private func pruneLogs() {
        let dir = documents.appendingPathComponent("logs", isDirectory: true)
        let runs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("20") }.sorted()
        for name in runs.dropLast(30) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
