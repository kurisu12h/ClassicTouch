// 首页（LibraryViewController）的几种行，「年表」风格（Theme.swift）：
//   表头：App 名、设置和导入按钮、「选择系统」、年份范围、统计、一道粗黑线
//   系统行：左边大号年份，中间机型、系统版本、构建号、占用，最右线描机身；正在运行的那台年份变红、左边一道红条、带「继续」
//   灰行：没导入的年份（「2010–11 · iOS 4、5 · 还没导入」），以及还不能模拟的 iOS 8 到 10（「以后」）
//   消息行：导入进度和结果、没有系统时的说明
//   脚注、JIT 框
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class PaperCell: UITableViewCell {
    let rule = Theme.hairline()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.paper
        let selected = UIView()
        selected.backgroundColor = Theme.rule
        selectedBackgroundView = selected
        contentView.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.margin),
            rule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.margin),
            rule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 年份那一栏的宽度
private let yearColumn: CGFloat = 92

final class LibraryHeaderCell: PaperCell {
    let importButton = UIButton(type: .system)
    let settingsButton = UIButton(type: .system)
    private let range = Theme.label(Theme.year(30), Theme.faint)
    private let meta = Theme.label(Theme.text(13.5, .regular, .footnote), Theme.mid, lines: 0)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        let app = Theme.label(Theme.text(15, .semibold, .subheadline), Theme.ink)
        app.text = "Classic Touch"
        let title = Theme.label(Theme.text(31, .bold, .largeTitle), Theme.ink)
        title.text = String(localized: "选择系统")
        title.accessibilityTraits = .header
        importButton.setImage(UIImage(systemName: "square.and.arrow.down",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        importButton.tintColor = Theme.ink
        importButton.accessibilityLabel = String(localized: "怎么导入")
        importButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setImage(UIImage(systemName: "gearshape",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        settingsButton.tintColor = Theme.ink
        settingsButton.accessibilityLabel = String(localized: "设置")
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        let bar = UIView()
        bar.backgroundColor = Theme.ink
        bar.translatesAutoresizingMaskIntoConstraints = false
        for v in [app, importButton, settingsButton, title, range, meta, bar] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            app.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            app.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            importButton.centerYAnchor.constraint(equalTo: app.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            importButton.widthAnchor.constraint(equalToConstant: 44),
            importButton.heightAnchor.constraint(equalToConstant: 44),
            settingsButton.centerYAnchor.constraint(equalTo: app.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
            title.topAnchor.constraint(equalTo: app.bottomAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            range.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
            range.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            range.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),
            bar.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 16),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            bar.heightAnchor.constraint(equalToConstant: 3),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(range text: String, meta info: String) {
        range.text = text
        range.accessibilityLabel = text.replacingOccurrences(of: "–", with: String(localized: " 到 "))
        meta.text = info
    }
}

/// 一台系统
final class SystemCell: PaperCell {
    let resume = UIButton(type: .system)
    private let year = Theme.label(Theme.year(46), Theme.ink)
    private let model = Theme.label(Theme.text(17, .semibold, .headline), Theme.ink, lines: 0)
    private let detail = Theme.label(Theme.text(13.5, .regular, .footnote), Theme.mid, lines: 0)
    private let notes = UIStackView()
    private let device = LineDeviceView(shape: .round)
    private let bar = UIView()
    private let text = UIStackView()
    /// 提示行和「继续」并排（普通容器加约束；横排的 UIStackView 套多行文字时，第一次量行高会量错）
    private let noteRow = UIView()
    private var idle: [NSLayoutConstraint] = []
    private var busy: [NSLayoutConstraint] = []
    private var deviceHeight: NSLayoutConstraint!
    /// 平时右边给线描机身留位置；正在运行的那台没有机身，文字和「继续」一直排到右边
    private var trailing: NSLayoutConstraint!
    private var trailingLive: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        bar.backgroundColor = Theme.accent
        bar.translatesAutoresizingMaskIntoConstraints = false
        device.translatesAutoresizingMaskIntoConstraints = false
        device.isAccessibilityElement = false
        year.setContentHuggingPriority(.required, for: .horizontal)
        year.adjustsFontSizeToFitWidth = true
        year.minimumScaleFactor = 0.5

        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Theme.ink
        config.baseForegroundColor = Theme.paper
        config.cornerStyle = .fixed
        config.background.cornerRadius = 8
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0
            a.font = Theme.text(15, .semibold)
            return a
        }
        config.title = String(localized: "继续")
        resume.configuration = config
        resume.translatesAutoresizingMaskIntoConstraints = false
        // 只是个样子：点到它就是点了这一行，由列表的 didSelect 处理
        resume.isUserInteractionEnabled = false
        resume.setContentHuggingPriority(.required, for: .horizontal)
        resume.setContentCompressionResistancePriority(.required, for: .horizontal)

        notes.axis = .vertical
        notes.spacing = 3
        notes.translatesAutoresizingMaskIntoConstraints = false
        noteRow.addSubview(notes)
        noteRow.addSubview(resume)
        NSLayoutConstraint.activate([
            notes.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor),
            notes.topAnchor.constraint(equalTo: noteRow.topAnchor),
            notes.bottomAnchor.constraint(lessThanOrEqualTo: noteRow.bottomAnchor),
        ])
        let fit = noteRow.heightAnchor.constraint(equalTo: notes.heightAnchor)
        fit.priority = .defaultLow
        fit.isActive = true
        idle = [notes.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor)]
        busy = [
            notes.trailingAnchor.constraint(lessThanOrEqualTo: resume.leadingAnchor, constant: -8),
            resume.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor),
            resume.centerYAnchor.constraint(equalTo: notes.centerYAnchor),
            resume.topAnchor.constraint(greaterThanOrEqualTo: noteRow.topAnchor),
            resume.bottomAnchor.constraint(lessThanOrEqualTo: noteRow.bottomAnchor),
        ]
        // 整宽排（不用 .leading），多行文字的行高才量得准
        for v in [model, detail, noteRow] { text.addArrangedSubview(v) }
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(6, after: detail)
        text.translatesAutoresizingMaskIntoConstraints = false

        for v in [bar, year, text, device] { contentView.addSubview(v) }
        let m = Theme.margin
        deviceHeight = device.heightAnchor.constraint(equalToConstant: 46)
        trailing = text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -(m + 36))
        trailingLive = text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),
            year.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            year.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            year.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m + yearColumn),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            trailing,
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            year.trailingAnchor.constraint(lessThanOrEqualTo: text.leadingAnchor, constant: -6),
            device.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            device.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            device.widthAnchor.constraint(equalToConstant: 24),
            deviceHeight,
            device.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// year 为 nil 时不显示年份（同一年的第二台）。notes 是下面的提示行（文字、颜色），live 是正在运行（已暂停）的那台
    func configure(year text: String?, model name: String, detail info: String, notes lines: [(String, UIColor)],
                   board: String, live: Bool) {
        year.text = text
        year.textColor = live ? Theme.accent : Theme.ink
        model.text = name
        detail.text = info
        notes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (line, color) in lines {
            let label = Theme.label(Theme.text(13, .medium, .footnote), color, lines: 0)
            label.text = line
            notes.addArrangedSubview(label)
        }
        // 不切换 isHidden：UIStackView 隐藏排列子视图时加的高度约束会残留到第一次量行高，把提示行压扁。
        // 没有提示时这一块本来就是 0 高，间距也设成 0；正在运行的那台「继续」和提示并排，离上面那行远一点
        self.text.setCustomSpacing(live ? 12 : lines.isEmpty ? 0 : 6, after: detail)
        bar.isHidden = !live
        resume.isHidden = !live
        NSLayoutConstraint.deactivate([trailing, trailingLive] + idle + busy)
        NSLayoutConstraint.activate(live ? [trailingLive] + busy : [trailing] + idle)
        device.isHidden = live
        device.shape = LineDeviceView.shape(for: board)
        deviceHeight.constant = 24 * device.aspect
        isAccessibilityElement = true
        accessibilityLabel = ([text, name, info] + lines.map(\.0)).compactMap { $0 }.joined(separator: "，")
        accessibilityTraits = .button
    }
}

