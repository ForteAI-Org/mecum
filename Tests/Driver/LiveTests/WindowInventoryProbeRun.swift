//
//  WindowInventoryProbeRun.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// WindowInventoryProbeRun walks the phase plan, takes one reading pair after
/// each phase, and ends with a bounded cleanup and a report.
///
/// It is the whole of the probe's logic and it holds no AppKit and no window
/// list of its own: the fixture and the reader are roles, which is what lets the
/// Live suite and an offline test run the very same code. The order is fixed and
/// there is no retry: a phase that failed stops the plan rather than being
/// attempted again over a residue the run has not accounted for, and every phase
/// that did not run is still written down.
///
/// The deadline is checked against a monotonic clock **at each point that admits
/// a native operation**, and the instant compared is the very instant recorded
/// for that operation: the `began` of a window command and the `started` of a
/// reading. Neither can therefore be issued at or after the deadline. Checking
/// earlier — once in `execute`, before the phase, or once per pair — is not
/// enough, and both counterexamples are exact. With a clock starting at 0 and
/// stepping by 1, a phase budget of 4 ns and the plan `[.createNeverPresented]`,
/// the guard after the command sees 3 and the all reading is then measured as
/// starting at 4, which is the deadline: that call must not leave, and the pair
/// records an unavailable reading instead. With a clock stepping by 5 and a
/// budget of 10 ns, the guard before the phase sees 5 and the command is then
/// measured as beginning at 10, which is the deadline: that command must not be
/// requested either, and the phase is written down as not run.
///
/// A synchronous call that is already blocked is not preempted by any of this:
/// the deadline bounds what the run begins, never what the system is in the
/// middle of doing, and the report states that instead of implying a timeout the
/// run cannot enforce.
@MainActor
struct WindowInventoryProbeRun {

    let fixture   : any ProbeWindowOperating
    let reader    : any InventoryRowsReading
    let clock     : any ProbeClock
    let budget    : ProbeBudget
    let provenance: ProbeRunProvenance
    let plan      : [ProbePhaseStep]

    init(
        fixture   : any ProbeWindowOperating,
        reader    : any InventoryRowsReading,
        clock     : any ProbeClock,
        budget    : ProbeBudget         = .diagnosticDefault,
        provenance: ProbeRunProvenance,
        plan      : [ProbePhaseStep]    = ProbePhaseStep.standardPlan
    ) {
        self.fixture    = fixture
        self.reader     = reader
        self.clock      = clock
        self.budget     = budget
        self.provenance = provenance
        self.plan       = plan
    }

    func execute() -> WindowInventoryProbeReport {

        let startedAt = clock.nowNanoseconds
        let deadline  = Self.deadline(from: startedAt, after: budget.phaseNanoseconds)

        var phases  : [ProbePhaseRecord]    = []
        var pairs   : [InventoryReadingPair] = []
        var failures: [String]              = []
        var stop                            = ProbeStopReason.planCompleted
        var haltReason: String?             = nil

        for (index, step) in plan.enumerated() {

            if let haltReason {
                phases.append(.notRun(index: index, step: step, reason: haltReason))
                continue
            }
            if clock.nowNanoseconds >= deadline {
                let reason = "the phase deadline of \(budget.phaseNanoseconds) ns was reached "
                    + "before this phase started"
                stop       = record(stop, as: .phaseDeadlineReached)
                haltReason = reason
                phases.append(.notRun(index: index, step: step, reason: reason))
                continue
            }
            if pairs.count >= budget.maximumPairs {
                let reason = "the cap of \(budget.maximumPairs) reading pairs was reached "
                    + "before this phase started"
                stop       = record(stop, as: .sampleCapReached)
                haltReason = reason
                phases.append(.notRun(index: index, step: step, reason: reason))
                continue
            }

            let began = clock.nowNanoseconds

            // The same admission the readings use, applied to the window
            // operation: the instant written down as this phase's start is the
            // instant compared with the deadline, so no AppKit command is
            // requested on a budget that is already spent. The guard above ran
            // before this measurement and cannot stand in for it.
            guard began < deadline else {
                let reason = "the phase deadline of \(budget.phaseNanoseconds) ns had passed at "
                    + "\(began) ns, so phase \(step.rawValue) was not requested"
                stop       = record(stop, as: .phaseDeadlineReached)
                haltReason = reason
                phases.append(.notRun(index: index, step: step, reason: reason))
                continue
            }

            do {
                let state = try fixture.perform(step)
                let ended = clock.nowNanoseconds

                // The command returned; the budget may have gone with it. No
                // reading is started after that, and the phase is recorded as
                // incomplete rather than as a phase with a missing pair.
                guard ended < deadline else {
                    let reason = "the phase deadline of \(budget.phaseNanoseconds) ns passed "
                        + "during phase \(step.rawValue), so no reading was started after it"
                    stop       = record(stop, as: .phaseDeadlineReached)
                    haltReason = reason
                    phases.append(
                        ProbePhaseRecord(
                            index               : index,
                            step                : step,
                            requestedCommand    : step.requestedCommand,
                            startedAtNanoseconds: began,
                            endedAtNanoseconds  : ended,
                            outcome             : .incomplete(reason),
                            sampleIndex         : nil
                        )
                    )
                    continue
                }

                let pair = sample(index: pairs.count, phaseIndex: index, deadline: deadline)
                pairs.append(pair)
                phases.append(
                    ProbePhaseRecord(
                        index               : index,
                        step                : step,
                        requestedCommand    : step.requestedCommand,
                        startedAtNanoseconds: began,
                        endedAtNanoseconds  : ended,
                        outcome             : .performed(state),
                        sampleIndex         : pair.sampleIndex
                    )
                )
            } catch {
                let ended = clock.nowNanoseconds
                let text  = "\(step.rawValue): \(error)"
                failures.append(text)
                stop       = record(stop, as: .operationFailed)
                haltReason = "phase \(step.rawValue) failed and left a residue this run has not "
                    + "accounted for, so the plan stopped here"
                phases.append(
                    ProbePhaseRecord(
                        index               : index,
                        step                : step,
                        requestedCommand    : step.requestedCommand,
                        startedAtNanoseconds: began,
                        endedAtNanoseconds  : ended,
                        outcome             : .failed(text),
                        sampleIndex         : nil
                    )
                )
            }
        }

        // The last phase has no phase after it to check the deadline for it, so
        // a plan whose readings crossed the budget says so instead of reporting
        // a completed plan.
        if haltReason == nil, clock.nowNanoseconds >= deadline {
            stop = record(stop, as: .phaseDeadlineReached)
        }

        // Cleanup has its own budget, so a plan that spent the phase deadline
        // still gets a bounded chance to release what it created.
        let cleanupDeadline = Self.deadline(
            from : clock.nowNanoseconds,
            after: budget.cleanupNanoseconds
        )
        let cleanup         = fixture
            .cleanUp(deadlineNanoseconds: cleanupDeadline)
            .preserving(priorErrors: failures)

        return WindowInventoryProbeReport.make(
            provenance: provenance,
            phases    : phases,
            pairs     : pairs,
            stopReason: stop,
            cleanup   : cleanup
        )
    }

