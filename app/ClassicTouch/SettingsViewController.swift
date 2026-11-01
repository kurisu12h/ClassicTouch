// 设置、关于和许可证页，「年表」风格（Theme.swift）。从首页右上角的齿轮进来。
//   设置：外观（跟随系统、浅色、深色）、系统和存储（每台占用，可以删除）、JIT 说明、关于、请我喝杯咖啡
//   关于：版本、简介、源代码和许可证、致谢、声明
//   许可证：App 里带的 ThirdPartyLicenses.txt（本 App 的 GPL 和 QEMU 静态链接的各个库的许可证原文）
// SPDX-License-Identifier: GPL-2.0-or-later

import SafariServices
import UIKit

/// 外面的链接
enum Links {
    static let source = URL(string: "https://github.com/kurisu12h/ClassicTouch")!
    static let qemuIOS = URL(string: "https://github.com/samhenrigold/qemu-ios")!
    static let lightTouch = URL(string: "https://github.com/samhenrigold/LightTouchMac")!
    static let qemu = URL(string: "https://www.qemu.org")!
    static let stikDebug = URL(string: "https://github.com/StikDebug/StikDebug")!
    /// 「请我喝杯咖啡」的捐赠页。还没定用哪个平台；空着时点按钮会说明还没设置
    static let coffee: URL? = nil
}

/// 外观：跟随系统、浅色、深色，存在 UserDefaults，改窗口的 overrideUserInterfaceStyle。模拟器画面一直是黑底，不受影响
enum AppAppearance: Int, CaseIterable {
    case system, light, dark

    private static let key = "appearance"

    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            apply()
        }
    }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = current.style }
        }
    }
}

// MARK: - 页面的公共部分

/// 设置、关于共用：一张没有分隔线的表，行的种类见 Item.Kind，点一行执行它的 action
class PageViewController: UITableViewController {
    struct Item {
        enum Kind {
            /// 大标题，下面一道粗黑线
            case title(String)
            /// 关于页的头：图标、App 名、版本
            case about
            case section(String)
            /// 标题、右边的值、要不要箭头
            case row(String, String?, chevron: Bool)
            /// 右边是一个弹出菜单
            case menu(String, String, UIMenu)
            case paragraph(String)
            case coffee
        }

        let kind: Kind
        var action: (() -> Void)?
    }

    var items: [Item] = [] {
        didSet { if isViewLoaded { tableView.reloadData() } }
    }

    init() {
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.paper
        tableView.separatorStyle = .none
        for (cell, id) in [(PageTitleCell.self, "title"), (AboutHeaderCell.self, "about"), (SectionCell.self, "section"),
                           (RowCell.self, "row"), (ParagraphCell.self, "paragraph"), (CoffeeCell.self, "coffee")]
            as [(UITableViewCell.Type, String)] {
            tableView.register(cell, forCellReuseIdentifier: id)
        }
        // 导航栏只留返回键，和纸一个颜色、没有分隔线；标题在表头里
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = Theme.paper
        bar.shadowColor = .clear
        navigationItem.standardAppearance = bar
        navigationItem.scrollEdgeAppearance = bar
        navigationItem.compactAppearance = bar
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.navigationBar.tintColor = Theme.ink
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        switch item.kind {
        case .title(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "title", for: indexPath) as! PageTitleCell
            cell.configure(text)
            return cell
        case .about:
            return tableView.dequeueReusableCell(withIdentifier: "about", for: indexPath)
        case .section(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "section", for: indexPath) as! SectionCell
            cell.configure(text)
            return cell
        case .row(let title, let value, let chevron):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! RowCell
            cell.configure(title: title, value: value, chevron: chevron, menu: nil)
            cell.selectionStyle = item.action == nil ? .none : .default
            return cell
        case .menu(let title, let value, let menu):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! RowCell
            cell.configure(title: title, value: value, chevron: false, menu: menu)
            cell.selectionStyle = .none
            return cell
        case .paragraph(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "paragraph", for: indexPath) as! ParagraphCell
            cell.configure(text)
            return cell
        case .coffee:
            return tableView.dequeueReusableCell(withIdentifier: "coffee", for: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        items[indexPath.row].action?()
    }

    func open(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = Theme.ink
        present(safari, animated: true)
    }

    func openCoffee() {
        guard let url = Links.coffee else {
            return alert(String(localized: "捐赠页还没设置好"), String(localized: "开发者还没填捐赠页的地址，过几个版本再来看看。谢谢你愿意支持！"))
        }
        open(url)
    }

    func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "好"), style: .default))
        present(alert, animated: true)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(format: String(localized: "版本 %@（%@）"), short, build)
    }
}

