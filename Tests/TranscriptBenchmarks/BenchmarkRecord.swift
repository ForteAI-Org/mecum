//
//  BenchmarkRecord.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Darwin
import Foundation

/// BenchmarkRecord prints what a benchmark measured beside what it ran on:
/// hardware, operating system, build configuration and dataset (§20.2). A
/// number without those is not reported.
///
/// Lines start with `bench:` so a run's output can be filtered to its table.
/// It asserts nothing: the targets are initial project criteria, and a row
/// that misses one says so in its note rather than failing the run.
enum BenchmarkRecord {

    /// Median, p95 and maximum of a set of durations or sizes, nearest rank.
    struct Samples: Sendable {
        let values: [Double]

        init(_ values: [Double]) { self.values = values.sorted() }

        func percentile(_ fraction: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let rank = Int((fraction * Double(values.count)).rounded(.up)) - 1
            return values[min(max(rank, 0), values.count - 1)]
        }

        var median : Double { percentile(0.5) }
        var p95    : Double { percentile(0.95) }
        var maximum: Double { values.last ?? .nan }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func header(dataset: String) {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("bench: hardware \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), "
              + "\(ProcessInfo.processInfo.activeProcessorCount) cores, "
              + "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        print("bench: system \(ProcessInfo.processInfo.operatingSystemVersionString), build \(build)")
        print("bench: dataset \(dataset)")
    }

    /// One table row: a name, its samples in `unit`, the target and a note.
    static func row(_ name: String, _ samples: Samples, unit: String, target: String = "", note: String = "") {
        let figures = String(format: "median %.2f, p95 %.2f, max %.2f %@ (n %d)",
                             samples.median, samples.p95, samples.maximum, unit, samples.values.count)
        print("bench: \(name) | \(figures) | \(target) | \(note)")
    }

    static func line(_ text: String) { print("bench: \(text)") }

    /// The process's physical footprint in megabytes, what Activity Monitor
    /// calls Memory. Nil when the kernel refuses the read.
    static func footprintMB() -> Double? {
        var info   = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_phys_footprint) / 1_048_576
    }

    /// Bytes the allocator has handed out and not had back, in megabytes: the
    /// live heap, without the freed pages it keeps that `footprintMB` counts.
    static func liveHeapMB() -> Double {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Double(statistics.size_in_use) / 1_048_576
    }

    /// Asks every malloc zone to return its free pages, so a footprint read
    /// after it shows what is still in use.
    static func relieveAllocator() {
        malloc_zone_pressure_relief(nil, 0)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
