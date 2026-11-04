// Reads English text on the guest screen (Vision), so automated measurements can tell the lock screen, home screen and
// Settings apart (autodrive in EmulatorViewController). From stage 3 on, the app decides by itself: having the Mac pull
// screenshots over AFC to recognize them was too slow, and the iPod touch 2nd gen fell into deep sleep after locking
// before it could be unlocked, which the placeholder SecureROM never wakes from. From step 4 (iOS 7) on, it also has to
// find the "Settings" icon to tap it.
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Vision

struct GuestReading {
    /// Each recognized piece of text
    let texts: [String]
    /// Centers of the requested words on screen, in normalized coordinates with the origin at top left (as in Engine.touch)
    let places: [String: CGPoint]
}

enum GuestText {
    /// The guest screen is only 320x480 or 640x960, so it is scaled up 2x before recognition, as work/tools/ocr/ocr does on the Mac.
    /// Words in locate are located when found (when a line holds several icon names, the box of the word itself is used).
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
                // Vision boxes have their origin at bottom left
                guard let range = candidate.string.range(of: word),
                      let box = try? candidate.boundingBox(for: range)?.boundingBox
                else { continue }
                places[word] = CGPoint(x: box.midX, y: 1 - box.midY)
            }
        }
        return GuestReading(texts: texts, places: places)
    }

    /// The "slide to unlock" of iOS 7 is gray text with a moving highlight over it, and recognition often gets it wrong
    /// (on a real phone it read "Slide to unlog." and "slide to umoax", and in one 13-second stretch never got it fully
    /// right), so spaces are ignored, and "slide to un", or "slide" and "unlock" in two pieces, both count.
    /// iOS 10 has no slider. Its "Press home to open" shows only for a few seconds after the screen lights, so the
    /// lock screen's date line ("Wednesday, December 31") counts too; the home screen's Calendar icon has the weekday
    /// and the day on two lines, with no comma and no month.
    static func isLockScreen(_ texts: [String]) -> Bool {
        let all = texts.map { $0.lowercased().filter { !$0.isWhitespace } }
        return all.contains { $0.contains("slidetoun") }   // "Slide to unlog." counts too
            || (all.contains { $0.contains("slide") } && all.contains { $0.contains("unlock") })
            || all.contains { $0.contains("presshome") }
            || texts.contains { $0.lowercased().range(of: dateLine, options: .regularExpression) != nil }
    }

    static let dateLine = "(mon|tues|wednes|thurs|fri|satur|sun)day, *(january|february|march|april|may|june|july|august|"
        + "september|october|november|december)"


    /// The first page of Settings: iOS 3 to 7 all have at least two of these rows
    static func isSettingsScreen(_ texts: [String]) -> Bool {
        let rows = ["Airplane Mode", "Wi-Fi", "Bluetooth", "Notification", "Control Center", "Do Not Disturb",
                    "General", "Sounds", "Brightness", "Wallpaper"]
        return rows.filter { row in texts.contains { $0.contains(row) } }.count >= 2
    }

    static let homeMarks = ["Settings", "Safari", "App Store", "Calendar", "Photos", "Messages", "Clock"]

    /// The Settings page's title is also "Settings", so exclude it
    static func isHomeScreen(_ texts: [String]) -> Bool {
        !isLockScreen(texts) && !isSettingsScreen(texts) && homeMarkCount(texts) > 0
    }

    /// How many distinct home screen icon names were recognized. When the home screen comes without a lock screen first
    /// (iPhone OS 1.0 cold-booting from the golden state, the iPod's 2.x booting for the first time after activation),
    /// autodrive needs three or more, so screens during boot are not mistaken for it
    static func homeMarkCount(_ texts: [String]) -> Int {
        homeMarks.filter { mark in texts.contains { $0.contains(mark) } }.count
    }
}
