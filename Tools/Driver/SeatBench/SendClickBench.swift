//
//  SendClickBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import WindowPlacement

/// SendClickBench measures the Background Driver's warm path against a window
/// **this process owns**, so every event posted stays inside the benchmark and
/// nothing reaches the person's applications. A local event monitor counts what
/// actually arrives, because a posting loop that delivers nothing is a fast
/// loop and not a measurement.
///
/// The coordinate-safety path now includes two WindowServer geometry snapshots.
/// Saved whole-send baselines recorded before that validation are retained as
/// historical evidence but are not directly comparable to this scenario.
///
/// The whole send is measured against a control that builds and posts the same
/// two CoreGraphics events. The latency difference includes identity, two
/// geometry snapshots, transform validation, routing and the Receipt. Identity
/// allocations have a second control: the same two documented `GetProcessPID`
/// mappings, using the target's attested process serial number.
@MainActor
enum SendClickBench {

    static let name = "send-click"

    /// Pre-geometry rows with the same names remain historical evidence, but
    /// baseline comparison refuses them because they measure a different path.
    static let measurementContract = "guarded-coordinate-v2"
    static let contractBoundSamples: Set<String> = [
        "send_click_full", "resolve_identity", "get_process_pid_twice_control",
    ]

    /// The Preparation talks to the window server four times per cycle, so it
    /// gets its own count: at 500 it dominates the runtime of the whole driver
    /// without saying anything the first hundred did not.
    static let preparationIterations = 200

    /// Why the default count is small, which is a measurement decision and not
    /// a shortcut: the target is this process's own window, and this process
    /// does not turn its event loop while a loop is being timed. Past a few
    /// hundred events the undrained queue is what gets measured, and the p95 of
    /// **both** the driver and the control blows up together, from 11 us at 200
    /// iterations to 94 us at 500. The p50 does not move. So the benchmark
    /// posts a few hundred, drains, and reports a tail that is still the
    /// driver's.
    static let defaultIterations = 200

    /// The pieces that are the kit's own code and nothing else: no CoreGraphics
    /// object is built or handed over inside them, so their allocation count is
    /// an assertion and not an estimate.
    static let zeroAllocationPieces: Set<String> = ["route_event"]

    static func run(
        iterations       : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        let gate  = FacilityGate.current(facility: .input)
        guard gate.mayAct else {
            print("send-click: the input facility refuses on this system: \(gate.readiness)")
            return false
        }

        // An accessory application with one window of its own. Nothing is
        // activated: the events are routed to this window by Window ID, which
        // is the whole point of the driver.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 420, height: 320),
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        window.title = "AgentSeatKit send-click bench"
        window.orderFrontRegardless()
        pump(for: 0.5)

        var delivered = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            delivered += 1
            return $0
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.orderOut(nil)
        }

        guard let target = WindowServerProbe.geometry(of: window.windowNumber),
              target.processID == getpid(),
              let geometry = WindowGeometryProbe.observation(of: target),
              geometry.window.frame == target.frame,
              let location = InputLocation(
                  screenPoint: CGPoint(x: target.frame.midX, y: target.frame.midY),
                  observedIn : geometry
              )
        else {
            print("send-click: WindowServer could not attest geometry and scale")
            return false
        }
        let platform: any InputPlatform = AppKitPlatform()
        let command  = InputCommand.click(location)

        guard let engine = try? InputEngine(unvalidatedBuild: gate.unvalidatedBuild),
              let source = CGEventSource(stateID: .privateState)
        else {
            print("send-click: the driver could not be built on this system")
            return false
        }
        source.localEventsSuppressionInterval = 0

        // Bind the control to the exact PSN/PID pair already attested for this target.
        guard let targetIdentity = target.identity else {
            print("send-click: FAIL, the target has no attested identity for the SDK control")
            return false
        }
        let targetProcess = targetIdentity.process
        guard WindowServerProbe.mappedProcessID(of: targetProcess) == target.processID,
              WindowServerProbe.mappedProcessID(of: targetProcess) == target.processID
        else {
            print("send-click: FAIL, GetProcessPID control could not reproduce the target PID")
            return false
        }

        print("""
            send-click: pid \(getpid()) window \(window.windowNumber), \
            readiness \(gate.readiness), post event grant \
            \(Permissions.preflight(.postEvent))
            """)

        var samples: [Sample] = []

