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
/// control is not a measurement (`CodeStyle.md`).
@MainActor
enum SeatSessionBench {

    static let idleName         = "seat-idle"
    static let recoveryName     = "recovery"
    static let windowWatchName  = "window-watch"
    static let focusRefreshName = "focus-refresh"

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

    // MARK: window-watch

    /// The default window each half of the pair is sampled over. A minute is
    /// sixty CPU samples and sixty heartbeats, which is enough for a median and
    /// a p95 of a cost this small, and the pair costs two minutes of the
    /// person's machine rather than ten.
    static let defaultWindowWatchSeconds: Double = 60

    /// What the window watch costs while nothing is happening, against the same
    /// seat with the watch off.
    ///
    /// The control is the whole measurement. Both halves bring up a virtual
    /// display, install the fence, adopt this process's own window and beat the
    /// same heartbeat for the same length of time; the only difference is
    /// `followsNewWindows`. So what is reported is the pass and not the seat,
    /// which is the rule a benchmark without a subtracted control breaks.
    ///
    /// Three numbers come out and the ticket asks for all three: the CPU, the
    /// wake-ups, and how many window server passes the watch actually made. The
    /// last one is not derivable from the first two, and a pass that got cheap
    /// by looking less often would otherwise read as an improvement.
    static func runWindowWatch(
        seconds          : Double,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        MonitorBench.pump(0.2)

        guard AXIsProcessTrusted() else {
            print("\(windowWatchName): FAIL, Accessibility is not granted, nothing can be adopted")
            return false
        }

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 320),
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        window.title       = "AgentSeatKit window watch bench"
        window.contentView = BenchTargetView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        window.orderFrontRegardless()
        MonitorBench.pump(0.3)
        defer { window.close() }

        guard let home = WindowServerProbe.geometry(of: Int(window.windowNumber)) else {
            print("\(windowWatchName): FAIL, the window server does not know our own window")
            return false
        }

        guard let control = sampleSeat(
            configuration: SeatHostConfiguration(followsNewWindows: false),
            benchmark    : windowWatchName,
            label        : "watch off",
            home         : home,
            seconds      : seconds,
            clock        : clock
        ) else { return false }

        guard let watched = sampleSeat(
            configuration: SeatHostConfiguration(followsNewWindows: true),
            benchmark    : windowWatchName,
            label        : "watch on",
            home         : home,
            seconds      : seconds,
            clock        : clock
        ) else { return false }

        let netCpu = Sample(
            name       : windowWatchName,
            nanoseconds: watched.cpuPercents.map {
                max(0, $0 - control.cpuMedianPercent) * 1_000
            },
            allocations: 0,
            frees      : 0
        )
        let medianPercent = netCpu.p50 / 1_000
        let p95Percent    = netCpu.p95 / 1_000
        let netWakeups    = max(0, watched.wakeupsPerSecond - control.wakeupsPerSecond)

        print("""
            \(windowWatchName): \(Int(seconds)) s a side, net CPU median \
            \(format(medianPercent)) %, p95 \(format(p95Percent)) %, \
            wake-ups \(format(netWakeups))/s, scans \(format(watched.scansPerSecond))/s
            watch off: CPU median \(format(control.cpuMedianPercent)) %, \
            wake-ups \(format(control.wakeupsPerSecond))/s, \
            scans \(format(control.scansPerSecond))/s
            """)

        let passed = medianPercent <= Budget.windowWatchMedianCpuPercent
            && p95Percent <= Budget.windowWatchP95CpuPercent
            && netWakeups <= Budget.windowWatchWakeupsPerSecond
            && watched.scansPerSecond <= Budget.windowWatchScansPerSecond
            && control.scansPerSecond == 0