/// 灰行：没导入的年份，或者还不能模拟的版本（later）
final class GhostCell: PaperCell {
    private let year = Theme.label(Theme.year(26), Theme.faint)
    private let text = Theme.label(Theme.text(14, .regular, .subheadline), Theme.mid, lines: 0)
    private let soon = PaddedLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        soon.text = String(localized: "以后")
        soon.font = Theme.text(11, .medium, .caption1)
        soon.textColor = Theme.mid
        soon.layer.borderColor = Theme.faint.cgColor
        soon.layer.borderWidth = 1
        soon.layer.cornerRadius = 4
        soon.translatesAutoresizingMaskIntoConstraints = false
        year.adjustsFontSizeToFitWidth = true
        year.minimumScaleFactor = 0.5
        for v in [year, text, soon] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            year.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            year.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 17),
            year.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            year.trailingAnchor.constraint(lessThanOrEqualTo: text.leadingAnchor, constant: -6),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m + yearColumn),
            text.firstBaselineAnchor.constraint(equalTo: year.firstBaselineAnchor, constant: -2),
            text.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            soon.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
            soon.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            soon.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        soon.layer.borderColor = Theme.faint.cgColor
    }

    func configure(years: String, text info: String, later: Bool) {
        year.text = years
        text.text = info
        soon.isHidden = !later
        // 「以后」比「还没导入」再淡一些，一看就知道还不能用
        year.alpha = later ? 0.6 : 1
        text.alpha = later ? 0.6 : 1
        soon.alpha = later ? 0.8 : 1
        accessibilityLabel = years + "，" + info + (later ? "，" + String(localized: "以后") : "")
    }
}