        // 1. The whole send: identity, build, route, post. This is the number
        //    the budget is about.
        samples.append(measure(
            "send_click_full",
            iterations: iterations,
            warmUp    : min(50, iterations / 10)
        ) {
            _ = try? engine.post(command, to: target, correlationID: 1, platform: platform)
        })
        // Counted only after the loop is pumped: a posted event reaches this
        // process's queue and is not seen until the application turns it.
        pump(for: 1.0)
        let deliveredFull = delivered
        delivered = 0

        // 2. The control: what CoreGraphics charges for a click no matter who
        //    sends it, two events built and two events posted. Everything the
        //    kit does is the difference between this line and the one above.
        samples.append(measure(
            "send_click_control",
            iterations: iterations,
            warmUp    : min(50, iterations / 10)
        ) {
            guard let down = CGEvent(
                      mouseEventSource   : source,
                      mouseType          : .leftMouseDown,
                      mouseCursorPosition: location.screenPoint,
                      mouseButton        : .left
                  ),
                  let up = CGEvent(
                      mouseEventSource   : source,
                      mouseType          : .leftMouseUp,
                      mouseCursorPosition: location.screenPoint,
                      mouseButton        : .left
                  )
            else { return }
            down.postToPid(target.processID)
            up.postToPid(target.processID)
        })
        pump(for: 1.0)
        let deliveredControl = delivered
        delivered = 0

        // 3. The pieces, so a regression says where it happened.
        var buffer: [PreparedEvent] = []
        buffer.reserveCapacity(16)
        samples.append(measure("make_events_click", iterations: iterations, warmUp: 50) {
            buffer.removeAll(keepingCapacity: true)
            try? InputEvents.append(
                command,
                source       : source,
                pacing       : .realistic,
                correlationID: 1,
                into         : &buffer
            )
        })

        let identityWarmUp = 50
        var identityAttempts  = 0
        var failedIdentities  = 0
        samples.append(measure(
            "resolve_identity",
            iterations: iterations,
            warmUp    : identityWarmUp
        ) {
            identityAttempts += 1
            do {
                let observed = try engine.identity(of: target)
                if observed != targetIdentity { failedIdentities += 1 }
            } catch {
                failedIdentities += 1
            }
        })
        let expectedIdentityReads = iterations + identityWarmUp

        let mappingWarmUp = 50
        var mappingAttempts = 0
        var failedMappings  = 0
        samples.append(measure(
            "get_process_pid_twice_control",
            iterations: iterations,
            warmUp    : mappingWarmUp
        ) {
            for _ in 0..<2 {
                mappingAttempts += 1
                if WindowServerProbe.mappedProcessID(of: targetProcess) != target.processID {
                    failedMappings += 1
                }
            }
        })
        let expectedMappings = 2 * (iterations + mappingWarmUp)

        let identity = try? engine.identity(of: target)
        if let identity, let routed = CGEvent(
            mouseEventSource   : source,
            mouseType          : .leftMouseDown,
            mouseCursorPosition: location.screenPoint,
            mouseButton        : .left
        ) {
            samples.append(measure("route_event", iterations: iterations, warmUp: 50) {
                try? engine.route(
                    routed,
                    to               : location.windowPointFromTop,
                    windowNumber     : identity.windowNumber,
                    ownerConnectionID: identity.ownerConnectionID
                )
            })
            samples.append(measure("post_event", iterations: iterations, warmUp: 50) {
                routed.postToPid(target.processID)
            })
            pump(for: 0.5)
        }

        // 4. The Preparation, which the send budget deliberately excludes and
        //    which has a budget of its own: 100 us and no allocation, settle
        //    apart. It is applied to this process's own window.
        if var participant = try? engine.preparation.participant(for: target) {
            // A whole cycle is three records applied and one restored, which is
            // what one prepared Command pays; the restore alone is measured
            // next to it so the apply can be read as the difference. Both
            // numbers are dominated by the window server round trip, and the
            // allocations happen inside `SLPSPostEventRecordTo`, which is why
            // they are reported and not gated.
            samples.append(measure(
                "preparation_apply_restore",
                iterations: preparationIterations,
                warmUp    : 10
            ) {
                try? engine.preparation.apply(&participant)
                try? engine.preparation.restore(&participant)
            })
            samples.append(measure(
                "preparation_restore",
                iterations: preparationIterations,
                warmUp    : 10
            ) {
                try? engine.preparation.restore(&participant)
            })
        }