        let results: [[String: Any]] = [
            [
                "name"  : "\(windowWatchName)-cpu-median",
                "unit"  : "percent",
                "n"     : watched.cpuPercents.count,
                "p50"   : medianPercent,
                "p95"   : p95Percent,
                "mean"  : medianPercent,
                "status": "measured",
                "budget": [
                    "limit" : Budget.windowWatchMedianCpuPercent,
                    "passed": medianPercent <= Budget.windowWatchMedianCpuPercent,
                ],
            ],
            [
                "name"  : "\(windowWatchName)-wakeups",
                "unit"  : "per-second",
                "n"     : watched.cpuPercents.count,
                "p50"   : netWakeups,
                "mean"  : netWakeups,
                "status": "measured",
                "budget": [
                    "limit" : Budget.windowWatchWakeupsPerSecond,
                    "passed": netWakeups <= Budget.windowWatchWakeupsPerSecond,
                ],
            ],
            [
                "name"  : "\(windowWatchName)-scans",
                "unit"  : "per-second",
                "n"     : watched.cpuPercents.count,
                "p50"   : watched.scansPerSecond,
                "mean"  : watched.scansPerSecond,
                "status": "measured",
                "budget": [
                    "limit" : Budget.windowWatchScansPerSecond,
                    "passed": watched.scansPerSecond <= Budget.windowWatchScansPerSecond,
                ],
            ],
            [
                "name"  : "\(windowWatchName)-control-cpu-median",
                "unit"  : "percent",
                "n"     : control.cpuPercents.count,
                "p50"   : control.cpuMedianPercent,
                "mean"  : control.cpuMedianPercent,
                "status": "measured",
            ],
        ]

