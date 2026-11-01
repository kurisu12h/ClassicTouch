// 模拟器画面的「年表」外观（设计稿 docs/design/mockups/a-run.html）：黑底；顶上大号年份、机型和系统、「⋯」；一道细线；
// 下面一行运行状态（等宽小字，点「⋯」收起或展开，记在 UserDefaults）；中间留给客体屏幕；底部三个方正的大按键：
// 年表（返回列表）、Home、电源。
//
// EmulatorViewController 用它（2026-11-02 接入）：先把它加进 view、再加客体屏幕（屏幕盖在上面；这里的空白处不接触摸），
// 原来的 status、backButton、homeButton、powerButton 就是这里的 status、back、home、power；
// viewDidLayoutSubviews 里 frame 铺满、layoutIfNeeded，再按 screenFrame(for:) 摆客体屏幕。
// 调试版另有预览：启动参数 -uipreview <设备 id>（见 LibraryViewController 和下面的 EmulatorChromePreviewController），不起 QEMU。
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

final class EmulatorChromeView: UIView {
    let status = UILabel()
    let back = UIButton(type: .system)
    let home = UIButton(type: .system)
    let power = UIButton(type: .system)
    let more = UIButton(type: .system)

    private let year = UILabel()
    private let model = UILabel()
    private let system = UILabel()
    private let rule = UIView()
    private var screenArea = CGRect.zero
    private static let statusKey = "chromeShowsStatus"

    var showsStatus: Bool {
        get { UserDefaults.standard.object(forKey: Self.statusKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.statusKey)
            // 屏幕的位置由外面的 viewDidLayoutSubviews 按 screenFrame 摆，要让它也重排
            setNeedsLayout()
            superview?.setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        year.font = Theme.year(48)
        year.textColor = .white
        model.font = Theme.text(16, .semibold, .headline)
        model.textColor = .white
        system.font = Theme.text(12.5, .regular, .footnote)
        system.textColor = UIColor(white: 1, alpha: 0.55)
        rule.backgroundColor = UIColor(white: 1, alpha: 0.16)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = UIColor(white: 1, alpha: 0.6)
        status.numberOfLines = 2
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7

        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
                      for: .normal)
        more.tintColor = .white
        more.accessibilityLabel = String(localized: "显示或隐藏运行状态")
        more.addAction(UIAction { [weak self] _ in self?.showsStatus.toggle() }, for: .touchUpInside)

        style(back, title: String(localized: "年表"), symbol: "chevron.left", primary: false)
        style(home, title: "Home", symbol: "circle", primary: true)
        style(power, title: String(localized: "电源"), symbol: "power", primary: false)
        back.accessibilityLabel = String(localized: "返回年表")
        power.accessibilityLabel = String(localized: "电源键")
        home.accessibilityLabel = String(localized: "Home 键")

        for v in [year, model, system, more, rule, status, back, home, power] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func style(_ button: UIButton, title: String, symbol: String, primary: Bool) {
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.imagePadding = 8
        config.baseForegroundColor = primary ? .black : .white
        if primary { config.baseBackgroundColor = .white }
        config.background.cornerRadius = 12
        if !primary {
            config.background.strokeColor = UIColor(white: 1, alpha: 0.28)
            config.background.strokeWidth = 1.5
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0
            a.font = Theme.text(15, .semibold)
            return a
        }
        button.configuration = config
    }

    /// backend 是「JIT」或「解释器」这类短词，可以为 nil
    func configure(_ profile: DeviceProfile?, backend: String?) {
        year.text = profile.flatMap { Era.year($0.majorVersion) }.map(String.init) ?? "—"
        model.text = profile?.modelName
        system.text = [profile?.systemName, backend].compactMap { $0 }.joined(separator: " · ")
        year.accessibilityLabel = year.text
        setNeedsLayout()
    }

    /// 只有按键接触摸；空白处让给下面（EmulatorViewController 自己的触摸处理）
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        let m = Theme.margin, width = bounds.width - 2 * m
        // 没有刘海的机型（SE）安全区上下都是 0，至少留出一点边
        let top = max(safe.minY + 4, 14)

        year.sizeToFit()
        year.frame.origin = CGPoint(x: m, y: top)
        more.frame = CGRect(x: bounds.width - 14 - 40, y: top + 4, width: 40, height: 40)
        let textX = year.frame.maxX + 12, textW = more.frame.minX - 8 - textX
        model.frame = CGRect(x: textX, y: top + 5, width: textW, height: model.font.lineHeight)
        system.frame = CGRect(x: textX, y: model.frame.maxY + 3, width: textW, height: system.font.lineHeight)
        rule.frame = CGRect(x: m, y: max(year.frame.maxY, system.frame.maxY) + 12, width: width, height: 1 / max(1, window?.screen.scale ?? 3))

        var y = rule.frame.maxY + 8
        status.isHidden = !showsStatus
        if showsStatus {
            status.frame = CGRect(x: m, y: y, width: width, height: 30)
            y = status.frame.maxY + 6
        }

        let buttonH: CGFloat = 64, gap: CGFloat = 10
        let buttonY = min(safe.maxY - 8, bounds.maxY - 16) - buttonH
        let unit = (width - 2 * gap) / 3.25
        back.frame = CGRect(x: m, y: buttonY, width: unit, height: buttonH)
        home.frame = CGRect(x: back.frame.maxX + gap, y: buttonY, width: unit * 1.25, height: buttonH)
        power.frame = CGRect(x: home.frame.maxX + gap, y: buttonY, width: unit, height: buttonH)

        // 客体屏幕左右各留 21 pt（402 宽的屏上正好 360 × 540，原机的 1.125 倍）
        screenArea = CGRect(x: 21, y: y + 8, width: bounds.width - 42, height: buttonY - 20 - (y + 8))
    }

