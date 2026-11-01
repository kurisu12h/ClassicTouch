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

    static func isLockScreen(_ texts: [String]) -> Bool {
        texts.contains { $0.lowercased().contains("slide to unlock") }
    }

    /// 「设置」的第一屏：iOS 3 到 7 都有这些行里的至少两行
    static func isSettingsScreen(_ texts: [String]) -> Bool {
        let rows = ["Airplane Mode", "Wi-Fi", "Bluetooth", "Notification", "Control Center", "Do Not Disturb",
                    "General", "Sounds", "Brightness", "Wallpaper"]
        return rows.filter { row in texts.contains { $0.contains(row) } }.count >= 2
    }

    /// 设置页的标题也是「Settings」，要排除
    static func isHomeScreen(_ texts: [String]) -> Bool {
        let marks = ["Settings", "Safari", "App Store", "Calendar", "Photos", "Messages", "Clock"]
        return !isLockScreen(texts) && !isSettingsScreen(texts) && texts.contains { t in marks.contains { t.contains($0) } }
    }
}