// MARK: - 设置

final class SettingsViewController: PageViewController {
    private let documents: URL
    private let current: CurrentSystem?
    var onJITHelp: (() -> Void)?
    /// 删了系统，首页要重新扫一遍
    var onChange: (() -> Void)?

    private var devices: [DeviceProfile] = []
    private var sizes: [String: Int64] = [:]

    init(documents: URL, current: CurrentSystem?) {
        self.documents = documents
        self.current = current
        super.init()
        title = String(localized: "设置")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 大标题已经写了「设置」，导航栏中间不再重复（title 还留着，下一页的返回键要用）
        navigationItem.titleView = UIView()
        reload()
    }

    private func reload() {
        devices = DeviceProfile.all(in: documents)
        build()
        let missing = devices.filter { sizes[$0.id] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0.allocatedSize()) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.sizes.merge(found) { $1 }
                self.build()
            }
        }
    }

    private func build() {
        var list: [Item] = [Item(kind: .title(String(localized: "设置")))]

        list.append(Item(kind: .section(String(localized: "显示"))))
        let choices = AppAppearance.allCases.map { choice in
            UIAction(title: choice.title, state: choice == AppAppearance.current ? .on : .off) { [weak self] _ in
                AppAppearance.current = choice
                self?.build()
            }
        }
        list.append(Item(kind: .menu(String(localized: "外观"), AppAppearance.current.title, UIMenu(children: choices))))

        list.append(Item(kind: .section(String(localized: "系统和存储"))))
        for device in devices {
            let running = current?.id == device.id && current?.stopped == false
            let value = running ? String(localized: "运行中") : sizes[device.id].map { ImportManager.bytes($0) } ?? "…"
            list.append(Item(kind: .row(device.displayName, value, chevron: false)) { [weak self] in self?.confirmDelete(device) })
        }
        list.append(Item(kind: .row(String(localized: "怎么导入系统"), nil, chevron: true)) { [weak self] in
            self?.present(LibraryViewController.importHelpAlert(), animated: true)
        })
        var note = devices.isEmpty ? String(localized: "还没有系统。") : String(localized: "点一台可以删除它。删除会删掉这台的全部数据，不能恢复。")
        if let free = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            note += String(format: String(localized: "手机还剩 %@ 可用。"), ImportManager.bytes(free))
        }
        list.append(Item(kind: .paragraph(note)))

        list.append(Item(kind: .section("JIT")))
        list.append(Item(kind: .row(String(localized: "JIT 和 StikDebug"), nil, chevron: true)) { [weak self] in self?.onJITHelp?() })

        list.append(Item(kind: .section(String(localized: "关于"))))
        list.append(Item(kind: .row(String(localized: "关于 Classic Touch"), Self.version, chevron: true)) { [weak self] in
            self?.navigationController?.pushViewController(AboutViewController(), animated: true)
        })
        list.append(Item(kind: .coffee) { [weak self] in self?.openCoffee() })
        items = list
    }

    private func confirmDelete(_ device: DeviceProfile) {
        if current?.id == device.id && current?.stopped == false {
            return alert(String(format: String(localized: "%@ 正在运行"), device.displayName),
                         String(localized: "正在运行的系统不能删除。先在年表里换一台别的，或者把 App 从多任务里划掉再打开。"))
        }
        let message = sizes[device.id].map {
            String(format: String(localized: "这台的系统和里面的全部数据（%@）都会删掉，不能恢复。要再用得重新导入。"), ImportManager.bytes($0))
        } ?? String(localized: "这台的系统和里面的全部数据都会删掉，不能恢复。要再用得重新导入。")
        let sheet = UIAlertController(title: String(format: String(localized: "删除 %@？"), device.displayName),
                                      message: message, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "删除"), style: .destructive) { [weak self] _ in self?.delete(device) })
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        present(sheet, animated: true)
    }

    private func delete(_ device: DeviceProfile) {
        // 只删 Documents/devices/ 下面那一层的目录
        let devicesDir = documents.appendingPathComponent("devices", isDirectory: true).standardizedFileURL
        let target = device.base.standardizedFileURL
        guard target.deletingLastPathComponent().path == devicesDir.path, !device.id.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = Result { try Self.removeTree(target) }.failure
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.alert(String(localized: "删除失败"), error.localizedDescription) }
                self.sizes[device.id] = nil
                self.reload()
                self.onChange?()
            }
        }
    }
}

