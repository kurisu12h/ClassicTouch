// Top level: decides what to do at launch, switches between the system list and the emulator screen, and controls when
// the VM runs.
//
// At launch:
//   1. A device given by launch arguments or Documents/autostart.json (a test entry point for scripts): boot it directly
//      once imports are done, as since M1;
//   2. A PendingBoot (the user picked a device in the list, and the app went to StikDebug for JIT or asked the user to
//      reopen it; this is the new process): boot that device directly;
//   3. Otherwise show the list.
// Selecting a system (select):
//   - This process has not started QEMU yet: boot if JIT is there; without JIT but with StikDebug installed, save a
//     PendingBoot, open stikjit:// and exit, and StikDebug launches a new process with the debugger attached; without
//     StikDebug, explain and offer to boot with the interpreter.
//   - QEMU has started (it can start only once per process): the same device goes back to it; another one needs a new
//     process: with StikDebug as above, otherwise ask the user to reopen the app.
// The VM runs only while the app is in the foreground and showing the emulator screen (updateRun): it pauses in the
// background and on the list.
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
            // Test entry point: as if the user tapped this device in the list (the full selection flow, including StikDebug)
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

    // MARK: Foreground and background

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

    // MARK: Switching screens

    private func show(_ vc: UIViewController) {
        guard vc !== shown else { return }
        let old = shown
        // Register before reading vc.view: the emulator screen boots in viewDidLoad, and once the engine is up it asks updateRun whether it is being shown
        shown = vc
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        old?.willMove(toParent: nil)
        old?.view.removeFromSuperview()
        old?.removeFromParent()
        // While the emulator screen is up the phone does not auto-lock; the list behaves normally
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

    // MARK: Boot

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

    /// The new process StikDebug launched, or the app the user reopened as asked. StikDebug launches it suspended and lets
    /// it run only after attaching the debugger, so JIT is usually there right away; wait 5 seconds to be safe. If it never
    /// comes, go back to the list and explain.
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

    /// The user tapped a device in the list. With confirm false the "switch system" confirmation is skipped (for the -select test entry point and control/select).
    private func select(_ device: DeviceProfile, confirm: Bool) {
        guard !exiting else { return }
        if let emulator, emulator.engineStarted {
            if emulator.profile?.id == device.id && !emulator.stopped { return showEmulator() }
            return switchSystem(to: device, confirm: confirm)
        }
        if JIT.ready { return boot(device.id, backend: .jit, test: false) }
        if StikDebug.installed { return relaunch(into: device, viaStikDebug: true) }
        askInterpreter(for: device, title: String(localized: "No JIT"),
                       message: String(localized: "StikDebug wasn't found, so JIT isn't available."))
    }

    private func switchSystem(to device: DeviceProfile, confirm: Bool) {
        let viaStikDebug = StikDebug.installed
        guard confirm else { return relaunch(into: device, viaStikDebug: viaStikDebug) }
        let running = emulator?.stopped == false ? emulator?.profile?.displayName : nil
        var message = viaStikDebug
            ? String(localized: "Only one system can run at a time. The app will switch to StikDebug to turn on JIT, then come back and boot this one.")
            : String(format: String(localized: "Only one system can run at a time, and switching systems means reopening the app. After tapping “Close App”, tap this app's icon on the Home Screen again (or swipe it away in the app switcher and reopen it), and %@ will boot with the interpreter."), device.displayName)
        if let running {
            message += "\n" + String(format: String(localized: "The running %@ will be shut down, like pulling the battery."), running)
        }
        let alert = UIAlertController(title: String(format: String(localized: "Switch to %@?"), device.displayName),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: viaStikDebug ? String(localized: "Switch System") : String(localized: "Close App"),
                                      style: .destructive) { [weak self] _ in
            self?.relaunch(into: device, viaStikDebug: viaStikDebug)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    /// Switching processes: note the device to boot; if QEMU is running, let it exit normally first (flushing to disk), then go to StikDebug (or just exit and wait for the user to reopen the app).
    private func relaunch(into device: DeviceProfile, viaStikDebug: Bool) {
        exiting = true
        do {
            try PendingBoot(device: device.id, wantJIT: viaStikDebug).save()
        } catch {
            exiting = false
            return alert(String(localized: "Something Went Wrong"), "\(error)")
        }
        emulator?.event("relaunch device=\(device.id) stikdebug=\(viaStikDebug)")
        stopQEMU { [weak self] in
            guard let self else { return }
            guard viaStikDebug else { exit(0) }
            if JIT.fake != nil {
                // Simulator: pretend StikDebug got the request. The host relaunches the app with -fakejit on, which stands in for the new process StikDebug would launch
                exit(0)
            }
            // StikDebug launches this app without killing the existing process, so exit as soon as the URL is handed over
            UIApplication.shared.open(StikDebug.url) { ok in
                if ok { exit(0) }
                PendingBoot.clear()
                self.exiting = false
                self.alert(String(localized: "Couldn't Open StikDebug"),
                           String(localized: "Make sure StikDebug is installed, then reopen this app and try again."))
            }
        }
    }

    /// Lets QEMU exit the normal way (qmp quit, block devices flushed to disk), waiting at most 2 seconds
    private func stopQEMU(_ then: @escaping () -> Void) {
        guard let emulator, emulator.engineStarted, !emulator.stopped else { return then() }
        var done = false
        let finish = { if !done { done = true; then() } }
        emulator.quitEngine(then: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    private func noJITAfterStikDebug(_ device: DeviceProfile) {
        let alert = UIAlertController(
            title: String(localized: "JIT Not Enabled"),
            message: String(localized: "StikDebug didn't turn on JIT for this app. Make sure LocalDevVPN is on and a pairing file is imported in StikDebug, then try again."),
            preferredStyle: .alert)
        if StikDebug.installed {
            alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak self] _ in
                self?.relaunch(into: device, viaStikDebug: true)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Boot with Interpreter (Slow)"), style: .default) { [weak self] _ in
            self?.boot(device.id, backend: .interp, test: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func askInterpreter(for device: DeviceProfile, title: String, message: String) {
        var text = message + "\n"
        text += device.majorVersion >= 7
            ? String(localized: "You can also boot with the interpreter, but iOS 7 is barely usable that way.")
            : String(localized: "You can also boot with the interpreter, but it's much slower: about 1 minute to the lock screen for iPhone OS 3 and about 2 minutes for iOS 6, and it feels sluggish.")
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Boot with Interpreter (Slow)"), style: .default) { [weak self] _ in
            self?.boot(device.id, backend: .interp, test: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "How to Install StikDebug"), style: .default) { [weak self] _ in
            self?.showJITHelp()
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func showJITHelp() {
        alert(String(localized: "JIT and StikDebug"), String(localized: """
            JIT makes systems run 5 to 10 times faster. iPhone doesn't give sideloaded apps JIT directly; the open-source StikDebug provides it on the phone.
            One-time setup: sideload StikDebug, install LocalDevVPN from the App Store, and follow StikDebug's instructions to create a pairing file on a computer once and import it into StikDebug.
            Each time after that: open LocalDevVPN, come back to this app and tap a system. The app switches to StikDebug, which turns on JIT, then comes back and boots. StikDebug may ask you to confirm once; just confirm.
            """))
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    // MARK: Test entry point: back, resume, select in Documents/control/ (the file content is a device id)

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

    /// Every boot creates a run folder under Documents/logs/; only the latest 30 are kept
    private func pruneLogs() {
        let dir = documents.appendingPathComponent("logs", isDirectory: true)
        let runs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("20") }.sorted()
        for name in runs.dropLast(30) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
