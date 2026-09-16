//
//  Measurement.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AllocationCounter
import Darwin
import Foundation

/// Clock is the timer every latency in this driver is taken with:
/// `mach_absolute_time` and the process timebase, which is the only reading
/// that costs nothing and has no allocation of its own. The
/// resolution on the reference machine is 41.67 ns, so a single call to
/// anything cheap reads as 0 or one tick, and that is a property of the clock
/// rather than of the code.
nonisolated struct Clock {

    let nanosecondsPerTick: Double
    let numerator         : UInt32
    let denominator       : UInt32

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        numerator          = timebase.numer
        denominator        = timebase.denom
    }

    @inline(__always)
    func tick() -> UInt64 { mach_absolute_time() }
}

/// Sample is one measured scenario reduced to the fields the Reix JSON schema
/// asks for, plus the allocation count, which is the field the
/// fence's budget is actually about.
nonisolated struct Sample {

    let name       : String
    let iterations : Int
    let minimum    : Double
    let p50        : Double
    let p95        : Double
    let p99        : Double
    let maximum    : Double
    let mean       : Double
    let allocations: UInt64
    let frees      : UInt64

    var allocationsPerCall: Double {
        iterations == 0 ? 0 : Double(allocations) / Double(iterations)
    }

    init(name: String, nanoseconds: [Double], allocations: UInt64, frees: UInt64) {
        let sorted = nanoseconds.sorted()
        func rank(_ percentile: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[max(0, Int(ceil(percentile * Double(sorted.count))) - 1)]
        }

        self.name        = name
        self.iterations  = sorted.count
        self.minimum     = sorted.first ?? 0
        self.p50         = rank(0.50)
        self.p95         = rank(0.95)
        self.p99         = rank(0.99)
        self.maximum     = sorted.last ?? 0
        self.mean        = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        self.allocations = allocations
        self.frees       = frees
    }

    var line: String {
        String(
            format: "%-42@ n=%7d  p50 %8.0f  p95 %8.0f  p99 %8.0f  max %9.0f ns  alloc %6llu (%.3f/call)",
            name, iterations, p50, p95, p99, maximum, allocations, allocationsPerCall
        )
    }

    func json(budgetLimit: Double?, passed: Bool?) -> [String: Any] {
        var object: [String: Any] = [
            "name"                 : name,
            "unit"                 : "ns",
            "n"                    : iterations,
            "min"                  : minimum,
            "p50"                  : p50,
            "p95"                  : p95,
            "p99"                  : p99,
            "max"                  : maximum,
            "mean"                 : mean,
            "allocations_total"    : allocations,
            "allocations_per_call" : allocationsPerCall,
            "frees_total"          : frees,
            "status"               : "measured",
        ]
        if let budgetLimit, let passed {
            object["budget"] = ["limit": budgetLimit, "passed": passed]
        }
        return object
    }
}

/// measure runs one scenario: warm up outside the count, then time every
/// iteration with the `malloc_logger` hook installed so a single hidden
/// allocation is visible as a non zero total.
///
/// The samples array is allocated before the hook goes on, and the timings are
/// kept as raw ticks and converted afterwards, so the measuring loop itself
/// allocates nothing and cannot be mistaken for the code under test.
nonisolated func measure(
    _ name    : String,
    iterations: Int,
    warmUp    : Int = 0,
    body      : () -> Void
) -> Sample {

    for _ in 0..<warmUp { body() }

    var ticks = [UInt64](repeating: 0, count: iterations)

    agentseat_bench_hook_install()
    let allocationsBefore = agentseat_bench_allocations()
    let freesBefore       = agentseat_bench_frees()

    let clock = Clock()
    for index in 0..<iterations {
        let start = clock.tick()
        body()
        ticks[index] = clock.tick() &- start
    }

    let allocations = agentseat_bench_allocations() - allocationsBefore
    let frees       = agentseat_bench_frees() - freesBefore
    agentseat_bench_hook_remove()

    return Sample(
        name       : name,
        nanoseconds: ticks.map { Double($0) * clock.nanosecondsPerTick },
        allocations: allocations,
        frees      : frees
    )
}

nonisolated func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    if let terminator = buffer.firstIndex(of: 0) { buffer.removeSubrange(terminator...) }
    return String(decoding: buffer, as: UTF8.self)
}

nonisolated func sysctlInteger(_ name: String) -> Int64 {
    var value = Int64(0)
    var size  = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return -1 }
    return value
}

/// The one minute load average when this process first looked, which is the
/// start of the run: every driver builds its `provenance` before it measures
/// anything, and building it is what reads this.
nonisolated let startingLoadAverage: Double = {
    var load = [Double](repeating: 0, count: 3)
    return getloadavg(&load, 3) > 0 ? load[0] : 0
}()

/// Whether a comparison against the saved baseline means anything on this run.
///
/// A load average above half the cores at the start makes a run inconclusive,
/// and an inconclusive run is never a pass. The split matters: a **budget** is
/// an absolute property of the design and stays gated whatever else the machine
/// was doing, while a **regression against a baseline** compares two machines'
/// spare capacity, so on a busy one it measures the neighbours. Measured: a
/// preparation cycle at 262 us p95 against a 233 us baseline, and a display
/// setup at 402 ms p50 against 358, both inside their budgets with two builds
/// and a browser running alongside.
///
/// Reported and not gated, so the number is still in the log and in the JSON.
/// The other half of the rule, the median of three consecutive runs, is the
/// caller's: nothing here runs itself three times.
nonisolated func loadAllowsBaselineComparison() -> Bool {
    startingLoadAverage <= Double(sysctlInteger("hw.ncpu")) / 2
}