/// 导入进度和结果、没有系统时的说明：左边一栏放图标，右边标题、说明，导入中带一条细进度条
final class MessageCell: PaperCell {
    private let icon = UIImageView()
    private let title = Theme.label(Theme.text(15, .semibold, .subheadline), Theme.ink, lines: 0)
    private let detail = Theme.label(Theme.text(13, .regular, .footnote), Theme.mid, lines: 0)
    private let progress = UIProgressView(progressViewStyle: .bar)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        progress.progressTintColor = Theme.ink
        progress.trackTintColor = Theme.rule
        let stack = UIStackView(arrangedSubviews: [title, detail, progress])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, stack] { contentView.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            icon.topAnchor.constraint(equalTo: stack.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m + yearColumn),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// fraction 不为 nil 时显示进度条
    func configure(symbol: String, tint: UIColor = Theme.ink, title text: String, detail info: String?, fraction: Double? = nil) {
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = tint
        title.text = text
        detail.text = info
        detail.isHidden = info == nil
        progress.isHidden = fraction == nil
        progress.progress = Float(fraction ?? 0)
    }
}

/// 列表底下的一行小字
final class NoteCell: PaperCell {
    private let text = Theme.label(Theme.text(12.5, .regular, .footnote), Theme.mid, lines: 0)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        rule.isHidden = true
        contentView.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.margin),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.margin),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ note: String) { text.text = note }
}

/// JIT 状态：一个黑框，点了看说明
final class JITCell: PaperCell {
    private let box = UIView()
    private let icon = UIImageView()
    private let title = Theme.label(Theme.text(15, .semibold, .subheadline), Theme.ink, lines: 0)
    private let detail = Theme.label(Theme.text(13, .regular, .footnote), Theme.mid, lines: 0)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        rule.isHidden = true
        selectedBackgroundView = nil
        selectionStyle = .none
        box.layer.borderWidth = 1.5
        box.layer.borderColor = Theme.ink.cgColor
        box.layer.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = Theme.ink
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(box)
        for v in [icon, stack] { box.addSubview(v) }
        let m = Theme.margin
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            box.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: stack.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        box.layer.borderColor = Theme.ink.cgColor
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        box.backgroundColor = highlighted ? Theme.rule : .clear
    }

    func configure(symbol: String, title text: String, detail info: String) {
        icon.image = UIImage(systemName: symbol)
        title.text = text
        detail.text = info
        isAccessibilityElement = true
        accessibilityLabel = text + "，" + info
        accessibilityTraits = .button
    }
}

/// 带内边距的小标签（「以后」）
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