        write(
            results          : results,
            clock            : clock,
            outputPath       : outputPath,
            baselineDirectory: baselineDirectory
        )
        print("\(windowWatchName): \(passed ? "PASS" : "FAIL")")
        return passed
    }

    /// One half of a pair: a whole seat holding this process's own window,
    /// sampled while nothing happens. Nil is a setup that failed, which is a
    /// failed benchmark and never a zero.
    ///
    /// The configuration is the caller's because the pairs this serves differ
    /// in exactly one switch and share everything else. `inspect` runs once
    /// with the window adopted and once when the sampling ends, outside the
    /// sampled interval on both sides, and a sentence back from it is a half
    /// that did not measure what it was asked to.
    private static func sampleSeat(
        configuration: SeatHostConfiguration,
        benchmark    : String,
        label        : String,
        home         : WindowReference,
        seconds      : Double,
        clock        : Clock,
        inspect      : ((SeatHost) -> String?)? = nil
    ) -> (
        cpuPercents     : [Double],
        cpuMedianPercent: Double,
        wakeupsPerSecond: Double,
        scansPerSecond  : Double
    )? {

        let host = SeatHost(configuration: configuration)

        do { try MonitorBench.awaiting { try await host.start() } }
        catch {
            print("\(benchmark): FAIL, \(label): the host did not start: \(error)")
            return nil
        }

        var scans   = 0
        var samples : (cpuPercents: [Double], cpuMedianPercent: Double, wakeupsPerSecond: Double)?
        var failure : String?

        func inspected() -> String? { inspect?(host).map { "\(label): \($0)" } }

        do {
            let seat    = try host.makeSeat()
            let adopted = try MonitorBench.awaiting {
                try await seat.adopt(home, platform: AppKitPlatform(), title: "")
            }
            failure = inspected()
            if failure == nil {
                let before = seat.windowFollowScanCount
                samples = sampleIdle(seconds: seconds, clock: clock, label: label)
                scans   = seat.windowFollowScanCount - before
                failure = inspected()
            }
            _ = try MonitorBench.awaiting { await seat.release(adopted, .returnToUserSeat) }
        } catch {
            failure = "\(label): \(error)"
        }

        _ = try? MonitorBench.awaiting { await host.stop() }
        MonitorBench.pump(0.5)

        if let failure {
            print("\(benchmark): FAIL, \(failure)")
            return nil
        }
        guard let samples, !samples.cpuPercents.isEmpty else {
            print("\(benchmark): FAIL, \(label): no usable sample")
            return nil
        }

        let elapsed = Double(samples.cpuPercents.count)
        return (
            samples.cpuPercents,
            samples.cpuMedianPercent,
            samples.wakeupsPerSecond,
            elapsed > 0 ? Double(scans) / elapsed : 0
        )
    }

    // MARK: focus-refresh

    /// The default window each half of the focus pair is sampled over. The
    /// refresh rides the heartbeat that already beats once a second, so a
    /// minute is sixty of them, and the pair costs two minutes of the person's
    /// machine rather than ten.
    static let defaultFocusRefreshSeconds: Double = 60

    /// What the focus recovery's preparation refresh costs a seat that holds a
    /// window and does nothing else, **net of the same seat with
    /// `restoresUserFocus` off**.
    ///
    /// ## The pair
    ///
    /// The window watch's shape, for the same reason: both halves bring up a
    /// virtual display, install the fence, adopt this process's own window and
    /// beat the same heartbeat for the same length of time, and the only
    /// difference is the one switch. `allowUnvalidatedFocusRecovery` travels
    /// with it because the activation export is deliberately absent from
    /// `validated-builds.json`, and the facility refuses without that opt-in;
    /// it relaxes no symbol, record or Accessibility check.
    /// `followsNewWindows` is off in both halves, so the only refresh measured
    /// here is the heartbeat's: the window-created wake-up is installed by the
    /// watch, and at rest nothing creates a window anyway.
    ///
    /// ## What the number covers, and what it does not
    ///
    /// A refresh with no destination returns before it resolves an owner and
    /// before it enumerates the window server, so a seat with nowhere to go
    /// would report a cost of zero for work that costs something. This reads
    /// the destination the recovery reads, through the host's own witness,
    /// once with the window adopted and once when the sampling ends, on both
    /// halves. A half without one, or one whose destination moved under it, is
    /// a failed run and never a zero.
    ///
    /// The destination is the person's own frontmost window because it cannot
    /// be one of ours: `rememberUserWindow` refuses a frontmost process the
    /// seat has adopted, and the only window this process can adopt is its
    /// own. A second cooperative process is what the stage benchmark needs a
    /// fixture application for, and this driver has none to offer.
    ///
    /// So the number is the whole refresh, sixty times: the destination
    /// reading, the owner and PSN resolution on the main actor, and the window
    /// server enumeration off it. It is not the cost of an activation, of a
    /// restoration or of its verification. Nothing activates during this run,
    /// and those intervals have their own approved budgets.
    ///
    /// ## Reported, not gated
    ///
    /// No budget. The refresh's cost has never been measured on a real
    /// machine, and a limit derived from arithmetic over other rows is the
    /// thing this benchmark exists to replace. The owner promotes a row to a
    /// gate once three runs have decided a number, which is the rule every
    /// budget in `Budgets.swift` was written under.
    static func runFocusRefresh(
        seconds          : Double,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        MonitorBench.pump(0.2)

        guard AXIsProcessTrusted() else {
            print("\(focusRefreshName): FAIL, Accessibility is not granted, nothing can be adopted")
            return false
        }

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 320),
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        window.title       = "AgentSeatKit focus refresh bench"
        window.contentView = BenchTargetView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        window.orderFrontRegardless()
        MonitorBench.pump(0.3)
        defer { window.close() }

        guard let home = WindowServerProbe.geometry(of: Int(window.windowNumber)) else {
            print("\(focusRefreshName): FAIL, the window server does not know our own window")
            return false
        }

        // One destination across the whole pair: its absence makes the measured
        // half meaningless, and a change of it makes the subtraction meaningless.
        var destination: WindowReference?
        let inspect: (SeatHost) -> String? = { host in
            guard let found = focusDestination(host) else {
                return "no user window is a focus destination, so every refresh returns "
                    + "before it resolves an owner: leave an ordinary application "
                    + "frontmost, with a window on a physical display"
            }
            if let held = destination, !held.hasSameIdentity(as: found) {
                return "the focus destination changed under the run, window "
                    + "\(held.windowNumber) to \(found.windowNumber)"
            }
            destination = found
            return nil
        }

        // The half with the recovery runs first, so a run with no destination
        // costs one minute instead of two before it says so.
        guard let restoring = sampleSeat(
            configuration: SeatHostConfiguration(
                restoresUserFocus            : true,
                allowUnvalidatedFocusRecovery: true
            ),
            benchmark    : focusRefreshName,
            label        : "recovery on",
            home         : home,
            seconds      : seconds,
            clock        : clock,
            inspect      : inspect
        ) else { return false }

        guard let control = sampleSeat(
            configuration: SeatHostConfiguration(),
            benchmark    : focusRefreshName,
            label        : "recovery off",
            home         : home,
            seconds      : seconds,
            clock        : clock,
            inspect      : inspect
        ) else { return false }

        let netCpu = Sample(
            name       : focusRefreshName,
            nanoseconds: restoring.cpuPercents.map {
                max(0, $0 - control.cpuMedianPercent) * 1_000
            },
            allocations: 0,
            frees      : 0
        )
        let medianPercent = netCpu.p50 / 1_000
        let p95Percent    = netCpu.p95 / 1_000
        let netWakeups    = max(0, restoring.wakeupsPerSecond - control.wakeupsPerSecond)
        let named         = describe(destination)

        print("""
            \(focusRefreshName): \(Int(seconds)) s a side, net CPU median \
            \(format(medianPercent)) %, p95 \(format(p95Percent)) %, \
            wake-ups \(format(netWakeups))/s
            recovery off: CPU median \(format(control.cpuMedianPercent)) %, \
            wake-ups \(format(control.wakeupsPerSecond))/s
            destination: \(named), read again when each half ended
            covers: the destination reading, the owner and PSN resolution and the \
            window server enumeration, once a second. Not an activation, a \
            restoration or a verification: nothing activated during this run.
            """)

        let results: [[String: Any]] = [
            [
                "name"  : "\(focusRefreshName)-cpu-median",
                "unit"  : "percent",
                "n"     : restoring.cpuPercents.count,
                "p50"   : medianPercent,
                "p95"   : p95Percent,
                "mean"  : medianPercent,
                "status": "measured",
                "detail": "destination \(named)",
            ],
            [
                "name"  : "\(focusRefreshName)-wakeups",
                "unit"  : "per-second",
                "n"     : restoring.cpuPercents.count,
                "p50"   : netWakeups,
                "mean"  : netWakeups,
                "status": "measured",
            ],
            [
                "name"  : "\(focusRefreshName)-control-cpu-median",
                "unit"  : "percent",
                "n"     : control.cpuPercents.count,
                "p50"   : control.cpuMedianPercent,
                "mean"  : control.cpuMedianPercent,
                "status": "measured",
            ],
        ]

        write(
            results          : results,
            clock            : clock,
            outputPath       : outputPath,
            baselineDirectory: baselineDirectory
        )
        print("\(focusRefreshName): REPORTED, no budget: a gate needs a real run to decide one")
        return true
    }

    /// The destination reading `UserFocusRecovery` takes, taken here through the
    /// host's own witness so the answer is the kit's own and not a second
    /// implementation of it.
    ///
    /// It mirrors `currentUserWindow` and `validDestination` together. The one
    /// clause written differently is theirs over the adopted processes, which
    /// here is this process: its own window is the only one this driver adopts.
    private static func focusDestination(_ host: SeatHost) -> WindowReference? {

        guard let sensing = host.sensing,
              let window  = sensing.focusedUserWindow,
              sensing.frontmostProcessID == window.processID,
              window.processID != getpid(),
              let current = sensing.windowGeometry(of: window.windowNumber),
              current.hasSameIdentity(as: window),
              !current.frame.isEmpty,
              !current.frame.intersects(sensing.virtualDisplayBounds),
              sensing.windowIsVisibleOnPhysicalDisplay(current)
        else { return nil }

        return current
    }

    /// The destination as a person reads it: a number nobody can attribute to
    /// an application is a number nobody can reproduce.
    private static func describe(_ window: WindowReference?) -> String {
        guard let window else { return "none" }
        let name = NSRunningApplication(processIdentifier: window.processID)?.localizedName
        return "\(name ?? "pid \(window.processID)") window \(window.windowNumber)"
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
            // New rows are added, existing ones left alone. Writing the whole
            // file would erase every other benchmark's baseline for this build.
            mergeIntoBaseline(object, at: baselinePath(in: baselineDirectory))
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
