//
//  SeatSessionBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import SeatCore
import SeatInput
import SeatSession
import WindowPlacement

/// A window this process owns, used as the cooperative target of the recovery
/// benchmark: it is adopted, moved out of place, and recovered.
@MainActor
final class BenchTargetView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemIndigo.setFill()
        bounds.fill()
    }
}

/// SeatSessionBench measures the two numbers of spec section 8 that belong to
/// the session layer: what a seat costs while it is doing nothing, and how long
/// it takes to come back from a recoverable Issue.
///
/// ## Why idle is the interesting one
///
/// A seat at rest is a virtual display, an event tap and a watchdog, and the
/// watchdog is the part that costs. Re-reading all eight invariants on a 20 ms
/// timer is fifty wake-ups a second for readings that almost never change, and
/// measured 0,024 % of a core at the median. This benchmark measures the same
/// seat with one heartbeat a second plus the display's own reconfiguration
/// callback, against a budget of
/// 0,1 % at the median, 1 % at p95, five wake-ups a second and 4 MB.
///
/// ## The subtracted control
///
/// The control is the same process, pumping the same event loop, with **no
/// host**: no display, no tap, no heartbeat. Its CPU, its wake-ups and its
/// footprint are what get subtracted, because a benchmark without a subtracted
/// control is not a measurement (`CODE_STYLE.md`).
@MainActor
enum SeatSessionBench {

    static let idleName     = "seat-idle"
    static let recoveryName = "recovery"

    /// The default idle window. Five minutes, which is what the budget says the
    /// median and the p95 have to hold over.
    static let defaultIdleSeconds: Double = 300

    /// One second of samples, which is the unit the CPU budget is written in.
    private static let samplePeriod: Double = 1

    // MARK: seat-idle

    static func runIdle(
        seconds          : Double,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        MonitorBench.pump(0.2)

        guard AXIsProcessTrusted() else {
            print("\(idleName): FAIL, Accessibility is not granted, the fence cannot install")
            return false
        }

        // MARK: the control, first: the same pump with nothing on
        let control = sampleIdle(seconds: min(seconds, 60), clock: clock, label: "control")

        // MARK: the seat
        let host = SeatHost(configuration: SeatHostConfiguration())

        do {
            try MonitorBench.awaiting { try await host.start() }
        } catch {
            print("\(idleName): FAIL, the host did not start: \(error)")
            return false
        }
        guard host.state == .ready else {
            print("\(idleName): FAIL, the host is \(host.state.rawValue)")
            _ = try? MonitorBench.awaiting { await host.stop() }
            return false
        }

        let footprintBefore = readUsage(clock: clock)?.intervalMaxFootprint ?? 0
        let measured = sampleIdle(seconds: seconds, clock: clock, label: "seat")
        let footprintAfter = readUsage(clock: clock)?.intervalMaxFootprint ?? 0

        let report = try? MonitorBench.awaiting { await host.stop() }
        MonitorBench.pump(0.5)

        if let report, !report.displayRemoved {
            print("\(idleName): FAIL, the virtual display was left online")
            return false
        }

        // MARK: the numbers, net of the control
        let netCpu = Sample(
            name      : idleName,
            nanoseconds: measured.cpuPercents.map { max(0, $0 - control.cpuMedianPercent) * 1_000 },
            allocations: 0,
            frees      : 0
        )
        let netWakeups   = max(0, measured.wakeupsPerSecond - control.wakeupsPerSecond)
        let netFootprint = Double(footprintAfter > footprintBefore ? footprintAfter - footprintBefore : 0)

        let medianPercent = netCpu.p50 / 1_000
        let p95Percent    = netCpu.p95 / 1_000

        print("""
            \(idleName): \(Int(seconds)) s, CPU median \(format(medianPercent)) %, \
            p95 \(format(p95Percent)) %, wake-ups \(format(netWakeups))/s, \
            footprint \(format(megabytes(UInt64(netFootprint)))) MB
            control: CPU median \(format(control.cpuMedianPercent)) %, \
            wake-ups \(format(control.wakeupsPerSecond))/s
            """)

        let passed = medianPercent <= Budget.seatIdleMedianCpuPercent
            && p95Percent <= Budget.seatIdleP95CpuPercent
            && netWakeups <= Budget.seatIdleWakeupsPerSecond
            && netFootprint <= Budget.seatIdleFootprintBytes

        var results: [[String: Any]] = [
            [
                "name"  : "\(idleName)-cpu-median",
                "unit"  : "percent",
                "n"     : measured.cpuPercents.count,
                "p50"   : medianPercent,
                "p95"   : p95Percent,
                "mean"  : medianPercent,
                "status": "measured",
                "budget": [
                    "limit" : Budget.seatIdleMedianCpuPercent,
                    "passed": medianPercent <= Budget.seatIdleMedianCpuPercent,
                ],
            ],
            [
                "name"  : "\(idleName)-wakeups",
                "unit"  : "per-second",
                "n"     : measured.cpuPercents.count,
                "p50"   : netWakeups,
                "mean"  : netWakeups,
                "status": "measured",
                "budget": ["limit": Budget.seatIdleWakeupsPerSecond, "passed": netWakeups <= Budget.seatIdleWakeupsPerSecond],
            ],
            [
                "name"  : "\(idleName)-footprint",
                "unit"  : "bytes",
                "n"     : 1,
                "p50"   : netFootprint,
                "mean"  : netFootprint,
                "status": "measured",
                "budget": ["limit": Budget.seatIdleFootprintBytes, "passed": netFootprint <= Budget.seatIdleFootprintBytes],
            ],
        ]

        if let report {
            results.append([
                "name"  : "\(idleName)-teardown",
                "unit"  : "nanoseconds",
                "n"     : 1,
                "p50"   : Double(report.removalNanoseconds),
                "mean"  : Double(report.removalNanoseconds),
                "status": "measured",
            ])
        }

        write(results: results, clock: clock, outputPath: outputPath, baselineDirectory: baselineDirectory)
        print("\(idleName): \(passed ? "PASS" : "FAIL")")
        return passed
    }