        // 5. The measuring apparatus itself.
        samples.append(measure("probe_overhead", iterations: iterations, warmUp: 1_000) {})

        for sample in samples { print(sample.line) }
        print("""
            delivered to own window: \(deliveredFull) from the driver, \
            \(deliveredControl) from the control, \
            expected about \(2 * iterations) each
            """)

        guard let full    = samples.first(where: { $0.name == "send_click_full" }),
              let control = samples.first(where: { $0.name == "send_click_control" })
        else {
            print("send-click: FAIL, the two measured scenarios did not both run")
            return false
        }

        // The kit's share: the send minus what CoreGraphics charges anyway.
        let attributableP95         = max(0, full.p95 - control.p95)
        let attributableP50         = max(0, full.p50 - control.p50)
        let attributableAllocations = max(
            0,
            full.allocationsPerCall - control.allocationsPerCall
        )
        print(String(
            format: "guarded-path delta: p50 %.0f ns, p95 %.0f ns, %.3f raw allocations per call",
            attributableP50, attributableP95, attributableAllocations
        ))

        var passed = true

        let identitySample = samples.first(where: { $0.name == "resolve_identity" })
        let mappingControl = samples.first(where: {
            $0.name == "get_process_pid_twice_control"
        })
        let identityAllocationResult = IdentityAllocationAssessment.evaluate(
            identityAllocations: identitySample?.allocations,
            identityIterations : identitySample?.iterations ?? 0,
            controlAllocations : mappingControl?.allocations,
            controlIterations  : mappingControl?.iterations ?? 0,
            expectedIdentityReads: expectedIdentityReads,
            observedIdentityReads: identityAttempts,
            failedIdentityReads  : failedIdentities,
            expectedMappings   : expectedMappings,
            observedMappings   : mappingAttempts,
            failedMappings     : failedMappings
        )

        let allocationEvidence: [String: Any]
        switch identityAllocationResult {
        case .success(let assessment):
            let allocationPassed = assessment.residualAllocationsPerCall
                <= Double(Budget.sendClickAllocations)
            print(String(
                format: "identity allocations: raw %.3f/call, two-call SDK control %.3f/call, residual %.3f/call",
                assessment.identityAllocationsPerCall,
                assessment.controlAllocationsPerCall,
                assessment.residualAllocationsPerCall
            ))
            if !allocationPassed {
                print(String(
                    format: "FAIL resolve_identity: residual %.3f allocations per call, budget %d",
                    assessment.residualAllocationsPerCall,
                    Budget.sendClickAllocations
                ))
                passed = false
            }
            allocationEvidence = [
                "status"                       : "measured",
                "identity_raw_total"           : assessment.identityAllocations,
                "identity_raw_per_call"        : assessment.identityAllocationsPerCall,
                "get_process_pid_control_total": assessment.controlAllocations,
                "get_process_pid_control_per_call": assessment.controlAllocationsPerCall,
                "residual_total"               : assessment.residualAllocations,
                "residual_per_call"            : assessment.residualAllocationsPerCall,
                "mapping_attempts"             : mappingAttempts,
                "mapping_failures"             : failedMappings,
                "identity_attempts"            : identityAttempts,
                "identity_failures"            : failedIdentities,
                "budget"                       : [
                    "limit" : Budget.sendClickAllocations,
                    "passed": allocationPassed,
                ],
            ]
        case .failure(let invalid):
            print("FAIL resolve_identity allocation evidence: \(invalid.message)")
            passed = false
            allocationEvidence = [
                "status"          : "invalid",
                "reason"          : invalid.message,
                "mapping_attempts": mappingAttempts,
                "mapping_failures": failedMappings,
                "identity_attempts": identityAttempts,
                "identity_failures": failedIdentities,
                "budget"          : [
                    "limit" : Budget.sendClickAllocations,
                    "passed": false,
                ],
            ]
        }

