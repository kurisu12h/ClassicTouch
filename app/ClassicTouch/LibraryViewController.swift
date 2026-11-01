// 首页：Documents/devices/ 下的系统按年份排成一张「年表」（设计稿见 docs/design/，方案 A）。每台一行：大号年份、机型、
// 系统版本、构建号、占用空间、线描机身；正在运行的那台（从模拟器画面「返回列表」回来时）年份变红、带「继续」。没导入的年份
// 是灰色的一行，还开不了的（iPhone OS 1、iOS 8 到 10）标「以后」。导入进度和结果在表头下面，JIT 的状态在最底下。怎么开机、要不要先去 StikDebug
// 由 RootViewController 决定。右上角齿轮进设置（SettingsViewController.swift）。行的样子在 LibraryCells.swift，颜色和字体在 Theme.swift。
// 界面文字都走 String Catalog（Localizable.xcstrings，源语言中文）。
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

struct CurrentSystem {
    let id: String
    let name: String
    /// QEMU 已经退出（或开机失败）
    let stopped: Bool
}

enum JITState {
    case ready, inUse, needStik, noStik
}

final class LibraryViewController: UITableViewController {
    private enum Row {
        case header
        case importActive, importCopying(String), importResult(ImportManager.Result)
        /// 正在运行的那台不在设备目录里了（少见），单独一行
        case strayCurrent(CurrentSystem)
        case empty
        /// showYear 为 false：同一年的第二台，不重复写年份
        case system(DeviceProfile, showYear: Bool)
        /// 没导入的大版本（连着的合成一行）；later 为 true 是还不能模拟的版本
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
        title = String(localized: "选择系统")
        navigationItem.backButtonTitle = String(localized: "年表")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.paper
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        // 设置里选的外观（跟随系统、浅色、深色），在第一次画出来之前就套上
        AppAppearance.apply()
        for (cell, id) in [(LibraryHeaderCell.self, "header"), (SystemCell.self, "system"), (GhostCell.self, "ghost"),
                           (MessageCell.self, "message"), (NoteCell.self, "note"), (JITCell.self, "jit")] as [(UITableViewCell.Type, String)] {
            tableView.register(cell, forCellReuseIdentifier: id)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 标题和导入按钮在表头里，不要系统的导航栏
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
    }

