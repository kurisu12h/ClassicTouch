// 导入设备包，不靠脚本：用户用 Finder（文件共享）或「文件」App 把 .ctpack 放进 Documents/import/（直接放 Documents
// 根目录也认）。App 盯着这两个目录，包的修改时间 3 秒没变（认为拷完了）就解到 import/.staging-<包名>/，完整解完再并进
// Documents、删掉包。首页显示拷入中、解包进度和结果；结果另外追加到 logs/import.log（scripts/ios/device-boot.sh 会取回）。
// 脚本的老用法照旧：宿主把包拷进 import/ 再启动 App，App 一起来就解，测试入口等导入完才开机（RootViewController）。
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

final class ImportManager {
    struct Active {
        let name: String
        var done: UInt64
        let total: UInt64
    }

    struct Result {
        let name: String
        let ok: Bool
        let text: String
    }

    let documents: URL
    private(set) var active: Active?
    /// 还在拷入（修改时间不到 3 秒）的包名
    private(set) var copying: [String] = []
    /// 最近的结果，新的在前
    private(set) var results: [Result] = []
    var onChange: (() -> Void)?
    /// 正在运行的设备。包里是它就先不并进来（会换掉 QEMU 正开着的文件），等下次打开 App 再导入
    var busyDevice: String?

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "import", qos: .userInitiated)
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescan: Timer?
    /// 失败过的包（路径 → 大小和修改时间），没变就不再重试；拷入中途被读到而失败的，接着拷完大小一变就会重试
    private var failed: [String: String] = [:]
    private var deferred: Set<String> = []

    var importDir: URL { documents.appendingPathComponent("import", isDirectory: true) }
    var idle: Bool { active == nil && copying.isEmpty }

    init(documents: URL) {
        self.documents = documents
    }

    func start() {
        try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        // 上次解到一半被杀留下的暂存
        for name in (try? fm.contentsOfDirectory(atPath: importDir.path)) ?? [] where name.hasPrefix(".staging-") {
            try? fm.removeItem(at: importDir.appendingPathComponent(name))
        }
        for dir in [importDir, documents] {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        scan()
    }

    private func packs() -> [URL] {
        [importDir, documents].flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".ctpack") && !$0.hasPrefix(".") }
                .sorted()
                .map { dir.appendingPathComponent($0) }
        }
    }

    /// 目录有变化、App 回到前台、还有包在拷入时每秒都来一次。一次只解一个包。
    func scan() {
        guard active == nil else { return }
        rescan?.invalidate()
        rescan = nil
        var stillCopying: [String] = []
        for pack in packs() {
            guard let attrs = try? fm.attributesOfItem(atPath: pack.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value
            else { continue }
            let stamp = "\(size) \(mtime.timeIntervalSince1970)"
            if failed[pack.path] == stamp || deferred.contains(pack.path) { continue }
            if Date().timeIntervalSince(mtime) < 3 {
                stillCopying.append(pack.lastPathComponent)
                continue
            }
            copying = stillCopying
            unpack(pack, size: size, stamp: stamp)
            return
        }
        copying = stillCopying
        if !copying.isEmpty {
            rescan = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.scan() }
        }
        onChange?()
    }

    private func unpack(_ pack: URL, size: UInt64, stamp: String) {
        let name = pack.lastPathComponent
        active = Active(name: name, done: 0, total: size)
        onChange?()
        let documents = documents, staging = importDir.appendingPathComponent(".staging-\(name)")
        let busy = busyDevice
        queue.async { [weak self] in
            let fm = FileManager.default
            let t0 = ProcessInfo.processInfo.systemUptime
            var result: Result
            var logLine: String
            var retry = false
            try? fm.removeItem(at: staging)
            do {
                let free = (try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? Int64.max
                let need = Int64(size) + (500 << 20)
                if free < need {
                    throw EngineError(String(format: String(localized: "空间不够：需要约 %@，手机还剩 %@"),
                                             ImportManager.bytes(need), ImportManager.bytes(free)))
                }
                let devices = try DevicePack.unpack(pack, into: staging) { done in
                    DispatchQueue.main.async { self?.active?.done = done; self?.onChange?() }
                }
                if let busy, devices.contains(busy) {
                    try? fm.removeItem(at: staging)
                    retry = true
                    result = Result(name: name, ok: false, text: String(localized: "包里的系统正在运行，下次打开 App 时再导入"))
                    logLine = "\(name) 推迟：包里的设备正在运行"
                } else {
                    try DevicePack.merge(staging, into: documents)
                    try fm.removeItem(at: pack)
                    let names = devices.compactMap {
                        try? DeviceProfile(base: documents.appendingPathComponent("devices/\($0)", isDirectory: true)).displayName
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - t0
                    result = Result(name: name, ok: true, text: String(
                        format: String(localized: "已导入 %@（用时 %.1f 秒）"),
                        names.isEmpty ? name : names.joined(separator: "、"), seconds))
                    // 和 M1 以来 import.log 的格式一样
                    logLine = String(format: "%@ 解包 %.1f 秒", name, seconds)
                }
            } catch {
                try? fm.removeItem(at: staging)
                result = Result(name: name, ok: false, text: String(format: String(localized: "导入失败：%@"), "\(error)"))
                logLine = "\(name) 失败：\(error)"
            }
            ImportManager.appendLog(logLine, documents: documents)
            DispatchQueue.main.async {
                guard let self else { return }
                if retry {
                    self.deferred.insert(pack.path)
                } else if !result.ok {
                    self.failed[pack.path] = stamp
                }
                self.active = nil
                self.results.insert(result, at: 0)
                self.results = Array(self.results.prefix(5))
                self.scan()
            }
        }
    }

    private static func appendLog(_ line: String, documents: URL) {
        let log = documents.appendingPathComponent("logs/import.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: log, atomically: true, encoding: .utf8)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
