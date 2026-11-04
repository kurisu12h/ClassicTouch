// Imports device packs without scripts: the user puts a .ctpack into Documents/import/ with Finder (file sharing) or the
// Files app (the Documents root works too). The app watches both folders; once a pack's modification time and size have
// not changed for 3 seconds (taken as fully copied), it unpacks it into import/.staging-<pack name>/, and only after a
// complete unpack merges it into Documents and deletes the pack. The home page shows copying, unpack progress and the
// result; results are also appended to logs/import.log (scripts/ios/device-boot.sh fetches it).
// The scripts' old way still works: the host copies a pack into import/ and then launches the app, which unpacks it right
// away, and test entry points boot only after the import is done (RootViewController).
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
    /// Names of packs still being copied (modified less than 3 seconds ago)
    private(set) var copying: [String] = []
    /// Recent results, newest first
    private(set) var results: [Result] = []
    var onChange: (() -> Void)?
    /// The running device. A pack that contains it is not merged (that would replace files QEMU has open) and waits for the next app launch
    var busyDevice: String?

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "import", qos: .userInitiated)
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescan: Timer?
    /// Packs that failed (path → size and modification time) are not retried while unchanged; one that failed because it was read mid-copy is retried once the copy finishes and its size changes
    private var failed: [String: String] = [:]
    private var deferred: Set<String> = []
    /// The size last seen for each pack and since when it has had that size. devicectl copy first creates an empty file,
    /// starts writing about 5 seconds later, and when done sets the modification time back to the original file's on the
    /// Mac, so looking only at the modification time would unpack an empty or partial pack
    /// (docs/reports/ios-device-14pro.md, section 7)
    private var sizes: [String: (size: UInt64, since: Date)] = [:]

    var importDir: URL { documents.appendingPathComponent("import", isDirectory: true) }
    var idle: Bool { active == nil && copying.isEmpty }

    init(documents: URL) {
        self.documents = documents
    }

    func start() {
        try? fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        // Staging left by an unpack that was killed halfway last time
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

    /// Runs when a folder changes, when the app comes to the foreground, and every second while packs are being copied. Unpacks one pack at a time.
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
            let now = Date()
            if sizes[pack.path]?.size != size { sizes[pack.path] = (size, now) }
            if size == 0 || now.timeIntervalSince(mtime) < 3 || now.timeIntervalSince(sizes[pack.path]?.since ?? now) < 3 {
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
        } else if failed.keys.contains(where: { fm.fileExists(atPath: $0) }) {
            // A pack that failed to unpack is still there: a growing file triggers no folder event, so look again in a while and retry once the copy finishes (the size changes)
            rescan = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.scan() }
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
                    throw EngineError(
                        "Not enough space: needs about \(ImportManager.bytes(need)), only \(ImportManager.bytes(free)) left on the phone")
                }
                let devices = try DevicePack.unpack(pack, into: staging) { done in
                    DispatchQueue.main.async { self?.active?.done = done; self?.onChange?() }
                }
                if let busy, devices.contains(busy) {
                    try? fm.removeItem(at: staging)
                    retry = true
                    result = Result(name: name, ok: false,
                                    text: String(localized: "A system in this pack is running; it will be imported the next time the app opens"))
                    logLine = "\(name) deferred: a device in the pack is running"
                } else {
                    try DevicePack.merge(staging, into: documents)
                    try fm.removeItem(at: pack)
                    let names = devices.compactMap {
                        try? DeviceProfile(base: documents.appendingPathComponent("devices/\($0)", isDirectory: true)).displayName
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - t0
                    result = Result(name: name, ok: true, text: String(
                        format: String(localized: "Imported %@ (%.1f s)"),
                        names.isEmpty ? name : names.listed, seconds))
                    // "<pack> unpacked in <seconds> s" (scripts read import.log)
                    logLine = String(format: "%@ unpacked in %.1f s", name, seconds)
                }
            } catch {
                try? fm.removeItem(at: staging)
                result = Result(name: name, ok: false, text: String(format: String(localized: "Import failed: %@"), "\(error)"))
                logLine = "\(name) failed: \(error.logText)"
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