    #if DEBUG
    private var previewed = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 看运行画面新外观的入口（还没接进 EmulatorViewController）：启动参数 -uipreview <设备 id>
        let args = ProcessInfo.processInfo.arguments
        guard !previewed, let i = args.firstIndex(of: "-uipreview"), i + 1 < args.count else { return }
        previewed = true
        let device = try? DeviceProfile(base: documents.appendingPathComponent("devices/\(args[i + 1])", isDirectory: true))
        let preview = EmulatorChromePreviewController(profile: device, documents: documents)
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: false)
    }
    #endif

    /// 重新扫描设备；占用空间在后台算，算好再刷一次
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

        // 年表：大版本 1 到 10 依次排，没导入的连着几个合成一行；能开的（还没导入）和「以后」的分开
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
        // 版本号读不懂的放最后
        list += devices.filter { Era.year($0.majorVersion) == nil }.map { Row.system($0, showYear: true) }
        list += [.note, .jit]
        return list
    }

    // MARK: 表格

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
            if live { notes.append((String(localized: "● 运行中，已暂停"), Theme.accent)) }
            if isCurrent && !live { notes.append((String(localized: "已关机。点这里重新开机（App 会重启）"), Theme.mid)) }
            let year = showYear ? Era.year(device.majorVersion).map(String.init) ?? "—" : nil
            cell.configure(year: year, model: device.modelName, detail: detail, notes: notes, board: device.board, live: live)
            return cell

        case .missing(let majors, let later):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ghost", for: indexPath) as! GhostCell
            let names = Era.names(majors)
            cell.configure(years: Era.years(majors[0], majors[majors.count - 1]),
                           text: later ? names : names + " · " + String(localized: "还没导入"), later: later)
            return cell

        case .note:
            let cell = tableView.dequeueReusableCell(withIdentifier: "note", for: indexPath) as! NoteCell
            cell.configure(String(localized: "一次只能开一个系统，换系统时 App 会重新启动。"))
            return cell

        case .jit:
            let cell = tableView.dequeueReusableCell(withIdentifier: "jit", for: indexPath) as! JITCell
            switch jitState {
            case .ready:
                cell.configure(symbol: "bolt.fill", title: String(localized: "JIT 已开启"), detail: String(localized: "点系统直接开机。"))
            case .inUse:
                cell.configure(symbol: "bolt.fill", title: String(localized: "当前系统在用 JIT"),
                               detail: String(localized: "换系统时会再经 StikDebug 开一次。"))
            case .needStik:
                cell.configure(symbol: "bolt", title: String(localized: "JIT 还没开"),
                               detail: String(localized: "点系统后会跳到 StikDebug 开启，开好自动回来开机。要先打开 LocalDevVPN。"))
            case .noStik:
                cell.configure(symbol: "bolt.slash", title: String(localized: "没有 StikDebug"),
                               detail: String(localized: "只能用解释器开机，会很慢。点这里看怎么装。"))
            }
            return cell
        }
    }

    /// 表头下面那行：「按年份排 · 已导入 3 个 · 共 5.8 GB」
    private func summary() -> String {
        guard !devices.isEmpty else { return String(localized: "按年份排 · 还没有系统") }
        var text = String(format: String(localized: "按年份排 · 已导入 %d 个"), devices.count)
        let known = devices.compactMap { sizes[$0.id] }
        if known.count == devices.count {
            text += " · " + String(format: String(localized: "共 %@"), ImportManager.bytes(known.reduce(0, +)))
        }
        return text
    }

    private func fillMessage(_ cell: MessageCell, _ row: Row) {
        cell.selectionStyle = .none
        switch row {
        case .importActive:
            guard let active = imports.active else { break }
            let fraction = active.total > 0 ? Double(active.done) / Double(active.total) : 0
            cell.configure(symbol: "arrow.down.circle", title: String(format: String(localized: "正在导入 %@"), active.name),
                           detail: String(format: String(localized: "%.0f%%（%@ / %@）"), fraction * 100,
                                          ImportManager.bytes(Int64(active.done)), ImportManager.bytes(Int64(active.total))),
                           fraction: fraction)
        case .importCopying(let name):
            cell.configure(symbol: "ellipsis.circle", title: String(format: String(localized: "正在拷入 %@"), name),
                           detail: String(localized: "拷完会自动开始导入"))
        case .importResult(let result):
            cell.configure(symbol: result.ok ? "checkmark.circle" : "exclamationmark.triangle",
                           tint: result.ok ? Theme.ink : Theme.accent, title: result.text, detail: result.name)
        case .strayCurrent(let current):
            cell.selectionStyle = .default
            cell.configure(symbol: current.stopped ? "stop.circle" : "play.circle", tint: current.stopped ? Theme.mid : Theme.accent,
                           title: current.name,
                           detail: current.stopped
                               ? String(localized: "已关机。再开一次要重新打开 App，点下面的系统即可。")
                               : String(localized: "已暂停，点这里继续"))
        case .empty:
            cell.selectionStyle = .default
            cell.configure(symbol: "tray", title: String(localized: "还没有系统"),
                           detail: String(localized: "把 .ctpack 设备包拷进本 App 的文稿，App 会自动导入。点这里看怎么拷。"))
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

    /// 设置页也用
    static func importHelpAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "怎么导入系统"),
            message: String(localized: """
                把 .ctpack 设备包放进本 App 的文稿，App 会自动导入，导入完删掉包。
                · Mac：插线后在 Finder 里选中这台 iPhone，打开「文件」，把包拖到本 App 上。
                · 手机上：在「文件」App 里打开「我的 iPhone」中本 App 的文件夹，把包移进 import 文件夹（或直接放进来）。
                导入时留在这一页可以看进度。
                """),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        return alert
    }

    private func showLaterHelp(_ majors: [Int]) {
        let old = majors.contains(1)
        let alert = UIAlertController(
            title: Era.names(majors),
            message: old
                ? String(localized: "iPhone OS 1 只能跑在初代 iPhone 和 iPod touch（第 1 代）上，这两种机型本 App 还没支持，所以暂时开不了。以后支持了，导入后会出现在这里。")
                : String(localized: "这几个版本要 A5、A6 芯片的机型（iPhone 4S、iPhone 5 等），现在还没有能跑它们的模拟器，所以暂时开不了。以后支持了，导入后会出现在这里。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        present(alert, animated: true)
    }
}
