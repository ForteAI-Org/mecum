//
//  DisplayLifecycleBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import VirtualScreens

/// DisplayLifecycleBench times the whole life of a real virtual display, in the
/// order a Seat Host uses, and gates the two budgets of spec section 8: setup at
/// most 800 ms p95 **without a settle**, removal at most 200 ms p95.
///
/// It also answers the open question the budget was written around. Waiting
/// 300 ms between two `verifyTopology` calls after attaching the display costs
/// nearly half the measured setup time and had never been justified: this driver
/// verifies immediately and again after the same 300 ms,
/// and counts the runs where the two disagree. Zero disagreements over
/// consecutive runs is what makes the wait dead weight; one is what brings it
/// back, with a number behind it.
///
/// A real display appears on the person's Mac for about a second per run. The
/// driver removes it, verifies the removal against `CGGetOnlineDisplayList` and
/// restores the topology before it exits, on every path.
@MainActor
enum DisplayLifecycleBench {

    static let name         = "display-lifecycle"
    static let setupName    = "display-setup"
    static let teardownName = "display-teardown"

    /// AppKit is pumped for real, because `NSScreen` is refreshed by the
    /// application event loop and nothing else: without this the display is
    /// created and never registers.
    static func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool {
                if let event = NSApplication.shared.nextEvent(
                    matching: .any,
                    until   : deadline,
                    inMode  : .default,
                    dequeue : true
                ) {
                    NSApplication.shared.sendEvent(event)
                }
            }
        } while Date() < deadline
    }

    static func pump(until condition: () -> Bool, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.002)
        }
        return condition()
    }

    static func run(
        cycles           : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        pump(0.2)

        var setupNanoseconds   : [Double] = []
        var teardownNanoseconds: [Double] = []
        var settleDisagreements = 0
        var registrationWaits  : [Double] = []
        var failures           : [String]  = []

        for cycle in 1...cycles {
            do {
                let baselineOnline = Set(try DisplayList.online())

                let setupStart = clock.tick()
                let display    = try VirtualDisplay.create()
                // Both registrations, CoreGraphics's and AppKit's, need the
                // application event loop to turn, and the second implies the
                // first: waiting for the NSScreen covers them in one wait.
                let registrationStart = clock.tick()
                guard pump(until: { display.appKitScreen != nil }, timeout: 5) else {
                    display.invalidate()
                    throw DisplayFailure.screenRegistrationTimedOut(displayID: display.displayID)
                }
                let registrationTicks = clock.tick() &- registrationStart
                try display.configureTopology()
                try display.verifyTopology()
                let setupTicks = clock.tick() &- setupStart

                // The settle, measured instead of assumed. The topology is
                // verified again after the same 300 ms a setup used to wait: a
                // disagreement here is the only thing that would justify the
                // wait, and it is counted rather than argued about.
                pump(0.3)
                var settleChangedTheAnswer = false
                do { try display.verifyTopology() } catch { settleChangedTheAnswer = true }
                if settleChangedTheAnswer { settleDisagreements += 1 }

                // The display lives a full second before it is taken away, as
                // as the baseline was taken: a removal timed right after the
                // attachment is not the removal a seat performs, and it is not
                // comparable to the 78 to 94 ms the baseline holds.
                pump(0.7)

                let teardownStart = clock.tick()
                display.invalidate()
                let removed = pump(until: { (try? display.isOnline) == false }, timeout: 2)
                let teardownTicks = clock.tick() &- teardownStart
                guard removed else {
                    throw DisplayFailure.displayStillOnline(display.displayID)
                }

                let restoration = try display.restoreTopology()
                // A full second between cycles, as the baseline was taken: the
                // window server needs the previous display
                // to be fully gone before it accepts the same identity triple
                // again, and the pump is what lets that finish.
                pump(1.0)
                guard restoration != .topologyChangedByUser else {
                    throw DisplayFailure.displayStillOnline(display.displayID)
                }
                try display.verifyTopology()
                guard Set(try DisplayList.online()) == baselineOnline else {
                    throw DisplayFailure.displayStillOnline(display.displayID)
                }

                setupNanoseconds.append(Double(setupTicks) * clock.nanosecondsPerTick)
                teardownNanoseconds.append(Double(teardownTicks) * clock.nanosecondsPerTick)
                registrationWaits.append(Double(registrationTicks) * clock.nanosecondsPerTick / 1e6)

                print(String(
                    format: "  cycle %d/%d: setup %6.0f ms  teardown %5.0f ms  "
                        + "registration %4.0f ms  settle changed the answer: %@",
                    cycle, cycles,
                    Double(setupTicks) * clock.nanosecondsPerTick / 1e6,
                    Double(teardownTicks) * clock.nanosecondsPerTick / 1e6,
                    Double(registrationTicks) * clock.nanosecondsPerTick / 1e6,
                    settleChangedTheAnswer ? "yes" : "no"
                ))
            } catch {
                failures.append("cycle \(cycle): \(error)")
                print("  cycle \(cycle)/\(cycles): FAILED \(error)")
                pump(1.0)
            }
        }

        guard failures.isEmpty, !setupNanoseconds.isEmpty else {
            print("display-lifecycle: FAIL, \(failures.joined(separator: "; "))")
            return false
        }

        let setup = Sample(
            name       : setupName,
            nanoseconds: setupNanoseconds,
            allocations: 0,
            frees      : 0
        )
        let teardown = Sample(
            name       : teardownName,
            nanoseconds: teardownNanoseconds,
            allocations: 0,
            frees      : 0
        )

        var passed = true
        for (sample, budget) in [
            (setup,    Budget.displaySetupNanosecondsP95),
            (teardown, Budget.displayTeardownNanosecondsP95),
        ] {
            let ok = sample.p95 <= budget
            print(String(
                format: "%@ %@: p50 %.0f ms  p95 %.0f ms  max %.0f ms  budget %.0f ms",
                ok ? "PASS" : "FAIL", sample.name,
                sample.p50 / 1e6, sample.p95 / 1e6, sample.maximum / 1e6, budget / 1e6
            ))
            passed = passed && ok
        }

        print(String(
            format: "settle: the deliberate 300 ms wait changed the verdict in %d of %d cycles",
            settleDisagreements, cycles
        ))
        if settleDisagreements > 0 {
            print("settle: FAIL, the topology was not settled at the first verify")
            passed = false
        }

        let report: [String: Any] = [
            "schema_version": 1,
            "benchmark"     : "display-lifecycle",
            "provenance"    : provenance(clock: clock),
            "scenario"      : "real CGVirtualDisplay, AppKit event pump, no settle between "
                + "verify and use; removal confirmed with CGGetOnlineDisplayList",
            "settle_disagreements"     : settleDisagreements,
            "registration_wait_ms_mean": registrationWaits.reduce(0, +) / Double(registrationWaits.count),
            "results": [
                setup.json(budgetLimit: Budget.displaySetupNanosecondsP95, passed: setup.p95 <= Budget.displaySetupNanosecondsP95),
                teardown.json(budgetLimit: Budget.displayTeardownNanosecondsP95, passed: teardown.p95 <= Budget.displayTeardownNanosecondsP95),
            ],
        ]

        if let outputPath { writeJSON(report, to: outputPath) }
        if let baselineDirectory {
            passed = compareWithBaseline(report, samples: [setup, teardown], directory: baselineDirectory)
                && passed
        }

        print(passed ? "display-lifecycle: PASS" : "display-lifecycle: FAIL")
        return passed
    }

    /// The regression rule, with the same 10 % tolerance the fence
    /// benchmark uses, but read off **p50** rather than p95.
    ///
    /// That is not a softening, it is what the sample size allows. A cycle
    /// creates a real display, so a run is five samples and p95 is simply the
    /// worst of the five: measured across six runs on the reference machine it
    /// wanders between 66 and 97 ms while p50 stays between 59 and 70. A rule
    /// written on the maximum of five would report a regression on scheduler
    /// noise. The **budget** of spec section 8 is still gated on p95, where a
    /// worst case is exactly the right thing to check.
    ///
    /// A first run on a new build and hardware pair writes the baseline and
    /// reports `no-baseline`.
    private static func compareWithBaseline(
        _ report : [String: Any],
        samples  : [Sample],
        directory: String
    ) -> Bool {

        let path = baselinePath(in: directory)
        guard let baseline = readJSON(at: path),
              let rows = baseline["results"] as? [[String: Any]],
              rows.contains(where: { $0["name"] as? String == setupName })
        else {
            merge(report, into: path)
            print("display-lifecycle: no-baseline, wrote \(path)")
            return true
        }

        var passed = true
        for sample in samples {
            guard let row = rows.first(where: { $0["name"] as? String == sample.name }),
                  let previous = row["p50"] as? Double, previous > 0
            else { continue }

            let allowed = previous * (1 + Budget.regressionTolerance)
            guard sample.p50 > allowed,
                  sample.p50 - previous > Budget.displayRegressionFloorNanoseconds
            else { continue }

            guard loadAllowsBaselineComparison() else {
                reportInconclusive(
                    sample.name,
                    measured: String(format: "p50 %.0f ms", sample.p50 / 1e6),
                    baseline: String(format: "%.0f ms", previous / 1e6)
                )
                continue
            }
            print(String(
                format: "FAIL %@: p50 %.0f ms against a baseline of %.0f ms, over the %.0f%% tolerance",
                sample.name, sample.p50 / 1e6, previous / 1e6, Budget.regressionTolerance * 100
            ))
            passed = false
        }
        return passed
    }

    /// Adds this benchmark's rows to the shared baseline file instead of
    /// replacing it: one file per build and hardware pair holds every
    /// benchmark, and the fence's rows were written there first.
    private static func merge(_ report: [String: Any], into path: String) {
        guard var existing = readJSON(at: path),
              var rows = existing["results"] as? [[String: Any]],
              let fresh = report["results"] as? [[String: Any]]
        else {
            writeJSON(report, to: path)
            return
        }
        let names = Set(fresh.compactMap { $0["name"] as? String })
        rows.removeAll { names.contains($0["name"] as? String ?? "") }
        existing["results"]   = rows + fresh
        // The file holds every benchmark's rows for this build and hardware
        // pair, so it stops being named after whichever one wrote it first.
        existing["benchmark"] = "baseline"
        writeJSON(existing, to: path)
    }
}
