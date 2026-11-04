// Launch options: launch arguments (-key value, passed by Xcode, simctl launch or devicectl process launch) come first,
// then Documents/autostart.json. When StikDebug launches the app there are no launch arguments, so this file decides
// which device to boot, with which backend and how big a code region, for example:
//   {"device": "n72ap-7E18", "tcg": "jit", "tbsize": 256, "guestpng": 1, "resetstate": true}
// Without tcg: JIT if a debugger is attached, otherwise the interpreter (when StikDebug launches the app, the debugger
// is attached from the start).
// autostart.json is used once: after reading it is renamed to autostart.used.json, or the app would boot that device
// every time the user opens it, and the list would never show.
// scripts/ios/device-boot.sh rewrites it before every launch.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

final class LaunchOptions {
    private let arguments: [String: Any]
    private let file: [String: Any]

    init(documents: URL) {
        arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let url = documents.appendingPathComponent("autostart.json")
        file = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let used = documents.appendingPathComponent("autostart.used.json")
            try? FileManager.default.removeItem(at: used)
            try? FileManager.default.moveItem(at: url, to: used)
        }
    }

    /// The device came from autostart.json rather than launch arguments
    var fromFile: Bool { arguments["device"] == nil && file["device"] != nil }

    private func value(_ key: String) -> Any? { arguments[key] ?? file[key] }

    func string(forKey key: String) -> String? { value(key).map { "\($0)" } }

    func bool(forKey key: String) -> Bool {
        switch value(key) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }

    func integer(forKey key: String) -> Int {
        (value(key) as? NSNumber)?.intValue ?? Int(string(forKey: key) ?? "") ?? 0
    }

    func double(forKey key: String) -> Double {
        (value(key) as? NSNumber)?.doubleValue ?? Double(string(forKey: key) ?? "") ?? 0
    }

    /// Extra environment variables for QEMU: an object in autostart.json ({"IT_GLES_STRICT": "0"}), "A=1 B=2" as a launch argument
    func environment(forKey key: String) -> [String: String] {
        if let object = value(key) as? [String: Any] { return object.mapValues { "\($0)" } }
        var out: [String: String] = [:]
        for pair in (string(forKey: key) ?? "").split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }
}
