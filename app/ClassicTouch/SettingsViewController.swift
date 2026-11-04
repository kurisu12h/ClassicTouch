// The settings, about and license pages, in the "timeline" style (Theme.swift), reached from the gear at the top right of the home page.
//   Settings: appearance (system, light, dark), systems and storage (size of each, deletable), JIT explanation, about, Buy Me a Coffee
//   About: version, introduction, source code and licenses, acknowledgments, disclaimer
//   Licenses: the ThirdPartyLicenses.txt bundled in the app (this app's GPL and the original license texts of the libraries QEMU links statically)
// SPDX-License-Identifier: GPL-2.0-or-later

import SafariServices
import UIKit

/// External links
enum Links {
    static let source = URL(string: "https://github.com/kurisu12h/ClassicTouch")!
    static let qemuIOS = URL(string: "https://github.com/samhenrigold/qemu-ios")!
    static let lightTouch = URL(string: "https://github.com/samhenrigold/LightTouchMac")!
    static let qemu = URL(string: "https://www.qemu.org")!
    static let stikDebug = URL(string: "https://github.com/StikDebug/StikDebug")!
    /// The donation page for "Buy Me a Coffee". The platform is not decided yet; while it is nil, the button explains it is not set up
    static let coffee: URL? = nil
}

/// Appearance: system, light, dark, saved in UserDefaults and applied as the windows' overrideUserInterfaceStyle. The emulator screen is always black and unaffected
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
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
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

// MARK: - Shared page parts

/// Shared by settings and about: a table without separators; row kinds are in Item.Kind, and tapping a row runs its action
class PageViewController: UITableViewController {
    struct Item {
        enum Kind {
            /// A large title with a thick black rule below
            case title(String)
            /// The about page's header: icon, app name, version
            case about
            case section(String)
            /// Title, value on the right, and whether to show a chevron
            case row(String, String?, chevron: Bool)
            /// A pop-up menu on the right
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
        // The navigation bar keeps only the back button, paper-colored with no separator; the title is in the table header
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
            return alert(String(localized: "Donation Page Not Set Up Yet"), String(localized: "The developer hasn't added a donation page yet. Check back in a few versions. Thanks for wanting to help!"))
        }
        open(url)
    }

    func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(format: String(localized: "Version %@ (%@)"), short, build)
    }
}

// MARK: - Settings

final class SettingsViewController: PageViewController {
    private let documents: URL
    private let current: CurrentSystem?
    var onJITHelp: (() -> Void)?
    /// A system was deleted, so the home page has to rescan
    var onChange: (() -> Void)?

    private var devices: [DeviceProfile] = []
    private var sizes: [String: Int64] = [:]

    init(documents: URL, current: CurrentSystem?) {
        self.documents = documents
        self.current = current
        super.init()
        title = String(localized: "Settings")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The large title already says "Settings", so the navigation bar does not repeat it (title stays for the next page's back button)
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
        var list: [Item] = [Item(kind: .title(String(localized: "Settings")))]

        list.append(Item(kind: .section(String(localized: "Display"))))
        let choices = AppAppearance.allCases.map { choice in
            UIAction(title: choice.title, state: choice == AppAppearance.current ? .on : .off) { [weak self] _ in
                AppAppearance.current = choice
                self?.build()
            }
        }
        list.append(Item(kind: .menu(String(localized: "Appearance"), AppAppearance.current.title, UIMenu(children: choices))))

        list.append(Item(kind: .section(String(localized: "Systems & Storage"))))
        for device in devices {
            let running = current?.id == device.id && current?.stopped == false
            let value = running ? String(localized: "Running") : sizes[device.id].map { ImportManager.bytes($0) } ?? "…"
            list.append(Item(kind: .row(device.displayName, value, chevron: false)) { [weak self] in self?.confirmDelete(device) })
        }
        list.append(Item(kind: .row(String(localized: "How to Import Systems"), nil, chevron: true)) { [weak self] in
            self?.present(LibraryViewController.importHelpAlert(), animated: true)
        })
        var note = devices.isEmpty ? String(localized: "No systems yet.") : String(localized: "Tap one to delete it. Deleting removes all of its data and can't be undone.")
        if let free = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            note += String(format: String(localized: " %@ available on this phone."), ImportManager.bytes(free))
        }
        list.append(Item(kind: .paragraph(note)))

        list.append(Item(kind: .section("JIT")))
        list.append(Item(kind: .row(String(localized: "JIT and StikDebug"), nil, chevron: true)) { [weak self] in self?.onJITHelp?() })

        list.append(Item(kind: .section(String(localized: "About"))))
        list.append(Item(kind: .row(String(localized: "About Classic Touch"), Self.version, chevron: true)) { [weak self] in
            self?.navigationController?.pushViewController(AboutViewController(), animated: true)
        })
        list.append(Item(kind: .coffee) { [weak self] in self?.openCoffee() })
        items = list
    }

