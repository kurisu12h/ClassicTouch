// The home page: the systems under Documents/devices/ sorted by year into a "timeline" (design in docs/design/,
// option A). One row per device: a large year, model, system version, build, size and a line drawing of the device;
// the running one (when coming back from the emulator screen with "back to the list") has a red year and "Resume". Years
// not imported are a gray row, and those that cannot run yet (iPhone OS 1, iOS 8 to 10) are marked "Later". Import
// progress and results are below the header, JIT status at the very bottom. RootViewController decides how to boot and
// whether to go to StikDebug first. The gear at the top right opens settings (SettingsViewController.swift). Row looks
// are in LibraryCells.swift, colors and fonts in Theme.swift.
// All UI text goes through the String Catalog (Localizable.xcstrings: English source, Simplified Chinese translation).
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

struct CurrentSystem {
    let id: String
    let name: String
    /// QEMU has exited (or the boot failed)
    let stopped: Bool
}

enum JITState {
    case ready, inUse, needStik, noStik
}

final class LibraryViewController: UITableViewController {
    private enum Row {
        case header
        case importActive, importCopying(String), importResult(ImportManager.Result)
        /// The running device is no longer in the devices folder (rare), so it gets its own row
        case strayCurrent(CurrentSystem)
        case empty
        /// showYear is false for the second device of the same year, so the year is not repeated
        case system(DeviceProfile, showYear: Bool)
        /// Major versions not imported (consecutive ones merged into one row); later is true for versions that cannot be emulated yet
        case missing([Int], later: Bool)
        case note
        case jit
    }

    private let documents: URL
    private let imports: ImportManager
    var current: CurrentSystem? { didSet { reload() } }
    var jitState: JITState = .needStik { didSet { reload() } }
    var onSelect: ((DeviceProfile) -> Void)?
    var onResume: (() -> Void)?
    var onJITHelp: (() -> Void)?

    private var devices: [DeviceProfile] = []
    private var sizes: [String: Int64] = [:]
    private var rows: [Row] = []

