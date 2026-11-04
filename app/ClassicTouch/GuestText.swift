// 认客体画面上的英文文字（Vision），给自动测量判断锁屏、主屏和「设置」用（EmulatorViewController 的 autodrive）。
// 第三阶段起在 App 里自己判断：靠 Mac 经 AFC 取截图再识别太慢，iPod touch 2 代锁屏后来不及解锁就进了深睡，
// 用占位 SecureROM 时深睡唤不醒。第四步（iOS 7）起还要找「Settings」图标的位置去点它。
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Vision

struct GuestReading {
    /// 识别出的各段文字
    let texts: [String]
    /// 要找的词在画面上的中心，归一化坐标、原点在左上（和 Engine.touch 一致）
    let places: [String: CGPoint]
}

enum GuestText {
    /// 客体画面只有 320x480 或 640x960，先放大两倍再认，和 Mac 上的 work/tools/ocr 做法一样。
    /// locate 里的词找到了就记下位置（一行里有几个图标名时取那个词本身的框）。
    static func recognize(_ image: CGImage, locate words: [String] = []) -> GuestReading {
        let w = image.width * 2, h = image.height * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return GuestReading(texts: [], places: [:]) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return GuestReading(texts: [], places: [:]) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: scaled, options: [:]).perform([request])
        var texts: [String] = []
        var places: [String: CGPoint] = [:]
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            texts.append(candidate.string)
            for word in words where places[word] == nil {
                // Vision 的框原点在左下
                guard let range = candidate.string.range(of: word),
                      let box = try? candidate.boundingBox(for: range)?.boundingBox
                else { continue }
                places[word] = CGPoint(x: box.midX, y: 1 - box.midY)
            }
        }
        return GuestReading(texts: texts, places: places)
    }

    /// iOS 7 的「slide to unlock」是灰字，上面还有一道流动的高光，识别常把它认错（真机上认成过「Slide to unlog.」
    /// 「slide to umoax」，一次 13 秒里一次都没认全），所以不看空格，认出「slide to un」或「slide」「unlock」分在两段都算。
    /// iOS 10 has no slider. Its "Press home to open" shows only for a few seconds after the screen lights, so the
    /// lock screen's date line ("Wednesday, December 31") counts too; the home screen's Calendar icon has the weekday
    /// and the day on two lines, with no comma and no month.
    static func isLockScreen(_ texts: [String]) -> Bool {
        let all = texts.map { $0.lowercased().filter { !$0.isWhitespace } }
        return all.contains { $0.contains("slidetoun") }   // 「Slide to unlog.」也算
            || (all.contains { $0.contains("slide") } && all.contains { $0.contains("unlock") })
            || all.contains { $0.contains("presshome") }
            || texts.contains { $0.lowercased().range(of: dateLine, options: .regularExpression) != nil }
    }

    static let dateLine = "(mon|tues|wednes|thurs|fri|satur|sun)day, *(january|february|march|april|may|june|july|august|"
        + "september|october|november|december)"


    /// 「设置」的第一屏：iOS 3 到 7 都有这些行里的至少两行
    static func isSettingsScreen(_ texts: [String]) -> Bool {
        let rows = ["Airplane Mode", "Wi-Fi", "Bluetooth", "Notification", "Control Center", "Do Not Disturb",
                    "General", "Sounds", "Brightness", "Wallpaper"]
        return rows.filter { row in texts.contains { $0.contains(row) } }.count >= 2
    }

    static let homeMarks = ["Settings", "Safari", "App Store", "Calendar", "Photos", "Messages", "Clock"]

    /// 设置页的标题也是「Settings」，要排除
    static func isHomeScreen(_ texts: [String]) -> Bool {
        !isLockScreen(texts) && !isSettingsScreen(texts) && homeMarkCount(texts) > 0
    }

    /// 认出了几个不同的主屏图标名。没经过锁屏直接到主屏时（iPhone OS 1.0 从黄金状态冷启动、iPod 的 2.x 激活后
    /// 第一次开机）autodrive 要三个以上才算，免得开机途中的画面误认
    static func homeMarkCount(_ texts: [String]) -> Int {
        homeMarks.filter { mark in texts.contains { $0.contains(mark) } }.count
    }
}