extension SettingsViewController {
    /// 设备本体里有只读目录（FirmwareKit 做的 nand/ 是 r-x），直接 removeItem 会删到一半报没权限。先把目录都改成可写再删
    static func removeTree(_ url: URL) throws {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try fm.removeItem(at: url)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - 关于

final class AboutViewController: PageViewController {
    override init() {
        super.init()
        title = String(localized: "关于")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        items = [
            Item(kind: .about),
            Item(kind: .paragraph(String(localized: "在 iPhone 上开机运行当年的原版 iPhone OS 和 iOS，给老玩家一个回味经典的入口。目标是 iPhone OS 1 到 iOS 10；现在能开 iPhone OS 2 到 iOS 7 的部分机型，其余的以后支持。"))),

            Item(kind: .section(String(localized: "开源"))),
            Item(kind: .row(String(localized: "源代码"), "GitHub", chevron: true)) { [weak self] in self?.open(Links.source) },
            Item(kind: .row(String(localized: "许可证"), "GPL-2.0-or-later", chevron: true)) { [weak self] in self?.showLicenses() },
            Item(kind: .paragraph(String(localized: "Classic Touch 是自由软件，按 GNU 通用公共许可证第 2 版或更新版本发布。可以自由使用、修改和再分发，但不提供任何担保。"))),

            Item(kind: .section(String(localized: "致谢"))),
            Item(kind: .row("qemu-ios", "GPL-2.0", chevron: true)) { [weak self] in self?.open(Links.qemuIOS) },
            Item(kind: .row("QEMU", "GPL-2.0", chevron: true)) { [weak self] in self?.open(Links.qemu) },
            Item(kind: .row(String(localized: "Light Touch（FirmwareKit）"), "GPL-2.0+", chevron: true)) { [weak self] in self?.open(Links.lightTouch) },
            Item(kind: .row("StikDebug", "AGPL-3.0", chevron: true)) { [weak self] in self?.open(Links.stikDebug) },
            Item(kind: .row(String(localized: "依赖库的许可证"), nil, chevron: true)) { [weak self] in self?.showLicenses() },
            Item(kind: .paragraph(String(localized: "模拟器核心是 Sam Henri Gold 的 qemu-ios，设备制作来自他的 Light Touch；JIT 靠 StikDebug（单独安装）。QEMU 里静态链接了 GLib、PCRE2、proxy-libintl、pixman、libslirp、OpenSSL、Nettle、libffi。"))),

            Item(kind: .section(String(localized: "声明"))),
            Item(kind: .paragraph(String(localized: "本项目和 Apple 没有关系。iPhone、iPod touch、iPad、iOS 是 Apple Inc. 的商标，这里只用来说明能模拟哪些机型和系统。App 不附带任何苹果的系统文件。"))),

            Item(kind: .coffee) { [weak self] in self?.openCoffee() },
        ]
    }

    private func showLicenses() {
        navigationController?.pushViewController(LicenseTextViewController(), animated: true)
    }
}

// MARK: - 许可证原文

final class LicenseTextViewController: UIViewController {
    private let text = UITextView()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "许可证")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        text.backgroundColor = Theme.paper
        text.textColor = Theme.ink
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        text.textContainerInset = UIEdgeInsets(top: 12, left: Theme.margin - 5, bottom: 32, right: Theme.margin - 5)
        text.text = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Self.reflow) ?? String(localized: "没找到许可证文件。")
        text.frame = view.bounds
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(text)
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = Theme.paper
        bar.shadowColor = Theme.rule
        navigationItem.standardAppearance = bar
        navigationItem.scrollEdgeAppearance = bar
    }

    /// 许可证原文按 80 列左右硬换行，手机上会再折一次，读起来很碎。把段落里的硬换行接起来：
    /// 上一行够长、下一行不是空行也不以空白开头（缩进的条目、标题保持原样）
    static func reflow(_ text: String) -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let last = out.last, last.count >= 50, !line.isEmpty, !(line.first?.isWhitespace ?? true),
               !last.hasPrefix("==="), !line.hasPrefix("===") {
                out[out.count - 1] = last + " " + line
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - 行

final class PageTitleCell: PaperCell {
    private let title = Theme.label(Theme.text(31, .bold, .largeTitle), Theme.ink, lines: 0)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        title.accessibilityTraits = .header
        let bar = UIView()
        bar.backgroundColor = Theme.ink
        bar.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, bar] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            bar.heightAnchor.constraint(equalToConstant: 3),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) { title.text = text }
}

