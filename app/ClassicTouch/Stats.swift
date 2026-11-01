// 本进程的 CPU 时间和内存，口径和 M0 的 bench.py 一致：CPU 是所有线程 user+sys 之和，
// 「占一个核的百分比」= CPU 秒 / 墙钟秒 × 100。内存记 phys_footprint 和 os_proc_available_memory()。
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation
import os

struct ProcessSample {
    let wall: Double
    let cpuSeconds: Double
    let footprint: UInt64
    let available: UInt64

    static func now(since start: Double) -> ProcessSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ProcessSample(
            wall: ProcessInfo.processInfo.systemUptime - start,
            cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime),
            footprint: kr == KERN_SUCCESS ? info.phys_footprint : 0,
            available: UInt64(os_proc_available_memory())
        )
    }
}

/// 每秒一行 CSV：墙钟秒、CPU 秒、这一秒的 CPU%、footprint MB、可用内存 MB、帧编号、背光。
final class StatsLog {
    private let handle: FileHandle?
    private var last: ProcessSample?

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("wall_s,cpu_s,cpu_pct,footprint_mb,available_mb,frame_serial,backlight\n".utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// 返回这一秒的 CPU%（占一个核）。
    @discardableResult
    func append(_ s: ProcessSample, serial: UInt64, backlight: Int32) -> Double {
        var pct = 0.0
        if let last, s.wall > last.wall { pct = (s.cpuSeconds - last.cpuSeconds) / (s.wall - last.wall) * 100 }
        last = s
        let line = String(
            format: "%.1f,%.2f,%.0f,%.0f,%.0f,%llu,%d\n", s.wall, s.cpuSeconds, pct,
            Double(s.footprint) / 1_048_576, Double(s.available) / 1_048_576, serial, backlight)
        handle?.write(Data(line.utf8))
        return pct
    }
}

/// 每秒按线程记 CPU（threads.csv：墙钟秒、线程、这一秒占一个核的百分比），只记 1% 以上的。线程名取 pthread 的名字：
/// QEMU 的线程靠 -name debug-threads=on 命名（「CPU 0/TCG」是模拟的 CPU，GL 转发也在它上面），App 起 QEMU 的
/// 线程叫「qemu」（QEMU 的主循环：定时器、显示刷新、发布帧），App 的主线程记成「app-main」。
final class ThreadLog {
    private let handle: FileHandle?
    private var last: [UInt64: Double] = [:]
    private var lastWall: Double?
    private let mainID: UInt64

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("wall_s,thread,cpu_pct\n".utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)   // 在主线程上建
        mainID = id
    }

    func append(wall: Double) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var now: [UInt64: Double] = [:]
        var lines = ""
        for i in 0..<Int(count) {
            var ident = thread_identifier_info_data_t()
            var n = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            let k1 = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(list[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &n)
                }
            }
            var ext = thread_extended_info_data_t()
            var m = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let k2 = withUnsafeMutablePointer(to: &ext) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(m)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &m)
                }
            }
            guard k1 == KERN_SUCCESS, k2 == KERN_SUCCESS else { continue }
            let cpu = Double(ext.pth_user_time + ext.pth_system_time) / 1e9
            now[ident.thread_id] = cpu
            guard let lastWall, wall > lastWall, let before = last[ident.thread_id] else { continue }
            let pct = (cpu - before) / (wall - lastWall) * 100
            guard pct >= 1 else { continue }
            var name = withUnsafeBytes(of: ext.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if ident.thread_id == mainID { name = "app-main" }
            if name.isEmpty { name = "tid-\(ident.thread_id)" }
            lines += String(format: "%.1f,%@,%.0f\n", wall, name.replacingOccurrences(of: ",", with: ";"), pct)
        }
        last = now
        lastWall = wall
        if !lines.isEmpty { handle?.write(Data(lines.utf8)) }
    }
}
