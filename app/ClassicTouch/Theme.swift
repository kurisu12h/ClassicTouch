// 界面的「年表」风格（设计稿见 docs/design/，方案 A）：白纸黑字（深色模式反过来），大号窄体年份，细线分隔，线描机身；
// 红色只用来标正在运行的那台和要注意的事。颜色在 Assets.xcassets 里，浅色、深色各一套。
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

    /// 大号年份用系统自带的 DIN Condensed（iOS 上一直有），万一没有就用系统字体的窄体。本来就够大，而且年份那一栏宽度固定，
    /// 所以不跟「更大字体」放大（其余文字都跟）
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

    /// 一像素的细线
    static func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = rule
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }
}

/// 年表按大版本的首发年份排（3.1.3 记 2009）。目标是 iPhone OS 1 到 iOS 10，App 现在能开的是 runnable 这几个
/// （iPhone OS 1 跑在初代 iPhone 和 iPod touch 1 代上，DeviceProfile 的 s5l8900 开机方式）；
/// 其余在年表里标「以后」：iOS 8 到 10 要 A5/A6 机型，还没有模拟器能跑。
enum Era {
    static let majors = 1...10
    static let runnable = 1...7

    static func year(_ major: Int) -> Int? { majors.contains(major) ? 2006 + major : nil }

    /// 「2009」或「2007–08」
    static func years(_ first: Int, _ last: Int) -> String {
        guard let a = year(first), let b = year(last) else { return "—" }
        return a == b ? "\(a)" : String(format: "%d–%02d", a, b % 100)
    }

    /// 「iPhone OS 1、2」「iOS 4、5」「iPhone OS 3、iOS 4」
    static func names(_ list: [Int]) -> String {
        let old = list.filter { $0 < 4 }.map(String.init), new = list.filter { $0 >= 4 }.map(String.init)
        var parts: [String] = []
        if !old.isEmpty { parts.append("iPhone OS " + old.joined(separator: "、")) }
        if !new.isEmpty { parts.append("iOS " + new.joined(separator: "、")) }
        return parts.joined(separator: "、")
    }
}

/// 线描机身：只有轮廓、屏幕框、听筒、Home 键，按机型分几种外形。自己画的简化外形，没有标志和商标字样。
final class LineDeviceView: UIView {
    enum Shape {
        /// iPod touch 1 到 3 代：圆角、没有听筒
        case pod
        /// 初代 iPhone、3GS：圆润、有听筒
        case round
        /// iPhone 4、iPod touch 4 代：直边、听筒旁有前摄像头
        case flat
        /// 初代 iPad
        case pad
    }

    var shape: Shape = .round { didSet { setNeedsDisplay() } }
    var color: UIColor = Theme.ink { didSet { setNeedsDisplay() } }

    static func shape(for board: String) -> Shape {
        switch board {
        case "n45ap", "n72ap", "n18ap": return .pod
        case "n81ap", "n90ap": return .flat
        case "k48ap": return .pad
        default: return .round
        }
    }

    /// 宽高比（高 / 宽），按各机型正面尺寸简化
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
        // 按 100 宽的坐标画，再缩放到视图大小
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

        // 屏幕：手机 2:3，iPad 3:4；上下边框一样宽
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
