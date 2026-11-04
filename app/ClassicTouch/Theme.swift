// The UI's "timeline" style (design in docs/design/, option A): black on white paper (reversed in dark mode), large
// condensed years, thin rules, line drawings of devices; red only marks the running device and things to watch out for.
// The colors are in Assets.xcassets, one set each for light and dark.
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

enum Theme {
    static let paper = UIColor(named: "Paper") ?? .systemBackground
    static let ink = UIColor(named: "Ink") ?? .label
    static let mid = UIColor(named: "Mid") ?? .secondaryLabel
    static let faint = UIColor(named: "Faint") ?? .tertiaryLabel
    static let rule = UIColor(named: "Rule") ?? .separator
    static let accent = UIColor(named: "Accent") ?? .systemRed
    static let margin: CGFloat = 22

    /// Large years use the built-in DIN Condensed (always present on iOS), falling back to the condensed system font. They
    /// are big enough already and the year column has a fixed width, so they do not grow with Larger Text (all other text does)
    static func year(_ size: CGFloat) -> UIFont {
        UIFont(name: "DINCondensed-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold, width: .condensed)
    }

    static func text(_ size: CGFloat, _ weight: UIFont.Weight = .regular, _ style: UIFont.TextStyle = .body) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    static func label(_ font: UIFont, _ color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A one-pixel hairline
    static func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = rule
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }

    /// Joins the parts of a VoiceOver label (a comma in English, a full-width comma in Chinese)
    static var spokenSeparator: String { String(localized: ", ", comment: "Between the parts of a VoiceOver label") }
}

/// The timeline is ordered by each major version's first release year (3.1.3 counts as 2009). The goal is iPhone OS 1 to
/// iOS 10; the app can boot the runnable ones now (iPhone OS 1 runs on the original iPhone and iPod touch 1st gen with
/// DeviceProfile's s5l8900 boot strategy; iOS 9 runs on the iPod touch 5th gen with the n78 boot strategy,
/// docs/reports/a5-app.md). The rest are marked "Later" in the timeline: the iPod touch 5th gen firmware for iOS 8 is not
/// made yet, and iOS 10 needs an A6 or newer device.
/// iOS 10 now runs on the emulated iPhone 5 (A6, n41ap, the n78 boot strategy; docs/reports/a6-app.md).
enum Era {
    static let majors = 1...10
    static let runnable: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 9, 10]

    static func year(_ major: Int) -> Int? { majors.contains(major) ? 2006 + major : nil }

    /// "2009" or "2007–08"
    static func years(_ first: Int, _ last: Int) -> String {
        guard let a = year(first), let b = year(last) else { return "—" }
        return a == b ? "\(a)" : String(format: "%d–%02d", a, b % 100)
    }

    /// "iPhone OS 1, 2", "iOS 4, 5", "iPhone OS 3, iOS 4" (the separator is the catalog's "%@, %@")
    static func names(_ list: [Int]) -> String {
        let old = list.filter { $0 < 4 }.map(String.init), new = list.filter { $0 >= 4 }.map(String.init)
        var parts: [String] = []
        if !old.isEmpty { parts.append("iPhone OS " + old.listed) }
        if !new.isEmpty { parts.append("iOS " + new.listed) }
        return parts.listed
    }
}

extension Array where Element == String {
    /// A short list joined for the UI language with the catalog's "%@, %@" ("4, 5, 6" in English)
    var listed: String {
        dropFirst().reduce(first ?? "") { String(format: String(localized: "%@, %@", comment: "Joins two items of a short list"), $0, $1) }
    }
}

/// A line drawing of the device: just the outline, screen frame, earpiece and Home button, in a few shapes by model. Simplified shapes drawn here, with no logos or trademark text.
final class LineDeviceView: UIView {
    enum Shape {
        /// iPod touch 1st to 3rd gen: rounded corners, no earpiece
        case pod
        /// Original iPhone, 3GS: rounded, with an earpiece
        case round
        /// iPhone 4, iPod touch 4th gen: straight edges, a front camera beside the earpiece
        case flat
        /// Original iPad
        case pad
    }

    var shape: Shape = .round { didSet { setNeedsDisplay() } }
    var color: UIColor = Theme.ink { didSet { setNeedsDisplay() } }

    static func shape(for board: String) -> Shape {
        switch board {
        case "n45ap", "n72ap", "n18ap": return .pod
        case "n81ap", "n90ap", "n78ap", "n41ap": return .flat
        case "k48ap": return .pad
        default: return .round
        }
    }

    /// Aspect ratio (height / width), simplified from each model's front dimensions
    var aspect: CGFloat {
        switch shape {
        case .pod: return 1.78
        case .round: return 1.9
        case .flat: return 1.96
        case .pad: return 1.28
        }
    }

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        // Draw in a 100-wide coordinate space, then scale to the view
        let w: CGFloat = 100, h = w * aspect
        let scale = min(bounds.width / (w + 6), bounds.height / (h + 6))
        guard let ctx = UIGraphicsGetCurrentContext(), scale > 0 else { return }
        ctx.translateBy(x: (bounds.width - w * scale) / 2, y: (bounds.height - h * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        color.setStroke()

        let corner: CGFloat
        switch shape {
        case .pod: corner = 15
        case .round: corner = 17
        case .flat: corner = 10
        case .pad: corner = 9
        }
        let body = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: corner)
        body.lineWidth = 4.5
        body.stroke()

        // Screen: 2:3 on phones, 3:4 on iPad; the top and bottom bezels are equally wide
        let screenW: CGFloat = shape == .pad ? 80 : 76
        let screenH = shape == .pad ? screenW * 4 / 3 : screenW * 1.5
        let top = (h - screenH) / 2
        let screen = UIBezierPath(rect: CGRect(x: (w - screenW) / 2, y: top, width: screenW, height: screenH))
        screen.lineWidth = 3.2
        screen.stroke()

        if shape == .round || shape == .flat {
            let ear = UIBezierPath()
            ear.move(to: CGPoint(x: 42, y: top / 2))
            ear.addLine(to: CGPoint(x: 58, y: top / 2))
            ear.lineWidth = 4
            ear.lineCapStyle = .round
            ear.stroke()
        }
        if shape == .flat {
            let cam = UIBezierPath(ovalIn: CGRect(x: 30, y: top / 2 - 2.2, width: 4.4, height: 4.4))
            cam.lineWidth = 3
            cam.stroke()
        }
        let r: CGFloat = shape == .pad ? 6 : 9
        let home = UIBezierPath(ovalIn: CGRect(x: w / 2 - r, y: top + screenH + (h - top - screenH) / 2 - r, width: 2 * r, height: 2 * r))
        home.lineWidth = 3.2
        home.stroke()
    }
}
