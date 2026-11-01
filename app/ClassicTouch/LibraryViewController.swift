// 首页：Documents/devices/ 下的系统列表（机型 · 系统版本、占用空间），点一个就开机；上面是正在运行的那台（从模拟器画面
// 「返回列表」回来时），中间是导入进度和结果，最下面是 JIT 的状态。怎么开机、要不要先去 StikDebug 由 RootViewController 决定。
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
    private enum Section { case current, imports, systems, jit }

    private let documents: URL
    private let imports: ImportManager
    var current: CurrentSystem? { didSet { reload() } }
    var jitState: JITState = .needStik { didSet { reload() } }
    var onSelect: ((DeviceProfile) -> Void)?
    var onResume: (() -> Void)?
    var onJITHelp: (() -> Void)?

    private var devices: [DeviceProfile] = []
    private var sizes: [String: Int64] = [:]
    private var sections: [Section] = []

    init(documents: URL, imports: ImportManager) {
        self.documents = documents
        self.imports = imports
        super.init(style: .insetGrouped)
        title = String(localized: "选择系统")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.down"), primaryAction: UIAction { [weak self] _ in self?.showImportHelp() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "怎么导入")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// 重新扫描设备；占用空间在后台算，算好再刷一次
    func reload() {
        devices = DeviceProfile.all(in: documents)
        var list: [Section] = []
        if current != nil { list.append(.current) }
        if imports.active != nil || !imports.copying.isEmpty || !imports.results.isEmpty { list.append(.imports) }
        list += [.systems, .jit]
        sections = list
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

    // MARK: 表格

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    private var importRows: Int { (imports.active == nil ? 0 : 1) + imports.copying.count + imports.results.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .current: return 1
        case .imports: return importRows
        case .systems: return max(devices.count, 1)
        case .jit: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .current: return String(localized: "正在运行")
        case .imports: return String(localized: "导入")
        case .systems: return String(localized: "系统")
        case .jit: return "JIT"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .systems where !devices.isEmpty: return String(localized: "一次只能开一个系统，换系统时 App 会重新启动。")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var c = UIListContentConfiguration.subtitleCell()
        c.secondaryTextProperties.color = .secondaryLabel
        c.secondaryTextProperties.numberOfLines = 0
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        switch sections[indexPath.section] {
        case .current:
            guard let current else { break }
            c.text = current.name
            c.secondaryText = current.stopped
                ? String(localized: "已关机。再开一次要重新打开 App，点下面的系统即可。")
                : String(localized: "已暂停，点这里继续")
            c.image = UIImage(systemName: current.stopped ? "stop.circle" : "play.circle.fill")
            cell.accessoryType = .disclosureIndicator
        case .imports:
            fillImport(&c, cell: cell, row: indexPath.row)
        case .systems:
            if devices.isEmpty {
                c.text = String(localized: "还没有系统")
                c.secondaryText = String(localized: "把 .ctpack 设备包拷进本 App 的文稿，App 会自动导入。点这里看怎么拷。")
                c.image = UIImage(systemName: "tray")
                break
            }
            let device = devices[indexPath.row]
            c.text = device.displayName
            var detail = device.build
            if let size = sizes[device.id] {
                detail += " · " + String(format: String(localized: "占用 %@"), ImportManager.bytes(size))
            }
            let text = NSMutableAttributedString(string: detail, attributes: [.foregroundColor: UIColor.secondaryLabel])
            if let note = device.experimentalNote {
                text.append(NSAttributedString(string: "\n" + note, attributes: [.foregroundColor: UIColor.systemOrange]))
            }
            c.secondaryAttributedText = text
            c.image = UIImage(systemName: device.info.width > device.info.height ? "ipad.landscape" : "iphone")
            if current?.id == device.id && current?.stopped == false {
                let label = UILabel()
                label.text = String(localized: "运行中")
                label.textColor = .systemGreen
                label.font = .preferredFont(forTextStyle: .footnote)
                label.sizeToFit()
                cell.accessoryView = label
            } else {
                cell.accessoryType = .disclosureIndicator
            }
        case .jit:
            switch jitState {
            case .ready:
                c.text = String(localized: "已开启")
                c.secondaryText = String(localized: "点系统直接开机。")
                c.image = UIImage(systemName: "bolt.fill")
            case .inUse:
                c.text = String(localized: "当前系统在用 JIT")
                c.secondaryText = String(localized: "换系统时会再经 StikDebug 开一次。")
                c.image = UIImage(systemName: "bolt.fill")
            case .needStik:
                c.text = String(localized: "还没开")
                c.secondaryText = String(localized: "点系统后会跳到 StikDebug 开 JIT，开好后自动回来开机。要先打开 LocalDevVPN。")
                c.image = UIImage(systemName: "bolt")
            case .noStik:
                c.text = String(localized: "没有 StikDebug")
                c.secondaryText = String(localized: "只能用解释器开机，会很慢。点这里看怎么装。")
                c.image = UIImage(systemName: "bolt.slash")
            }
            c.imageProperties.tintColor = jitState == .ready || jitState == .inUse ? .systemYellow : .secondaryLabel
        }
        cell.contentConfiguration = c
        return cell
    }

    private func fillImport(_ c: inout UIListContentConfiguration, cell: UITableViewCell, row: Int) {
        var row = row
        cell.selectionStyle = .none
        if let active = imports.active {
            if row == 0 {
                let fraction = active.total > 0 ? Double(active.done) / Double(active.total) : 0
                c.text = String(format: String(localized: "正在导入 %@"), active.name)
                c.secondaryText = String(format: String(localized: "%.0f%%（%@ / %@）"), fraction * 100,
                                         ImportManager.bytes(Int64(active.done)), ImportManager.bytes(Int64(active.total)))
                c.image = UIImage(systemName: "arrow.down.circle")
                let bar = UIProgressView(progressViewStyle: .default)
                bar.frame.size.width = 80
                bar.progress = Float(fraction)
                cell.accessoryView = bar
                return
            }
            row -= 1
        }
        if row < imports.copying.count {
            c.text = String(format: String(localized: "正在拷入 %@"), imports.copying[row])
            c.secondaryText = String(localized: "拷完会自动开始导入")
            c.image = UIImage(systemName: "ellipsis.circle")
            return
        }
        let result = imports.results[row - imports.copying.count]
        c.text = result.text
        c.secondaryText = result.name
        c.image = UIImage(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        c.imageProperties.tintColor = result.ok ? .systemGreen : .systemOrange
        c.textProperties.numberOfLines = 0
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .current: onResume?()
        case .imports: break
        case .systems:
            if devices.isEmpty { showImportHelp() } else { onSelect?(devices[indexPath.row]) }
        case .jit: onJITHelp?()
        }
    }

    private func showImportHelp() {
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
        present(alert, animated: true)
    }
}
