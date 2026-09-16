//
//  FenceClampBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import CursorGuard
import Darwin
import Foundation
import PrivateSymbols
import SeatCore

/// FenceClampBench measures the branch `fence-callback` deliberately does not:
/// the clamp, **with the cursor really warped**.
///
/// `fence-callback` runs on a detached fence, which owns no tap and therefore
/// has no right to move the person's pointer, so every scenario there is the
/// steady state path with no `CGWarpMouseCursorPosition` in it. That left the
/// expensive half of the callback unmeasured: the clamp is what runs when the
/// person pushes the cursor at the edge of their own displays, it ends in a
/// window server round trip, and nothing can exercise it without a real tap on
/// real hardware, which is why it went unmeasured for so long.
///
/// This benchmark installs the **real** tap, so `movesPhysicalCursor` is true,
/// and hands the callback a synthetic `mouseMoved` far outside the region.
/// Every iteration clamps and warps for real. It therefore **moves the
/// person's cursor**, to the edge of the region and no further, and it puts it
/// back where it found it at the end. Nothing is ever posted: the event is
/// handed to `handle` directly, exactly as the unit tier does.
///
/// The budget is not the steady state one. A warp is a synchronous round trip
/// to the window server and the callback's 50 us p99 was written for a path
/// with no round trip in it, so the number here is its own constant, gated on
/// allocations at zero and on a p99 that leaves the callback well inside the
/// 1 ms ceiling it must never cross.
@MainActor
enum FenceClampBench {

    static let name = "fence-clamp"

