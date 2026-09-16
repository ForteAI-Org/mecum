//
//  FenceCallbackBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import Darwin
import Foundation
import SeatCore

/// FenceCallbackBench measures the HID callback in the three scenarios its
/// budget names: at rest, with an anchor in flight and with an audit recording.
///
/// The method is deliberately the one the saved baseline was taken with, which
/// is what makes the numbers comparable at all: synthetic
/// `mouseMoved` events inside the physical region, **never posted**, no tap
/// installed and no cursor warped. What is measured is the steady state path,
/// which is the path that runs on every movement of the person's hand.
///
/// It is a gate, not a report. A single allocation or a p99 over budget exits
/// the driver non zero.
@MainActor
enum FenceCallbackBench {

    static let name = "fence-callback"

    /// The audit's trace holds 8192 points and invalidates itself past that, so
    /// the measured window stays under the limit and the warm up runs on a
    /// throwaway audit rather than eating into it.
    static let auditIterations = 8_000

    static func run(
        iterations       : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        let displayBounds = displayIDs.map { CGDisplayBounds($0) }

        guard let fence = try? CursorFence.acquireDetached(displayBounds: displayBounds),
              let first = displayBounds.first
        else {
            print("fence-callback: no physical display to build a region from")
            return false
        }
        defer { fence.release() }

        let inside = CGPoint(x: first.midX, y: first.midY)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let userMove = CGEvent(
                  mouseEventSource   : source,
                  mouseType          : .mouseMoved,
                  mouseCursorPosition: inside,
                  mouseButton        : .left
              ),
              let syntheticMove = CGEvent(
                  mouseEventSource   : source,
                  mouseType          : .mouseMoved,
                  mouseCursorPosition: inside,
                  mouseButton        : .left
              )
        else {
            print("fence-callback: could not build the synthetic events")
            return false
        }

        // A user event carries no marker and claims the HID source, which is
        // what the audit demands before it counts a movement as physical.
        userMove.setIntegerValueField(.eventSourceUserData, value: 0)
        userMove.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        userMove.setIntegerValueField(
            .eventSourceStateID,
            value: Int64(CGEventSourceStateID.hidSystemState.rawValue)
        )
        syntheticMove.setIntegerValueField(.eventSourceUserData, value: 42)

        print("fence-callback: region \(displayBounds), point \(inside)")

        var samples: [Sample] = []

        // 1. At rest: no anchor, no audit. The path of every mouse movement
        //    while the seat is idle.
        samples.append(measure(
            "fence_callback_idle",
            iterations: iterations,
            warmUp    : min(10_000, iterations / 10)
        ) {
            _ = fence.handle(type: .mouseMoved, event: userMove)
        })

        // 2. With an anchor in flight: a user event walks the anchors so the
        //    next synthetic one stays pinned to where the hand is now. This is
        //    the scenario a dictionary of anchors costs an allocation for.
        fence.anchor(inside, forSyntheticMarker: 42)
        samples.append(measure(
            "fence_callback_anchor_user_event",
            iterations: iterations,
            warmUp    : min(10_000, iterations / 10)
        ) {
            _ = fence.handle(type: .mouseMoved, event: userMove)
        })

        // 3. The driver's own event under the same anchor: pinned, not clamped.
        samples.append(measure(
            "fence_callback_anchor_synthetic_event",
            iterations: iterations,
            warmUp    : min(10_000, iterations / 10)
        ) {
            _ = fence.handle(type: .mouseMoved, event: syntheticMove)
        })
        fence.endAnchor(forSyntheticMarker: 42)

        // 4. With an audit recording: the settle window of an action, and the
        //    scenario that costs two allocations per event if the traces are
        //    not preallocated. The event's timestamp is
        //    refreshed first, because the audit refuses a reading it cannot
        //    place inside the five seconds before its delivery, and a benchmark
        //    that stops at that guard would never reach the trace at all.
        fence.attachAudit(
            CursorMotionAudit(
                marker   : 7,
                point    : inside,
                timestamp: DispatchTime.now().uptimeNanoseconds
            ),
            forSyntheticMarker: 7
        )
        userMove.timestamp = mach_absolute_time()
        for _ in 0..<800 { _ = fence.handle(type: .mouseMoved, event: userMove) }
        _ = fence.endAudit(forSyntheticMarker: 7)

        fence.attachAudit(
            CursorMotionAudit(
                marker   : 7,
                point    : inside,
                timestamp: DispatchTime.now().uptimeNanoseconds
            ),
            forSyntheticMarker: 7
        )
        userMove.timestamp = mach_absolute_time()
        samples.append(measure(
            "fence_callback_audit",
            iterations: auditIterations
        ) {
            _ = fence.handle(type: .mouseMoved, event: userMove)
        })
        let auditResult = fence.endAudit(forSyntheticMarker: 7)

        // 5. The control: the same loop with an empty body, so every number
        //    above can be read net of the measuring apparatus.
        samples.append(measure("probe_overhead", iterations: iterations, warmUp: 10_000) {})

        let control = samples[samples.count - 1]
        for sample in samples { print(sample.line) }
        print(String(
            format: "control subtracted: p50 %.0f ns, p95 %.0f ns, p99 %.0f ns",
            control.p50, control.p95, control.p99
        ))
        if let auditResult {
            print(
                "audit trace: \(auditResult.physicalEventCount) physical, "
                + "\(auditResult.driverEventCount) driver, \(auditResult.otherEventCount) other"
            )
        }
        print("fence snapshot: \(fence.snapshot())")

        // The three scenarios of the budget, plus the synthetic one for the
        // same reason the baseline reported it: it is the branch the driver's own
        // events take, and a regression there is a regression in every action.
        let gated = samples.filter { $0.name != "probe_overhead" }
        var passed = true

        for sample in gated {
            let allocationsOK = sample.allocations == UInt64(Budget.fenceCallbackAllocations)
            let latencyOK     = sample.p99 <= Budget.fenceCallbackP99Nanoseconds
            let ceilingOK     = sample.maximum <= Budget.fenceCallbackCeilingNanoseconds

            if !allocationsOK {
                print(
                    "FAIL \(sample.name): \(sample.allocations) allocations, "
                    + "budget \(Budget.fenceCallbackAllocations)"
                )
            }
            if !latencyOK {
                print(String(
                    format: "FAIL %@: p99 %.0f ns, budget %.0f ns",
                    sample.name, sample.p99, Budget.fenceCallbackP99Nanoseconds
                ))
            }
            if !ceilingOK {
                // Reported, not gated: a maximum above the ceiling on this loop
                // is the scheduler taking the CPU away, not the callback
                // working.
                print(String(
                    format: "NOTE %@: max %.0f ns above the %.0f ns ceiling, scheduler preemption",
                    sample.name, sample.maximum, Budget.fenceCallbackCeilingNanoseconds
                ))
            }
            passed = passed && allocationsOK && latencyOK
        }

        let report: [String: Any] = [
            "schema_version": 1,
            "benchmark"     : name,
            "provenance"    : provenance(clock: clock),
            "scenario"      : "synthetic in-region mouseMoved events, no tap installed, no warp",
            "results"       : samples.map { sample -> [String: Any] in
                sample.name == "probe_overhead"
                    ? sample.json(budgetLimit: nil, passed: nil)
                    : sample.json(
                        budgetLimit: Budget.fenceCallbackP99Nanoseconds,
                        passed     : sample.p99 <= Budget.fenceCallbackP99Nanoseconds
                            && sample.allocations == UInt64(Budget.fenceCallbackAllocations)
                    )
            },
        ]

        if let outputPath { writeJSON(report, to: outputPath) }
        if let baselineDirectory {
            passed = compareWithBaseline(report, samples: gated, directory: baselineDirectory) && passed
        }

        print(passed ? "fence-callback: PASS" : "fence-callback: FAIL")
        return passed
    }

