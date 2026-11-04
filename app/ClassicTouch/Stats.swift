// This process's CPU time and memory, measured the same way as M0's bench.py: CPU is user+sys summed over all threads,
// and "percent of one core" = CPU seconds / wall-clock seconds × 100. Memory records phys_footprint and
// os_proc_available_memory().
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

/// One CSV line per second: wall-clock seconds, CPU seconds, this second's CPU%, footprint MB, available memory MB, frame serial, backlight.
final class StatsLog {
    private let handle: FileHandle?
    private var last: ProcessSample?

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("wall_s,cpu_s,cpu_pct,footprint_mb,available_mb,frame_serial,backlight\n".utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// Returns this second's CPU% (of one core).
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

/// CPU per thread every second (threads.csv: wall-clock seconds, thread, percent of one core this second), only threads
/// at 1% or more. Thread names are the pthread names: QEMU names its threads with -name debug-threads=on ("CPU 0/TCG" is
/// the emulated CPU, and GL forwarding runs on it too), the thread the app starts QEMU on is "qemu" (QEMU's main loop:
/// timers, display refresh, frame publishing), and the app's main thread is recorded as "app-main".
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
        pthread_threadid_np(nil, &id)   // created on the main thread
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
