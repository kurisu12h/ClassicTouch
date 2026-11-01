// 启动选项：启动参数（Xcode、simctl launch、devicectl process launch 传的 -key value）优先，
// 其次是 Documents/autostart.json。从 StikDebug 拉起时没有启动参数，就靠这个文件决定开哪台设备、
// 用哪种后端、代码区多大，例如：
//   {"device": "n72ap-7E18", "tcg": "jit", "tbsize": 256, "guestpng": 1, "resetstate": true}
// 不写 tcg 时：有调试器挂着就用 JIT，否则用解释器（StikDebug 拉起时调试器从一开始就挂着）。
// autostart.json 只用一次：读过就改名成 autostart.used.json，不然用户以后自己打开 App 也会直接开那台，看不到列表。
// scripts/ios/device-boot.sh 每次拉起 App 之前都会重写它。
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

    /// 设备是从 autostart.json 而不是启动参数来的
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

    /// 给 QEMU 的额外环境变量：autostart.json 里是对象（{"IT_GLES_STRICT": "0"}），启动参数是「A=1 B=2」
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