    /// 客体屏幕放在哪：按比例缩放，放进中间那块，横向居中、纵向居中
    func screenFrame(for guest: CGSize) -> CGRect {
        guard guest.width > 0, guest.height > 0, screenArea.width > 0, screenArea.height > 0 else { return .zero }
        let scale = min(screenArea.width / guest.width, screenArea.height / guest.height)
        let size = CGSize(width: (guest.width * scale).rounded(), height: (guest.height * scale).rounded())
        return CGRect(x: screenArea.midX - size.width / 2, y: screenArea.minY + (screenArea.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

#if DEBUG
/// 看新外观用（启动参数 -uipreview <设备 id>）：屏幕位置放 Documents/ui-preview.png（没有就是暗灰色），
/// Home 和电源只记一行日志，「年表」关掉预览。不起 QEMU。
final class EmulatorChromePreviewController: UIViewController {
    private let profile: DeviceProfile?
    private let documents: URL
    private let chrome = EmulatorChromeView()
    private let screen = UIImageView()

    init(profile: DeviceProfile?, documents: URL) {
        self.profile = profile
        self.documents = documents
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        chrome.configure(profile, backend: "JIT")
        chrome.status.text = "\(profile?.displayName ?? "?") · JIT · 0:54\nCPU 10%（累计 33 秒）· 占用 805 MB · 可用 2.1 GB · 帧 1234"
        chrome.back.addAction(UIAction { [weak self] _ in self?.dismiss(animated: false) }, for: .touchUpInside)
        chrome.home.addAction(UIAction { _ in NSLog("ui-preview: home") }, for: .touchUpInside)
        chrome.power.addAction(UIAction { _ in NSLog("ui-preview: power") }, for: .touchUpInside)
        screen.image = UIImage(contentsOfFile: documents.appendingPathComponent("ui-preview.png").path)
        screen.backgroundColor = UIColor(white: 0.12, alpha: 1)
        screen.layer.magnificationFilter = .linear
        view.addSubview(chrome)
        view.addSubview(screen)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        chrome.frame = view.bounds
        chrome.layoutIfNeeded()
        let guest = profile.map { CGSize(width: $0.info.width, height: $0.info.height) } ?? CGSize(width: 320, height: 480)
        screen.frame = chrome.screenFrame(for: guest)
    }
}
#endif