        // Framework costs remain raw. `route_event` is the other exact zero gate;
        // identity uses the validated SDK control above.
        // `postToPid` allocates between 11 and 22 times per event **for the
        // same code** from one run to the next, because this benchmark posts to
        // a process that is not draining its own queue and the allocator cost
        // inside CoreGraphics follows the queue pressure. Subtracting two loops
        // with that spread cannot prove "zero": the pieces can, and they are
        // the code the kit actually owns.
        for piece in samples where Self.zeroAllocationPieces.contains(piece.name) {
            guard piece.allocations != 0 else { continue }
            print(String(
                format: "FAIL %@: %.3f allocations per call, budget 0",
                piece.name, piece.allocationsPerCall
            ))
            passed = false
        }
        if let build = samples.first(where: { $0.name == "make_events_click" }),
           build.allocationsPerCall > Budget.makeEventsAllocationsPerEvent * 2 {
            print(String(
                format: "FAIL make_events_click: %.3f allocations per call, budget %.0f",
                build.allocationsPerCall, Budget.makeEventsAllocationsPerEvent * 2
            ))
            passed = false
        }
        if attributableP95 > Budget.sendClickNanosecondsP95 {
            print(String(
                format: "FAIL send_click: p95 %.0f ns attributable, budget %.0f ns",
                attributableP95, Budget.sendClickNanosecondsP95
            ))
            passed = false
        }
        if deliveredFull == 0 {
            print("FAIL send_click: nothing was delivered, the loop measured a refusal")
            passed = false
        }

        if let preparation = samples.first(where: { $0.name == "preparation_apply_restore" }),
           preparation.p95 > Budget.preparationNanosecondsP95 {
            print(String(
                format: "FAIL preparation: p95 %.0f ns, budget %.0f ns",
                preparation.p95, Budget.preparationNanosecondsP95
            ))
            passed = false
        }

        let report: [String: Any] = [
            "schema_version": 1,
            "benchmark"     : name,
            "measurement_contract": measurementContract,
            "provenance"    : provenance(clock: clock),
            "scenario"      : "own-process NSWindow target, AppKitPlatform, no preparation on "
                + "the measured send; events never leave the benchmark process",
            "attributable"  : [
                "p50"                 : attributableP50,
                "p95"                 : attributableP95,
                "allocations_per_call": attributableAllocations,
                "identity_allocations" : allocationEvidence,
                "budget"              : [
                    "limit" : Budget.sendClickNanosecondsP95,
                    "passed": passed,
                ],
            ],
            "delivered"     : ["driver": deliveredFull, "control": deliveredControl],
            "results"       : samples.map { sample -> [String: Any] in
                var row = sample.name == "send_click_full"
                    ? sample.json(budgetLimit: Budget.sendClickNanosecondsP95, passed: passed)
                    : sample.json(budgetLimit: nil, passed: nil)
                if Self.contractBoundSamples.contains(sample.name) {
                    row["measurement_contract"] = measurementContract
                }
                return row
            },
        ]

        if let outputPath { writeJSON(report, to: outputPath) }
        if let baselineDirectory {
            passed = compareWithBaseline(report, samples: samples, directory: baselineDirectory)
                && passed
        }

        print(passed ? "send-click: PASS" : "send-click: FAIL")
        return passed
    }

    /// The application event loop, turned by hand: the events are posted to this
    /// very process, and a process that does not pump never receives what it
    /// sent itself.
    private static func pump(for seconds: Double) {
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
            print("send-click: no-baseline, wrote \(path)")
            return true
        }

        var passed = true
        for sample in samples where sample.name != "probe_overhead" {
            guard let row = rows.first(where: { $0["name"] as? String == sample.name }) else {
                if Self.contractBoundSamples.contains(sample.name) {
                    print(
                        "send-click: no-comparable-baseline for \(sample.name); "
                            + "the saved baseline has no \(measurementContract) row"
                    )
                }
                continue
            }

            if Self.contractBoundSamples.contains(sample.name),
               row["measurement_contract"] as? String != measurementContract {
                print(
                    "send-click: no-comparable-baseline for \(sample.name); "
                        + "saved row predates \(measurementContract)"
                )
                continue
            }

            guard let previous = row["p95"] as? Double, previous > 0 else {
                if Self.contractBoundSamples.contains(sample.name) {
                    print(
                        "send-click: no-comparable-baseline for \(sample.name); "
                            + "the saved contract row has no valid p95"
                    )
                }
                continue
            }

            let allowed = previous * (1 + Budget.regressionTolerance)
            // A percentage alone would report the scheduler: the control's own
            // p95 wanders by more than 10 us between runs, so a regression has
            // to be over the tolerance and over the absolute floor as well.
            guard sample.p95 > allowed,
                  sample.p95 - previous > Budget.sendClickRegressionFloorNanoseconds
            else { continue }

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