    /// One idle window: CPU per second and wake-ups per second, while the event
    /// loop turns exactly as an application's would.
    private static func sampleIdle(
        seconds: Double,
        clock  : Clock,
        label  : String
    ) -> (cpuPercents: [Double], cpuMedianPercent: Double, wakeupsPerSecond: Double) {

        guard var previous = readUsage(clock: clock) else { return ([], 0, 0) }

        let first    = previous
        var percents : [Double] = []
        let started  = Date()

        while Date().timeIntervalSince(started) < seconds {
            MonitorBench.pump(samplePeriod)
            guard let current = readUsage(clock: clock) else { break }
            percents.append(ProcessUsage.cpuPercent(from: previous, to: current, clock: clock))
            previous = current
        }

        let elapsed = Double(previous.wallTicks &- first.wallTicks) * clock.nanosecondsPerTick / 1e9
        let wakeups = Double(
            (previous.pkgIdleWakeups &- first.pkgIdleWakeups)
                + (previous.interruptWakeups &- first.interruptWakeups)
        )
        let sorted = percents.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]

        print("  \(label): \(percents.count) samples, CPU median \(format(median)) %")

        return (percents, median, elapsed > 0 ? wakeups / elapsed : 0)
    }

    // MARK: recovery

    /// How long a seat takes to come back from a recoverable Issue, measured
    /// from the Issue to `ready`.
    ///
    /// The Issue is produced the way it happens: the window is moved off the
    /// place the seat put it, which is what an application that repositions
    /// itself does, and `geometryChanged` is raised on the seat. The recovery
    /// then reads the window server on its own cadence, puts the window back
    /// and waits for two agreeing readings, which is the floor of the number
    /// this reports: two readings at 250 ms is 500 ms before anything else.
    static func runRecovery(
        episodes         : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        MonitorBench.pump(0.2)

        guard AXIsProcessTrusted() else {
            print("\(recoveryName): FAIL, Accessibility is not granted")
            return false
        }

        let window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 420, height: 320),
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        window.title       = "AgentSeatKit recovery bench"
        window.contentView = BenchTargetView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        window.orderFrontRegardless()
        MonitorBench.pump(0.3)

        let windowNumber = Int(window.windowNumber)
        guard let home = WindowServerProbe.geometry(of: windowNumber) else {
            print("\(recoveryName): FAIL, the window server does not know our own window")
            return false
        }

        // A seat gets three recovery episodes and then it is
        // `recoveryExhausted`: that budget is the contract, not a limit of the
        // benchmark, so more samples means more seats. Each group is a fresh
        // host, which costs about 400 ms of setup and is the only honest way to
        // measure the fourth episode of anything.
        var nanoseconds: [UInt64] = []
        var failure: String?

        let groups = max(1, (episodes + RecoveryPolicy.maximumEpisodes - 1)
            / RecoveryPolicy.maximumEpisodes)

        for group in 0..<groups where failure == nil {

            let host = SeatHost(configuration: SeatHostConfiguration())
            do { try MonitorBench.awaiting { try await host.start() } }
            catch {
                failure = "group \(group): the host did not start: \(error)"
                break
            }

            do {
                let seat    = try host.makeSeat()
                let adopted = try MonitorBench.awaiting {
                    try await seat.adopt(home, platform: AppKitPlatform(), title: window.title)
                }

                for episode in 0..<min(RecoveryPolicy.maximumEpisodes, episodes - nanoseconds.count) {

                    // The application moved its own window, which is the Issue.
                    let displaced = CGPoint(
                        x: adopted.reference.frame.minX + 200,
                        y: adopted.reference.frame.minY + 120
                    )
                    try WindowRelocator.move(adopted.reference, to: displaced)
                    MonitorBench.pump(0.3)

                    let start = clock.tick()
                    seat.report([.geometryChanged])

                    let recovered = MonitorBench.pump(
                        until  : { seat.state == .ready || seat.state == .failed },
                        timeout: 10
                    )
                    let elapsed = clock.tick() &- start

                    guard recovered, seat.state == .ready else {
                        failure = "group \(group) episode \(episode) ended in \(seat.state.rawValue)"
                        break
                    }
                    nanoseconds.append(UInt64(Double(elapsed) * clock.nanosecondsPerTick))
                }

                _ = try MonitorBench.awaiting { await seat.release(adopted, .returnToUserSeat) }

            } catch {
                failure = "group \(group): \(error)"
            }

            _ = try? MonitorBench.awaiting { await host.stop() }
            MonitorBench.pump(0.5)
        }

        window.close()

        if let failure {
            print("\(recoveryName): FAIL, \(failure)")
            return false
        }

        let sample = Sample(
            name       : recoveryName,
            // `map(Double.init)` here resolves to `Double(bitPattern:)`, which
            // reinterprets 757 million nanoseconds as 3,7e-315 seconds and
            // reports every recovery as instant. Measured, not guessed.
            nanoseconds: nanoseconds.map { Double($0) },
            allocations: 0,
            frees      : 0
        )
        let passed = sample.p95 <= Budget.recoveryNanosecondsP95

        print("""
            \(recoveryName): \(nanoseconds.count) episodes, p50 \
            \(Int(sample.p50 / 1_000_000)) ms, p95 \(Int(sample.p95 / 1_000_000)) ms, \
            budget \(Int(Budget.recoveryNanosecondsP95 / 1_000_000)) ms
            """)

        write(
            results          : [sample.json(budgetLimit: Budget.recoveryNanosecondsP95, passed: passed)],
            clock            : clock,
            outputPath       : outputPath,
            baselineDirectory: baselineDirectory
        )
        print("\(recoveryName): \(passed ? "PASS" : "FAIL")")
        return passed
    }

    // MARK: The report

    private static func write(
        results          : [[String: Any]],
        clock            : Clock,
        outputPath       : String?,
        baselineDirectory: String?
    ) {
        let object: [String: Any] = [
            "schema_version": 1,
            "provenance"    : provenance(clock: clock),
            "results"       : results,
        ]
        if let outputPath { writeJSON(object, to: outputPath) }
        if let baselineDirectory {
            let path = baselinePath(in: baselineDirectory)
            if readJSON(at: path) == nil {
                writeJSON(object, to: path)
                print("no-baseline: written to \(path)")
            }
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