    private func confirmDelete(_ device: DeviceProfile) {
        if current?.id == device.id && current?.stopped == false {
            return alert(String(format: String(localized: "%@ Is Running"), device.displayName),
                         String(localized: "A running system can't be deleted. Switch to another one in the timeline first, or swipe the app away in the app switcher and reopen it."))
        }
        let message = sizes[device.id].map {
            String(format: String(localized: "This system and all of its data (%@) will be deleted. This can't be undone; to use it again, import it again."), ImportManager.bytes($0))
        } ?? String(localized: "This system and all of its data will be deleted. This can't be undone; to use it again, import it again.")
        let sheet = UIAlertController(title: String(format: String(localized: "Delete %@?"), device.displayName),
                                      message: message, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in self?.delete(device) })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    private func delete(_ device: DeviceProfile) {
        // Only delete a folder exactly one level under Documents/devices/
        let devicesDir = documents.appendingPathComponent("devices", isDirectory: true).standardizedFileURL
        let target = device.base.standardizedFileURL
        guard target.deletingLastPathComponent().path == devicesDir.path, !device.id.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = Result { try Self.removeTree(target) }.failure
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.alert(String(localized: "Couldn't Delete"), error.localizedDescription) }
                self.sizes[device.id] = nil
                self.reload()
                self.onChange?()
            }
        }
    }
}

extension SettingsViewController {
    /// The device itself has read-only folders (FirmwareKit's nand/ is r-x), so a plain removeItem fails halfway without permission. Make all folders writable first, then delete
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

// MARK: - About

final class AboutViewController: PageViewController {
    override init() {
        super.init()
        title = String(localized: "About")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        items = [
            Item(kind: .about),
            Item(kind: .paragraph(String(localized: "Boot and run the original iPhone OS and iOS of years past on your iPhone, a way for longtime fans to revisit the classics. iPhone OS 1 through iOS 10 all run except iOS 8, which will come later."))),

            Item(kind: .section(String(localized: "Open Source"))),
            Item(kind: .row(String(localized: "Source Code"), "GitHub", chevron: true)) { [weak self] in self?.open(Links.source) },
            Item(kind: .row(String(localized: "License"), "GPL-2.0-or-later", chevron: true)) { [weak self] in self?.showLicenses() },
            Item(kind: .paragraph(String(localized: "Classic Touch is free software, released under the GNU General Public License, version 2 or later. You are free to use, modify, and redistribute it, but it comes with no warranty."))),

            Item(kind: .section(String(localized: "Acknowledgments"))),
            Item(kind: .row("qemu-ios", "GPL-2.0", chevron: true)) { [weak self] in self?.open(Links.qemuIOS) },
            Item(kind: .row("QEMU", "GPL-2.0", chevron: true)) { [weak self] in self?.open(Links.qemu) },
            Item(kind: .row(String(localized: "Light Touch (FirmwareKit)"), "GPL-2.0+", chevron: true)) { [weak self] in self?.open(Links.lightTouch) },
            Item(kind: .row("StikDebug", "AGPL-3.0", chevron: true)) { [weak self] in self?.open(Links.stikDebug) },
            Item(kind: .row(String(localized: "Library Licenses"), nil, chevron: true)) { [weak self] in self?.showLicenses() },
            Item(kind: .paragraph(String(localized: "The emulator core is Sam Henri Gold's qemu-ios, and device creation comes from his Light Touch; JIT comes from StikDebug (installed separately). QEMU statically links GLib, PCRE2, proxy-libintl, pixman, libslirp, OpenSSL, Nettle, and libffi."))),

            Item(kind: .section(String(localized: "Disclaimer"))),
            Item(kind: .paragraph(String(localized: "This project is not affiliated with Apple. iPhone, iPod touch, iPad, and iOS are trademarks of Apple Inc., used here only to describe which models and systems can be emulated. The app does not include any Apple system files."))),

            Item(kind: .coffee) { [weak self] in self?.openCoffee() },
        ]
    }

    private func showLicenses() {
        navigationController?.pushViewController(LicenseTextViewController(), animated: true)
    }
}

// MARK: - License text

final class LicenseTextViewController: UIViewController {
    private let text = UITextView()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Licenses")
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
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Self.reflow) ?? String(localized: "License file not found.")
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

    /// The license texts are hard-wrapped at about 80 columns and the phone wraps them again, which reads choppily. Join
    /// the hard line breaks inside paragraphs: when the previous line is long enough and the next is neither empty nor
    /// starts with whitespace (indented items and headings stay as they are)
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

// MARK: - Rows

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

/// The about page's header: small icon, app name, version
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

/// A section heading ("Display", "Systems & Storage", …)
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

/// A row: a title on the left, a value and chevron on the right, or a pop-up menu
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
        // The right group is only centered vertically and does not set the row height, so toggling isHidden does not have SystemCell's row height problem
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
        accessibilityLabel = [text, detail].compactMap { $0 }.joined(separator: Theme.spokenSeparator)
    }
}

/// A paragraph of explanation
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

/// "Buy Me a Coffee": a big black button with white text
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
        title.text = String(localized: "Buy Me a Coffee")
        let detail = Theme.label(Theme.text(13, .regular, .footnote), Theme.paper.withAlphaComponent(0.7), lines: 0)
        detail.text = String(localized: "Classic Touch is an open-source project made in spare time. If you enjoy it, you can buy the developer a coffee.")
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
        accessibilityLabel = (title.text ?? "") + Theme.spokenSeparator + (detail.text ?? "")
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        box.alpha = highlighted ? 0.75 : 1
    }
}

/// The about page's small icon, drawn after the app icon (docs/design/mockups/app-icon.html): white background, thick black rule, "2007", red bar
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