/// 关于页的头：小图标、App 名、版本
final class AboutHeaderCell: PaperCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        let icon = IconView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = Theme.label(Theme.text(28, .bold, .largeTitle), Theme.ink)
        name.text = "Classic Touch"
        name.accessibilityTraits = .header
        let version = Theme.label(Theme.text(13.5, .regular, .footnote), Theme.mid)
        version.text = PageViewController.version
        let bar = UIView()
        bar.backgroundColor = Theme.ink
        bar.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, name, version, bar] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            name.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),
            name.topAnchor.constraint(equalTo: icon.topAnchor, constant: 6),
            version.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            version.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            bar.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            bar.heightAnchor.constraint(equalToConstant: 3),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 小标题（「显示」「系统和存储」…）
final class SectionCell: PaperCell {
    private let text = Theme.label(Theme.text(13, .semibold, .footnote), Theme.mid)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        text.accessibilityTraits = .header
        contentView.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.margin),
            text.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.margin),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ title: String) { text.text = title }
}

/// 一行：左边标题，右边值和箭头，或者一个弹出菜单
final class RowCell: PaperCell {
    private let title = Theme.label(Theme.text(16), Theme.ink, lines: 0)
    private let value = Theme.label(Theme.text(15), Theme.mid)
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private let menuButton = UIButton(type: .system)
    private let right = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        chevron.tintColor = Theme.faint
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.tintColor = Theme.mid
        menuButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [value, menuButton, chevron] { right.addArrangedSubview(v) }
        right.spacing = 8
        right.alignment = .center
        right.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, right] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 15),
            title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -15),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            right.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, value detail: String?, chevron arrow: Bool, menu: UIMenu?) {
        title.text = text
        value.text = detail
        // 右边这一组只是竖直居中、不决定行高，所以切换 isHidden 没有 SystemCell 那个量行高的问题
        value.isHidden = detail == nil || menu != nil
        chevron.isHidden = !arrow
        menuButton.isHidden = menu == nil
        menuButton.menu = menu
        if menu != nil {
            var config = UIButton.Configuration.plain()
            config.title = detail
            config.image = UIImage(systemName: "chevron.up.chevron.down",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            config.imagePlacement = .trailing
            config.imagePadding = 6
            config.contentInsets = .zero
            config.baseForegroundColor = Theme.mid
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var a = $0
                a.font = Theme.text(15)
                return a
            }
            menuButton.configuration = config
        }
        isAccessibilityElement = menu == nil
        accessibilityLabel = [text, detail].compactMap { $0 }.joined(separator: "，")
    }
}

/// 一段说明文字
final class ParagraphCell: PaperCell {
    private let text = Theme.label(Theme.text(13.5, .regular, .footnote), Theme.mid, lines: 0)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        contentView.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.margin),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.margin),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ paragraph: String) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        text.attributedText = NSAttributedString(string: paragraph, attributes: [.paragraphStyle: style])
    }
}

/// 「请我喝杯咖啡」：一块黑底白字的大按钮
final class CoffeeCell: PaperCell {
    private let box = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        box.backgroundColor = Theme.ink
        box.layer.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "cup.and.saucer.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)))
        icon.tintColor = Theme.paper
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = Theme.label(Theme.text(17, .semibold, .headline), Theme.paper, lines: 0)
        title.text = String(localized: "请我喝杯咖啡")
        let detail = Theme.label(Theme.text(13, .regular, .footnote), Theme.paper.withAlphaComponent(0.7), lines: 0)
        detail.text = String(localized: "Classic Touch 是业余时间做的开源项目。喜欢的话，可以请开发者喝杯咖啡。")
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(box)
        for v in [icon, stack] { box.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -36),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityLabel = (title.text ?? "") + "，" + (detail.text ?? "")
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        box.alpha = highlighted ? 0.75 : 1
    }
}

/// 关于页的小图标，照 App 图标画（docs/design/mockups/app-icon.html）：白底、粗黑线、「2007」、红条
final class IconView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor(white: 0, alpha: 0.15).cgColor
        clipsToBounds = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let s = bounds.width / 1024
        UIColor(white: 0.067, alpha: 1).setFill()
        UIRectFill(CGRect(x: 172 * s, y: 262 * s, width: 680 * s, height: 22 * s))
        UIColor(red: 0.843, green: 0.149, blue: 0.118, alpha: 1).setFill()
        UIRectFill(CGRect(x: 172 * s, y: 716 * s, width: 300 * s, height: 40 * s))
        let font = UIFont(name: "DINCondensed-Bold", size: 440 * s) ?? .systemFont(ofSize: 440 * s, weight: .bold, width: .condensed)
        let text = NSAttributedString(string: "2007", attributes: [.font: font, .foregroundColor: UIColor(white: 0.067, alpha: 1), .kern: -4 * s])
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: 344 * s + (440 * s - size.height) / 2))
    }
}