    /// One sample: the all reading and then the on-screen reading, parsed
    /// against the Window IDs the fixture has registered by now.
    ///
    /// Both members go through the same admission, because each of them is a
    /// synchronous native call of unknown duration and the first one may spend
    /// the rest of the budget by itself. A pair whose member was never started
    /// keeps whatever the other member produced and says the missing one was not
    /// performed, which is not the same finding as an empty list.
    private func sample(index: Int, phaseIndex: Int, deadline: UInt64) -> InventoryReadingPair {
        let parser = WindowInventoryRowParser(
            fixtureWindowIDs: fixture.ownedWindowIDs,
            fixtureProcessID: fixture.processID
        )
        let all      = reading(scope: .all, parser: parser, deadline: deadline)
        let onScreen = reading(scope: .onScreenOnly, parser: parser, deadline: deadline)
        return InventoryReadingPair(
            runID      : provenance.runID,
            sampleIndex: index,
            phaseIndex : phaseIndex,
            all        : all,
            onScreen   : onScreen
        )
    }

    /// One reading, admitted or refused at the very instant it is measured from.
    ///
    /// `started` is read once: it is both the measurement written into the
    /// reading and the value compared with the deadline. A reading refused here
    /// never reaches `reader.rows`, so the report cannot contain a native call
    /// that left at or after the budget was spent, and the refusal is recorded
    /// as `unavailable` rather than as an empty list.
    private func reading(
        scope   : InventoryReadingScope,
        parser  : WindowInventoryRowParser,
        deadline: UInt64
    ) -> InventoryReading {
        let started = clock.nowNanoseconds
        guard started < deadline else {
            return InventoryReading(
                scope               : scope,
                apiName             : reader.apiName,
                optionBits          : reader.optionBits(for: scope),
                relativeToWindowID  : reader.relativeToWindowID,
                startedAtNanoseconds: started,
                endedAtNanoseconds  : started,
                outcome             : .unavailable(
                    "the phase deadline of \(budget.phaseNanoseconds) ns had passed at "
                        + "\(started) ns, so the \(scope.rawValue) reading of this pair was "
                        + "not started"
                )
            )
        }
        let response = reader.rows(scope: scope)
        let ended    = clock.nowNanoseconds
        return InventoryReading(
            scope               : scope,
            apiName             : reader.apiName,
            optionBits          : reader.optionBits(for: scope),
            relativeToWindowID  : reader.relativeToWindowID,
            startedAtNanoseconds: started,
            endedAtNanoseconds  : ended,
            outcome             : parser.outcome(of: response)
        )
    }

    /// The instant the phases must stop at, saturating instead of wrapping, so a
    /// budget close to the width of the clock cannot produce a deadline in the
    /// past.
    private static func deadline(from start: UInt64, after budget: UInt64) -> UInt64 {
        let sum = start.addingReportingOverflow(budget)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    /// The first reason a run stopped is the one that explains it. A later
    /// deadline on an already halted plan must not rewrite the failure that
    /// halted it.
    private func record(_ current: ProbeStopReason, as reason: ProbeStopReason) -> ProbeStopReason {
        current == .planCompleted ? reason : current
    }
}
