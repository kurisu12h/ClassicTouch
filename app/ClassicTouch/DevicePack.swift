// 解开 scripts/ios/pack-device.py 打的 .ctpack（格式见那个脚本）。文件按区段 pwrite，空洞不写，所以解出来的 NAND
// 还是稀疏文件。什么时候解、解到哪、进度怎么报由 ImportManager 管：先解到暂存目录，完整解完才并进 Documents，
// 中途失败或 App 被杀都不会留下半台设备。
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum DevicePack {
    /// 解到 root 下（路径相对 root），progress 收到已读的字节数。返回包里的设备 id（devices/<id>/ 这一级）。
    /// 不删包。
    static func unpack(_ pack: URL, into root: URL, progress: @escaping (UInt64) -> Void) throws -> [String] {
        guard let input = InputStream(url: pack) else { throw EngineError("打不开 \(pack.lastPathComponent)") }
        input.open()
        defer { input.close() }
        var reader = Reader(input: input, progress: progress)
        guard try reader.bytes(8) == Array("CTPACK1\n".utf8) else { throw EngineError("\(pack.lastPathComponent) 不是 ctpack") }
        let rootPath = root.standardizedFileURL.path
        var devices: [String] = []
        while true {
            let type = try reader.u8()
            if type == 0 { break }
            let pathBytes = try reader.bytes(Int(try reader.u16()))
            guard let rel = String(bytes: pathBytes, encoding: .utf8), !rel.contains("..") else {
                throw EngineError("包里的路径不对")
            }
            let target = root.appendingPathComponent(rel)
            guard target.standardizedFileURL.path.hasPrefix(rootPath) else { throw EngineError("包里的路径越界：\(rel)") }
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
            guard fd >= 0 else { throw EngineError("写不了 \(rel)：errno \(errno)") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(size)) == 0 else { throw EngineError("ftruncate \(rel)：errno \(errno)") }
            for _ in 0..<count {
                var offset = try reader.u64()
                var left = try reader.u64()
                while left > 0 {
                    let chunk = try reader.bytes(Int(min(left, 8 << 20)))
                    let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk.count, off_t(offset)) }
                    guard written == chunk.count else { throw EngineError("写 \(rel) 失败：errno \(errno)") }
                    offset += UInt64(chunk.count)
                    left -= UInt64(chunk.count)
                }
            }
        }
        return devices
    }

    /// 把暂存目录里的文件逐个挪进 documents 的同一位置（同名的替换），目录里原有的其他文件（比如设备的 state/）不动。
    /// 同一个卷上挪动只是改名，几秒钟的事。
    static func merge(_ staging: URL, into documents: URL) throws {
        let fm = FileManager.default
        // 先列全再挪：边读目录边把文件挪走，readdir 可能漏项
        for rel in try fm.subpathsOfDirectory(atPath: staging.path) {
            let source = staging.appendingPathComponent(rel)
            let target = documents.appendingPathComponent(rel)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                // 宿主克隆进来的设备目录可能是只读的（M0 的设备目录是 0555），重新导入同一台时要先能写
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
                guard r > 0 else { throw EngineError("ctpack 提前结束") }
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