    /// Compares against the saved baseline for this build and hardware pair. A
    /// first run writes the file and reports `no-baseline`, which is never a
    /// pass on its own; here it does not fail the run either,
    /// because the budgets above already gated it.
    private static func compareWithBaseline(
        _ report : [String: Any],
        samples  : [Sample],
        directory: String
    ) -> Bool {

        let path = baselinePath(in: directory)
        guard let baseline = readJSON(at: path),
              let rows = baseline["results"] as? [[String: Any]]
        else {
            writeJSON(report, to: path)
            print("fence-callback: no-baseline, wrote \(path)")
            return true
        }

        var passed = true
        for sample in samples {
            guard let row = rows.first(where: { $0["name"] as? String == sample.name }),
                  let previous = row["p95"] as? Double, previous > 0
            else { continue }

            let allowed = previous * (1 + Budget.regressionTolerance)
            // Below the timer's own resolution a percentage is noise, so a
            // regression has to be visible in absolute terms too.
            guard sample.p95 > allowed, sample.p95 - previous > 100 else { continue }

            guard loadAllowsBaselineComparison() else {
                reportInconclusive(
                    sample.name,
                    measured: String(format: "p95 %.0f ns", sample.p95),
                    baseline: String(format: "%.0f ns", previous)
                )
                continue
            }
            print(String(
                format: "FAIL %@: p95 %.0f ns against a baseline of %.0f ns, over the %.0f%% tolerance",
                sample.name, sample.p95, previous, Budget.regressionTolerance * 100
            ))
            passed = false
        }
        return passed
    }
}
