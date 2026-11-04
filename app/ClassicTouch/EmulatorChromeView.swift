// The "timeline" look around the emulator screen (mockup docs/design/mockups/a-run.html): a black background; at the
// top a large year, the model and system, and "⋯"; a thin rule; below it a line of run status (small monospaced text,
// collapsed or expanded with "⋯" and remembered in UserDefaults); the middle is left for the guest screen; at the
// bottom three large square buttons: Back (to the timeline), Home, Power.
//
// EmulatorViewController uses it (since 2026-11-02): it adds this view first, then the guest screen (the screen sits on
// top; the empty areas here take no touches). The old status, backButton, homeButton and powerButton are status, back,
// home and power here; viewDidLayoutSubviews fills the frame, calls layoutIfNeeded, then places the guest screen at
// screenFrame(for:).
// Debug builds also have a preview: launch argument -uipreview <device id> (see LibraryViewController and
// EmulatorChromePreviewController below), which starts no QEMU.
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
            // The outer viewDidLayoutSubviews places the screen at screenFrame, so it has to lay out again too
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
        more.accessibilityLabel = String(localized: "Show or hide status")
        more.addAction(UIAction { [weak self] _ in self?.showsStatus.toggle() }, for: .touchUpInside)

        style(back, title: String(localized: "Back", comment: "The emulator screen's button that returns to the timeline"),
              symbol: "chevron.left", primary: false)
        style(home, title: "Home", symbol: "circle", primary: true)
        style(power, title: String(localized: "Power"), symbol: "power", primary: false)
        back.accessibilityLabel = String(localized: "Back to Timeline")
        power.accessibilityLabel = String(localized: "Power button")
        home.accessibilityLabel = String(localized: "Home button")

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

    /// backend is a short word such as "JIT" or "Interpreter", and may be nil
    func configure(_ profile: DeviceProfile?, backend: String?) {
        year.text = profile.flatMap { Era.year($0.majorVersion) }.map(String.init) ?? "—"
        model.text = profile?.modelName
        system.text = [profile?.systemName, backend].compactMap { $0 }.joined(separator: " · ")
        year.accessibilityLabel = year.text
        setNeedsLayout()
    }

    /// Only the buttons take touches; empty areas go to the view below (EmulatorViewController's own touch handling)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        let m = Theme.margin, width = bounds.width - 2 * m
        // Devices without a notch (SE) have zero top and bottom safe areas; leave at least a little margin
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

        // The guest screen leaves 21 pt on each side (exactly 360 × 540 on a 402-wide screen, 1.125 times the original)
        screenArea = CGRect(x: 21, y: y + 8, width: bounds.width - 42, height: buttonY - 20 - (y + 8))
    }

    /// Where the guest screen goes: scaled to fit the middle area, centered horizontally and vertically
    func screenFrame(for guest: CGSize) -> CGRect {
        guard guest.width > 0, guest.height > 0, screenArea.width > 0, screenArea.height > 0 else { return .zero }
        let scale = min(screenArea.width / guest.width, screenArea.height / guest.height)
        let size = CGSize(width: (guest.width * scale).rounded(), height: (guest.height * scale).rounded())
        return CGRect(x: screenArea.midX - size.width / 2, y: screenArea.minY + (screenArea.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

#if DEBUG
/// For viewing the new look (launch argument -uipreview <device id>): the screen area shows Documents/ui-preview.png
/// (dark gray if it is missing), Home and Power only log a line, and "Back" closes the preview. Starts no QEMU.
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
        chrome.status.text = String(
            format: String(localized: "%@ · %@ · %d:%02d\nCPU %.0f%% (%.0f s total) · using %.0f MB · %.0f MB free · frame %d"),
            profile?.displayName ?? "?", "JIT", 0, 54, 10.0, 33.0, 805.0, 2150.0, 1234)
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