/// The line that stands in for a FAIL when the machine was too busy to compare.
nonisolated func reportInconclusive(_ name: String, measured: String, baseline: String) {
    print(String(
        format: "INCONCLUSIVE %@: %@ against a baseline of %@, over the tolerance, but the load "
            + "average was %.2f on %d cores at the start of the run",
        name, measured, baseline, startingLoadAverage, sysctlInteger("hw.ncpu")
    ))
}

/// The provenance block of the Reix schema: everything needed to know which
/// machine, build and load a number came from, because a latency without its
/// provenance cannot be compared to anything.
nonisolated func provenance(clock: Clock) -> [String: Any] {
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    load[0] = startingLoadAverage

    return [
        "date"                     : ISO8601DateFormatter().string(from: Date()),
        "kern.osversion"           : sysctlString("kern.osversion"),
        "kern.osproductversion"    : sysctlString("kern.osproductversion"),
        "machdep.cpu.brand_string" : sysctlString("machdep.cpu.brand_string"),
        "hw.model"                 : sysctlString("hw.model"),
        "hw.ncpu"                  : sysctlInteger("hw.ncpu"),
        "hw.memsize"               : sysctlInteger("hw.memsize"),
        "timebase_numer"           : clock.numerator,
        "timebase_denom"           : clock.denominator,
        "loadavg"                  : load,
        "configuration"            : buildConfiguration,
    ]
}

/// Which configuration this driver was compiled in. A latency measured in a
/// debug build is not a measurement, so the JSON says so out loud.
nonisolated var buildConfiguration: String {
    #if DEBUG
    "debug"
    #else
    "release"
    #endif
}

/// The baseline path: one file per build and hardware pair.
nonisolated func baselinePath(in directory: String) -> String {
    let build = sysctlString("kern.osversion")
    let model = sysctlString("hw.model")
    return directory + "/" + build + "-" + model + ".json"
}

nonisolated func writeJSON(_ object: [String: Any], to path: String) {
    do {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at                         : url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options       : [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
        print("json -> \(path)")
    } catch {
        print("json write failed: \(error)")
    }
}

/// Adds a report's **new** rows to the shared baseline file and leaves the rows
/// that are already in it alone.
///
/// Two rules meet here. One file per build and hardware pair holds every
/// benchmark, so a driver that wrote its own rows over the whole file would
/// erase every other benchmark's baseline and turn the next run of those into a
/// silent no-baseline. And a baseline is regenerated by hand, never by a run
/// that happened to be fast: a driver that saved its own numbers on every pass
/// ratchets the baseline down to its best run and then fails the next one
/// against it. Measured: a clamp p95 of 9542 ns saved over a baseline of 11 000
/// failed the following run at 11 250 ns, a number the original baseline
/// accepted with room to spare.
///
/// To regenerate a row on purpose, delete it from the file and run the driver.
nonisolated func mergeIntoBaseline(_ report: [String: Any], at path: String) {
    guard var existing = readJSON(at: path),
          let rows = existing["results"] as? [[String: Any]],
          let fresh = report["results"] as? [[String: Any]]
    else {
        writeJSON(report, to: path)
        return
    }
    let known = Set(rows.compactMap { $0["name"] as? String })
    let added = fresh.filter { !known.contains($0["name"] as? String ?? "") }
    guard !added.isEmpty else { return }

    existing["results"]   = rows + added
    existing["benchmark"] = "baseline"
    writeJSON(existing, to: path)
    print("baseline: added " + added.compactMap { $0["name"] as? String }.joined(separator: ", ")
        + "; the rows already there are regenerated by hand, never by a run")
}

nonisolated func readJSON(at path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// ProcessUsage is one reading of what this process costs, from
/// `proc_pid_rusage`: 375 ns per sample, and the only source that reports CPU
/// and memory for the whole process rather than for one call (research note
/// 05).
///
/// `ri_user_time` and `ri_system_time` are **mach ticks**, not nanoseconds
/// (XNU `task.c`), which is the mistake that makes a CPU percentage come out
/// off by the timebase ratio.
nonisolated struct ProcessUsage {

    let wallTicks           : UInt64
    let userSeconds         : Double
    let systemSeconds       : Double
    let physFootprint       : UInt64
    let intervalMaxFootprint: UInt64
    let residentSize        : UInt64
    let pkgIdleWakeups      : UInt64
    let interruptWakeups    : UInt64

    /// Percent of one core between two readings.
    static func cpuPercent(from previous: ProcessUsage, to current: ProcessUsage, clock: Clock) -> Double {
        let wall = Double(current.wallTicks &- previous.wallTicks) * clock.nanosecondsPerTick / 1e9
        guard wall > 0 else { return 0 }
        let cpu = (current.userSeconds - previous.userSeconds)
            + (current.systemSeconds - previous.systemSeconds)
        return cpu / wall * 100
    }
}

nonisolated func readUsage(clock: Clock) -> ProcessUsage? {
    var info = rusage_info_v6()
    // libproc passes the buffer itself as the address the kernel fills, so the
    // struct pointer is reinterpreted as `rusage_info_t*` and never wrapped.
    let ok = withUnsafeMutablePointer(to: &info) { pointer -> Bool in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound) == 0
        }
    }
    guard ok else { return nil }
    return ProcessUsage(
        wallTicks           : mach_absolute_time(),
        userSeconds         : Double(info.ri_user_time) * clock.nanosecondsPerTick / 1e9,
        systemSeconds       : Double(info.ri_system_time) * clock.nanosecondsPerTick / 1e9,
        physFootprint       : info.ri_phys_footprint,
        intervalMaxFootprint: info.ri_interval_max_phys_footprint,
        residentSize        : info.ri_resident_size,
        pkgIdleWakeups      : info.ri_pkg_idle_wkups,
        interruptWakeups    : info.ri_interrupt_wkups
    )
}

nonisolated func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
