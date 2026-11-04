// Unpacks the .ctpack made by scripts/ios/pack-device.py (the format is described in that script). Files are written
// extent by extent with pwrite and holes are skipped, so the unpacked NAND stays sparse. ImportManager decides when to
// unpack, where to and how to report progress: it unpacks into a staging folder and merges into Documents only after a
// complete unpack, so a failure or a killed app never leaves half a device behind.
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum DevicePack {
    /// Unpacks under root (paths are relative to root); progress gets the number of bytes read. Returns the device ids
    /// in the pack (the devices/<id>/ level). Does not delete the pack.
    static func unpack(_ pack: URL, into root: URL, progress: @escaping (UInt64) -> Void) throws -> [String] {
        guard let input = InputStream(url: pack) else { throw EngineError("Cannot open \(pack.lastPathComponent)") }
        input.open()
        defer { input.close() }
        var reader = Reader(input: input, progress: progress)
        guard try reader.bytes(8) == Array("CTPACK1\n".utf8) else { throw EngineError("\(pack.lastPathComponent) is not a ctpack") }
        let rootPath = root.standardizedFileURL.path
        var devices: [String] = []
        while true {
            let type = try reader.u8()
            if type == 0 { break }
            let pathBytes = try reader.bytes(Int(try reader.u16()))
            guard let rel = String(bytes: pathBytes, encoding: .utf8), !rel.contains("..") else {
                throw EngineError("Bad path in the pack")
            }
            let target = root.appendingPathComponent(rel)
            guard target.standardizedFileURL.path.hasPrefix(rootPath) else { throw EngineError("Path in the pack escapes its folder: \(rel)") }
            let parts = rel.split(separator: "/")
            if parts.count >= 2, parts[0] == "devices", !devices.contains(String(parts[1])) { devices.append(String(parts[1])) }
            let mode = mode_t(try reader.u32())
            if type == 1 {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = try reader.u64()
            let count = try reader.u32()
            try? FileManager.default.removeItem(at: target)
            let fd = open(target.path, O_WRONLY | O_CREAT | O_TRUNC, mode)
            guard fd >= 0 else { throw EngineError("Cannot write \(rel): errno \(errno)") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(size)) == 0 else { throw EngineError("ftruncate \(rel): errno \(errno)") }
            for _ in 0..<count {
                var offset = try reader.u64()
                var left = try reader.u64()
                while left > 0 {
                    let chunk = try reader.bytes(Int(min(left, 8 << 20)))
                    let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk.count, off_t(offset)) }
                    guard written == chunk.count else { throw EngineError("Writing \(rel) failed: errno \(errno)") }
                    offset += UInt64(chunk.count)
                    left -= UInt64(chunk.count)
                }
            }
        }
        return devices
    }

    /// Moves the staged files one by one to the same place in documents (replacing files of the same name); other files
    /// already in those folders (such as a device's state/) stay. A move on the same volume is only a rename, a matter of seconds.
    static func merge(_ staging: URL, into documents: URL) throws {
        let fm = FileManager.default
        // List everything first, then move: moving files out while reading the directory can make readdir skip entries
        for rel in try fm.subpathsOfDirectory(atPath: staging.path) {
            let source = staging.appendingPathComponent(rel)
            let target = documents.appendingPathComponent(rel)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                // A device folder cloned in from the host may be read-only (M0's device folders are 0555); re-importing the same device has to be able to write first
                let parent = target.deletingLastPathComponent().path
                if !fm.isWritableFile(atPath: parent) { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: source, to: target)
            }
        }
        try? fm.removeItem(at: staging)
    }

    private struct Reader {
        let input: InputStream
        let progress: (UInt64) -> Void
        private var read: UInt64 = 0
        private var reported: UInt64 = 0

        init(input: InputStream, progress: @escaping (UInt64) -> Void) {
            self.input = input
            self.progress = progress
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: n)
            var got = 0
            while got < n {
                let r = out.withUnsafeMutableBufferPointer { input.read($0.baseAddress! + got, maxLength: n - got) }
                guard r > 0 else { throw EngineError("The ctpack ended early") }
                got += r
            }
            read += UInt64(n)
            if read - reported >= 16 << 20 {
                reported = read
                progress(read)
            }
            return out
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { try le(2) }
        mutating func u32() throws -> UInt32 { try le(4) }
        mutating func u64() throws -> UInt64 { try le(8) }

        private mutating func le<T: FixedWidthInteger>(_ n: Int) throws -> T {
            try bytes(n).enumerated().reduce(T(0)) { $0 | T($1.element) << (8 * $1.offset) }
        }
    }
}
