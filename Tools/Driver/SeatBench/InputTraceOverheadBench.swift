//
//  InputTraceOverheadBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import Dispatch
import Foundation
import SeatCore
import SeatInput

/// InputTraceOverheadBench measures fixed-value trace bookkeeping against a
/// control that takes the same monotonic clock readings and retains them. It
/// performs no event construction, posting, window read or external I/O inside
/// the measured body.
@MainActor
enum InputTraceOverheadBench {

    static let name = "input-trace-overhead"

    @inline(never)
    private static func consume(_ trace: InputCommandTrace) -> UInt64 {
        var checksum = trace.commandID ^ trace.submittedAtNanoseconds
        checksum ^= UInt64(bitPattern: Int64(trace.processID))
        checksum ^= UInt64(bitPattern: Int64(trace.windowNumber))
        checksum ^= UInt64(bitPattern: trace.correlationID)
        checksum ^= trace.executionStartedAtNanoseconds ?? 0
        checksum ^= trace.firstPostAtNanoseconds ?? 0
        checksum ^= trace.lastPostAtNanoseconds ?? 0
        checksum ^= trace.completedAtNanoseconds
        checksum ^= trace.firstEventTimestamp ?? 0
        checksum ^= trace.lastEventTimestamp ?? 0
        let commandKind: UInt64 = switch trace.commandKind {
        case .key:        1
        case .text:       2
        case .insertText: 3
        case .click:      4
        case .drag:       5
        case .scroll:     6
        }
        checksum ^= commandKind
        checksum ^= consume(trace.queue)
        checksum ^= consume(trace.exclusion)
        checksum ^= consume(trace.windowVerification)
        checksum ^= consume(trace.preparation)
        checksum ^= consume(trace.settling)
        checksum ^= consume(trace.eventConstruction)
        checksum ^= consume(trace.routing)
        checksum ^= consume(trace.sending)
        checksum ^= consume(trace.restoration)
        return checksum
    }

    @inline(never)
    private static func consume(_ stage: InputTraceStage) -> UInt64 {
        var checksum = stage.startedAtNanoseconds ?? 0
        checksum ^= stage.completedAtNanoseconds ?? 0
        checksum ^= stage.workNanoseconds
        checksum ^= stage.systemCallNanoseconds
        checksum ^= stage.intentionalWaitNanoseconds
        checksum ^= stage.schedulingWaitNanoseconds
        checksum ^= stage.unattributedNanoseconds
        checksum ^= consume(stage.allocationCount)
        checksum ^= consume(stage.copyCount)
        return checksum
    }

    @inline(never)
    private static func consume(_ count: InputTraceCount) -> UInt64 {
        switch count {
        case .known(let value): UInt64(bitPattern: Int64(value))
        case .unknown:          UInt64.max
        }
    }

    @inline(never)
    private static func consumeClockControl(
        _ one  : UInt64,
        _ two  : UInt64,
        _ three: UInt64,
        _ four : UInt64,
        _ five : UInt64,
        _ six  : UInt64,
        _ seven: UInt64,
        _ eight: UInt64,
        _ nine : UInt64
    ) -> UInt64 {
        one ^ two ^ three ^ four ^ five ^ six ^ seven ^ eight ^ nine
    }

    static func run(iterations: Int, outputPath: String?) -> Bool {
        let target = WindowReference(
            processID   : 42,
            windowNumber: 7,
            frame       : .zero
        )
        let command = InputCommand.click(InputLocation(
            screenPoint       : .zero,
            windowPointFromTop: .zero
        ))

        var fullChecksum: UInt64 = 0
        let full = measure(name + "_full", iterations: iterations, warmUp: 1_000) {
            var trace = InputTraceIdentity.submitted(
                command      : command,
                window       : target,
                correlationID: 9
            )
            let execution = DispatchTime.now().uptimeNanoseconds
            trace.beginExecution(at: execution)
            let verification = DispatchTime.now().uptimeNanoseconds
            trace.recordWindowVerification(from: execution, through: verification)
            let preparation = DispatchTime.now().uptimeNanoseconds
            trace.recordPreparation(from: verification, through: preparation)
            let settle = DispatchTime.now().uptimeNanoseconds
            trace.recordSettling(from: preparation, through: settle)
            let construction = DispatchTime.now().uptimeNanoseconds
            trace.recordEventConstruction(from: settle, through: construction, copies: .known(0))
            let routing = DispatchTime.now().uptimeNanoseconds
            trace.recordRouting(from: construction, through: routing)
            let sending = DispatchTime.now().uptimeNanoseconds
            trace.recordSendSystemCall(from: routing, through: sending)
            let restoration = DispatchTime.now().uptimeNanoseconds
            trace.recordRestoration(from: sending, through: restoration)
            fullChecksum &+= consume(trace.completed(at: restoration))
        }

        var controlChecksum: UInt64 = 0
        let control = measure(name + "_control", iterations: iterations, warmUp: 1_000) {
            let one   = DispatchTime.now().uptimeNanoseconds
            let two   = DispatchTime.now().uptimeNanoseconds
            let three = DispatchTime.now().uptimeNanoseconds
            let four  = DispatchTime.now().uptimeNanoseconds
            let five  = DispatchTime.now().uptimeNanoseconds
            let six   = DispatchTime.now().uptimeNanoseconds
            let seven = DispatchTime.now().uptimeNanoseconds
            let eight = DispatchTime.now().uptimeNanoseconds
            let nine  = DispatchTime.now().uptimeNanoseconds
            controlChecksum &+= consumeClockControl(
                one,
                two,
                three,
                four,
                five,
                six,
                seven,
                eight,
                nine
            )
        }

        let attributableP50 = max(0, full.p50 - control.p50)
        let attributableP95 = max(0, full.p95 - control.p95)
        let attributableAllocations = max(
            0,
            full.allocationsPerCall - control.allocationsPerCall
        )
        let passed = attributableAllocations == 0

        print(full.line)
        print(control.line)
        print("trace checksum \(fullChecksum), control checksum \(controlChecksum)")
        print(String(
            format: "trace attributable: p50 %.0f ns, p95 %.0f ns, %.3f allocations per command",
            attributableP50,
            attributableP95,
            attributableAllocations
        ))

        if let outputPath {
            writeJSON([
                "schema_version": 1,
                "benchmark"     : name,
                "provenance"    : provenance(clock: Clock()),
                "scenario"      : "fixed-value trace construction against equal uptime clock reads; no events or I/O",
                "attributable"  : [
                    "p50"                 : attributableP50,
                    "p95"                 : attributableP95,
                    "allocations_per_call": attributableAllocations,
                ],
                "results"       : [full.json(budgetLimit: nil, passed: nil),
                                   control.json(budgetLimit: nil, passed: nil)],
            ], to: outputPath)
        }

        print(passed ? "\(name): PASS" : "\(name): FAIL")
        return passed
    }
}