    static func run(
        iterations       : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()

        guard Permissions.preflight(.accessibility) else {
            print("\(name): FAIL, Accessibility is not granted, so no tap can be installed")
            return false
        }

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        let displayBounds = displayIDs.map { CGDisplayBounds($0) }

        guard let cursorBefore = CGEvent(source: nil)?.location else {
            print("\(name): FAIL, the pointer position is not readable")
            return false
        }

        guard let fence = try? CursorFence.acquire(displayBounds: displayBounds) else {
            print("\(name): FAIL, the fence refused to install its tap")
            return false
        }
        defer {
            _ = fence.release()
            // The person's pointer goes back where it was, inside the region it
            // never left.
            CGWarpMouseCursorPosition(cursorBefore)
        }
        guard fence.isActive else {
            print("\(name): FAIL, the tap installed but is not active")
            return false
        }

        // Far outside every physical display, so `nearestPoint` really has
        // something to correct and the warp really has somewhere to move to.
        let region  = fence.region.bounds.reduce(CGRect.null) { $0.union($1) }
        let outside = CGPoint(x: region.maxX + 4_000, y: region.maxY + 4_000)
        let inside  = CGPoint(x: region.midX, y: region.midY)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let outsideMove = CGEvent(
                  mouseEventSource   : source,
                  mouseType          : .mouseMoved,
                  mouseCursorPosition: outside,
                  mouseButton        : .left
              ),
              let insideMove = CGEvent(
                  mouseEventSource   : source,
                  mouseType          : .mouseMoved,
                  mouseCursorPosition: inside,
                  mouseButton        : .left
              )
        else {
            print("\(name): could not build the synthetic events")
            return false
        }
        for event in [outsideMove, insideMove] {
            event.setIntegerValueField(.eventSourceUserData, value: 0)
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            event.setIntegerValueField(
                .eventSourceStateID,
                value: Int64(CGEventSourceStateID.hidSystemState.rawValue)
            )
        }

        print("\(name): region \(region), out of region point \(outside), cursor was \(cursorBefore)")

        let before  = fence.snapshot()
        let warmUp  = min(2_000, iterations / 10)
        var samples: [Sample] = []

        // 1. The branch under measurement: out of region, clamped, warped. The
        //    event's own location is rewritten every iteration, because the
        //    callback mutates it and a clamped event is in region next time.
        samples.append(measure(
            "fence_callback_clamp_with_warp",
            iterations: iterations,
            warmUp    : warmUp
        ) {
            outsideMove.location = outside
            _ = fence.handle(type: .mouseMoved, event: outsideMove)
        })

        // 2. The same callback on the same fence with an in region event: the
        //    steady state path, measured here too so the cost of the warp is a
        //    subtraction and not a comparison across two runs.
        samples.append(measure(
            "fence_callback_in_region_same_fence",
            iterations: iterations,
            warmUp    : warmUp
        ) {
            _ = fence.handle(type: .mouseMoved, event: insideMove)
        })

        // 3. The bare warp, with no callback around it, so the round trip can
        //    be told apart from the kit's own share of the clamp.
        samples.append(measure(
            "warp_only",
            iterations: iterations,
            warmUp    : min(2_000, iterations / 10)
        ) {
            CGWarpMouseCursorPosition(inside)
        })

        // 4. The control: the same loop with an empty body.
        samples.append(measure("probe_overhead", iterations: iterations, warmUp: 2_000) {})

        let snapshot = fence.snapshot()

        // Events the tap saw that this driver did not hand it, which is the
        // person's own hand. It matters because the tap here is **real**: while
        // the measurement window is open, a real HID event is delivered on the
        // fence's own thread, and the allocations that delivery costs land in a
        // `malloc_logger` count that is process wide. Measured: 1281 of them
        // over 20 000 iterations with somebody using the mouse, and zero in
        // every run where nobody touched it. The callback's own budget is still
        // zero; what this number decides is whether the count can be read.
        let handedOver  = UInt64(2 * (iterations + warmUp))
        let observed    = snapshot.observedEventCount - before.observedEventCount
        let strayEvents = observed > handedOver ? observed - handedOver : 0

        for sample in samples { print(sample.line) }
        print("""
            fence snapshot: \(snapshot.clampedEventCount - before.clampedEventCount) clamps in \
            this run, \(observed) observed of \(handedOver) handed over, \(strayEvents) from the \
            person's hand, \(snapshot.disableCount) disables
            """)

        guard let clamp    = samples.first(where: { $0.name == "fence_callback_clamp_with_warp" }),
              let inRegion = samples.first(where: { $0.name == "fence_callback_in_region_same_fence" }),
              let warpOnly = samples.first(where: { $0.name == "warp_only" })
        else {
            print("\(name): FAIL, a scenario did not produce a sample")
            return false
        }
        print(String(
            format: "the warp's share: clamp p50 %.0f ns minus in region p50 %.0f ns = %.0f ns, "
                + "and a bare warp is %.0f ns",
            clamp.p50, inRegion.p50, clamp.p50 - inRegion.p50, warpOnly.p50
        ))

        var passed = true
        let gated  = [clamp, inRegion]
        for sample in gated {
            let limit = sample.name == "fence_callback_clamp_with_warp"
                ? Budget.fenceClampP99Nanoseconds
                : Budget.fenceCallbackP99Nanoseconds
            if sample.allocations != UInt64(Budget.fenceCallbackAllocations) {
                if strayEvents > 0 {
                    print(
                        "INCONCLUSIVE \(sample.name): \(sample.allocations) allocations, budget "
                        + "\(Budget.fenceCallbackAllocations), but the tap delivered \(strayEvents) "
                        + "real events during the window and the count is process wide"
                    )
                } else {
                    print(
                        "FAIL \(sample.name): \(sample.allocations) allocations, "
                        + "budget \(Budget.fenceCallbackAllocations)"
                    )
                    passed = false
                }
            }
            if sample.p99 > limit {
                print(String(
                    format: "FAIL %@: p99 %.0f ns, budget %.0f ns",
                    sample.name, sample.p99, limit
                ))
                passed = false
            }
            if sample.maximum > Budget.fenceCallbackCeilingNanoseconds {
                // Reported, not gated, for the same reason as in
                // `fence-callback`: a maximum on this loop is the scheduler
                // taking the CPU away.
                print(String(
                    format: "NOTE %@: max %.0f ns above the %.0f ns ceiling, scheduler preemption",
                    sample.name, sample.maximum, Budget.fenceCallbackCeilingNanoseconds
                ))
            }
        }
        if snapshot.clampedEventCount - before.clampedEventCount < UInt64(iterations) {
            print("""
                FAIL: \(snapshot.clampedEventCount - before.clampedEventCount) clamps counted for \
                \(iterations) out of region events, so the branch was not the one measured
                """)
            passed = false
        }
        if snapshot.disableCount > 0 {
            print("FAIL: the tap was disabled \(snapshot.disableCount) times during the run")
            passed = false
        }

        let report: [String: Any] = [
            "schema_version": 1,
            "benchmark"     : name,
            "provenance"    : provenance(clock: clock),
            "scenario"      : "the real tap installed, synthetic out of region mouseMoved events "
                + "handed to the callback directly and never posted, so every iteration clamps and "
                + "calls CGWarpMouseCursorPosition for real; the pointer is restored afterwards",
            "results"       : samples.map { sample -> [String: Any] in
                switch sample.name {
                case "fence_callback_clamp_with_warp":
                    sample.json(
                        budgetLimit: Budget.fenceClampP99Nanoseconds,
                        passed     : sample.p99 <= Budget.fenceClampP99Nanoseconds
                            && sample.allocations == UInt64(Budget.fenceCallbackAllocations)
                    )
                case "fence_callback_in_region_same_fence":
                    sample.json(
                        budgetLimit: Budget.fenceCallbackP99Nanoseconds,
                        passed     : sample.p99 <= Budget.fenceCallbackP99Nanoseconds
                    )
                default:
                    sample.json(budgetLimit: nil, passed: nil)
                }
            },
        ]

        if let outputPath { writeJSON(report, to: outputPath) }
        if let baselineDirectory {
            passed = compareWithBaseline(report, samples: gated, directory: baselineDirectory) && passed
        }

        print(passed ? "\(name): PASS" : "\(name): FAIL")
        return passed
    }

    /// The regression rule, with the same absolute floor as
    /// `fence-callback`: below the timer's resolution a percentage is noise.
    private static func compareWithBaseline(
        _ report : [String: Any],
        samples  : [Sample],
        directory: String
    ) -> Bool {

        let path = baselinePath(in: directory)
        let rows = (readJSON(at: path)?["results"] as? [[String: Any]]) ?? []
        defer { mergeIntoBaseline(report, at: path) }

        var passed = true
        for sample in samples {
            guard let row = rows.first(where: { $0["name"] as? String == sample.name }),
                  let previous = row["p95"] as? Double, previous > 0
            else {
                print("\(sample.name): no-baseline, writing \(path)")
                continue
            }

            let allowed = previous * (1 + Budget.regressionTolerance)
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