    init(documents: URL, imports: ImportManager) {
        self.documents = documents
        self.imports = imports
        super.init(style: .plain)
        title = String(localized: "Systems")
        navigationItem.backButtonTitle = String(localized: "Timeline")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.paper
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        // The appearance chosen in settings (system, light, dark) is applied before the first draw
        AppAppearance.apply()
        for (cell, id) in [(LibraryHeaderCell.self, "header"), (SystemCell.self, "system"), (GhostCell.self, "ghost"),
                           (MessageCell.self, "message"), (NoteCell.self, "note"), (JITCell.self, "jit")] as [(UITableViewCell.Type, String)] {
            tableView.register(cell, forCellReuseIdentifier: id)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The title and import button are in the header, so no system navigation bar
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
    }

    #if DEBUG
    private var previewed = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Entry point for viewing the new look of the run screen (not yet wired into EmulatorViewController): launch argument -uipreview <device id>
        let args = ProcessInfo.processInfo.arguments
        guard !previewed, let i = args.firstIndex(of: "-uipreview"), i + 1 < args.count else { return }
        previewed = true
        let device = try? DeviceProfile(base: documents.appendingPathComponent("devices/\(args[i + 1])", isDirectory: true))
        let preview = EmulatorChromePreviewController(profile: device, documents: documents)
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: false)
    }
    #endif

    /// Rescans devices; sizes are computed in the background, then the list refreshes again
    func reload() {
        devices = DeviceProfile.all(in: documents)
        rows = buildRows()
        guard isViewLoaded else { return }
        tableView.reloadData()
        let missing = devices.filter { sizes[$0.id] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0.allocatedSize()) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.sizes.merge(found) { $1 }
                self.tableView.reloadData()
            }
        }
    }

    private func buildRows() -> [Row] {
        var list: [Row] = [.header]
        if imports.active != nil { list.append(.importActive) }
        list += imports.copying.map { Row.importCopying($0) }
        list += imports.results.map { Row.importResult($0) }
        if let current, !devices.contains(where: { $0.id == current.id }) { list.append(.strayCurrent(current)) }
        if devices.isEmpty { list.append(.empty) }

        // Timeline: major versions 1 to 10 in order, consecutive missing ones merged into one row; runnable ones (not imported) and "Later" ones kept apart
        var gap: [Int] = []
        var gapLater = false
        let flush = { if !gap.isEmpty { list.append(.missing(gap, later: gapLater)); gap = [] } }
        for major in Era.majors {
            let here = devices.filter { $0.majorVersion == major }
            if here.isEmpty {
                let later = !Era.runnable.contains(major)
                if later != gapLater { flush() }
                gapLater = later
                gap.append(major)
                continue
            }
            flush()
            list += here.enumerated().map { Row.system($1, showYear: $0 == 0) }
        }
        flush()
        // Devices with an unreadable version go last
        list += devices.filter { Era.year($0.majorVersion) == nil }.map { Row.system($0, showYear: true) }
        list += [.note, .jit]
        return list
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .header:
            let cell = tableView.dequeueReusableCell(withIdentifier: "header", for: indexPath) as! LibraryHeaderCell
            cell.configure(range: "\(Era.year(Era.majors.lowerBound) ?? 0)–\(Era.year(Era.majors.upperBound) ?? 0)", meta: summary())
            cell.importButton.removeTarget(nil, action: nil, for: .allEvents)
            cell.importButton.addTarget(self, action: #selector(showImportHelp), for: .touchUpInside)
            cell.settingsButton.removeTarget(nil, action: nil, for: .allEvents)
            cell.settingsButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            return cell

        case .importActive, .importCopying, .importResult, .strayCurrent, .empty:
            let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! MessageCell
            fillMessage(cell, rows[indexPath.row])
            return cell

        case .system(let device, let showYear):
            let cell = tableView.dequeueReusableCell(withIdentifier: "system", for: indexPath) as! SystemCell
            var detail = device.systemName + " · " + device.build
            if let size = sizes[device.id] { detail += " · " + ImportManager.bytes(size) }
            var notes: [(String, UIColor)] = []
            if let note = device.experimentalNote { notes.append((note, Theme.accent)) }
            let isCurrent = current?.id == device.id
            let live = isCurrent && current?.stopped == false
            if live { notes.append((String(localized: "● Running, paused"), Theme.accent)) }
            if isCurrent && !live { notes.append((String(localized: "Shut down. Tap here to boot again (the app will restart)"), Theme.mid)) }
            let year = showYear ? Era.year(device.majorVersion).map(String.init) ?? "—" : nil
            cell.configure(year: year, model: device.modelName, detail: detail, notes: notes, board: device.board, live: live)
            return cell

        case .missing(let majors, let later):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ghost", for: indexPath) as! GhostCell
            let names = Era.names(majors)
            cell.configure(years: Era.years(majors[0], majors[majors.count - 1]),
                           text: later ? names : names + " · " + String(localized: "Not imported"), later: later)
            return cell

        case .note:
            let cell = tableView.dequeueReusableCell(withIdentifier: "note", for: indexPath) as! NoteCell
            cell.configure(String(localized: "Only one system can run at a time. Switching systems restarts the app."))
            return cell

        case .jit:
            let cell = tableView.dequeueReusableCell(withIdentifier: "jit", for: indexPath) as! JITCell
            switch jitState {
            case .ready:
                cell.configure(symbol: "bolt.fill", title: String(localized: "JIT is on"), detail: String(localized: "Tap a system to boot it."))
            case .inUse:
                cell.configure(symbol: "bolt.fill", title: String(localized: "The current system is using JIT"),
                               detail: String(localized: "Switching systems goes through StikDebug again."))
            case .needStik:
                cell.configure(symbol: "bolt", title: String(localized: "JIT is off"),
                               detail: String(localized: "Tapping a system switches to StikDebug to turn it on, then comes back and boots. Open LocalDevVPN first."))
            case .noStik:
                cell.configure(symbol: "bolt.slash", title: String(localized: "No StikDebug"),
                               detail: String(localized: "Systems can only boot with the interpreter, which is very slow. Tap here to see how to install it."))
            }
            return cell
        }
    }

    /// The line under the header: "By year · 3 imported · 5.8 GB total"
    private func summary() -> String {
        guard !devices.isEmpty else { return String(localized: "By year · No systems yet") }
        var text = String(format: String(localized: "By year · %d imported"), devices.count)
        let known = devices.compactMap { sizes[$0.id] }
        if known.count == devices.count {
            text += " · " + String(format: String(localized: "%@ total"), ImportManager.bytes(known.reduce(0, +)))
        }
        return text
    }

    private func fillMessage(_ cell: MessageCell, _ row: Row) {
        cell.selectionStyle = .none
        switch row {
        case .importActive:
            guard let active = imports.active else { break }
            let fraction = active.total > 0 ? Double(active.done) / Double(active.total) : 0
            cell.configure(symbol: "arrow.down.circle", title: String(format: String(localized: "Importing %@"), active.name),
                           detail: String(format: String(localized: "%.0f%% (%@ of %@)"), fraction * 100,
                                          ImportManager.bytes(Int64(active.done)), ImportManager.bytes(Int64(active.total))),
                           fraction: fraction)
        case .importCopying(let name):
            cell.configure(symbol: "ellipsis.circle", title: String(format: String(localized: "Copying %@"), name),
                           detail: String(localized: "Import starts automatically when copying finishes"))
        case .importResult(let result):
            cell.configure(symbol: result.ok ? "checkmark.circle" : "exclamationmark.triangle",
                           tint: result.ok ? Theme.ink : Theme.accent, title: result.text, detail: result.name)
        case .strayCurrent(let current):
            cell.selectionStyle = .default
            cell.configure(symbol: current.stopped ? "stop.circle" : "play.circle", tint: current.stopped ? Theme.mid : Theme.accent,
                           title: current.name,
                           detail: current.stopped
                               ? String(localized: "Shut down. To boot again, reopen the app and tap a system below.")
                               : String(localized: "Paused. Tap here to resume"))
        case .empty:
            cell.selectionStyle = .default
            cell.configure(symbol: "tray", title: String(localized: "No Systems Yet"),
                           detail: String(localized: "Copy a .ctpack device pack into this app's Documents and the app will import it. Tap here to see how."))
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .system(let device, _):
            if current?.id == device.id && current?.stopped == false { onResume?() } else { onSelect?(device) }
        case .strayCurrent(let current):
            if !current.stopped { onResume?() }
        case .empty: showImportHelp()
        case .missing(let majors, let later): later ? showLaterHelp(majors) : showImportHelp()
        case .jit: onJITHelp?()
        default: break
        }
    }

    @objc private func showSettings() {
        let settings = SettingsViewController(documents: documents, current: current)
        settings.onJITHelp = onJITHelp
        settings.onChange = { [weak self] in self?.reload() }
        navigationController?.pushViewController(settings, animated: true)
    }

    @objc private func showImportHelp() {
        present(Self.importHelpAlert(), animated: true)
    }

    /// Also used by the settings page
    static func importHelpAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "How to Import Systems"),
            message: String(localized: """
                Put a .ctpack device pack in this app's Documents. The app imports it automatically and deletes the pack when done.
                · Mac: connect the iPhone with a cable, select it in Finder, open Files, and drag the pack onto this app.
                · On the phone: in the Files app, open this app's folder under On My iPhone and move the pack into the import folder (or straight into the app's folder).
                Stay on this page to watch the progress.
                """),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        return alert
    }

    private func showLaterHelp(_ majors: [Int]) {
        let old = majors.contains(1)
        let alert = UIAlertController(
            title: Era.names(majors),
            message: old
                ? String(localized: "iPhone OS 1 runs only on the original iPhone and the iPod touch (1st generation), which this app doesn't support yet, so it can't run for now. Once they're supported, imported systems will appear here.")
                : String(localized: "iOS 8 needs a model with an A5 or A6 chip (iPod touch 5th generation, iPhone 5), and devices for this version aren't ready yet, so it can't run for now. Once it's supported, imported systems will appear here."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
