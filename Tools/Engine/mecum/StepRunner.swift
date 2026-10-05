//
//  StepRunner.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// StepResult is what one step did: the outcome the engine decided and what its call's recorder left.
struct StepResult {
    let outcome: ActOutcome
    let report: CallRecorder.Report?
}

/// StepPerforming is what runs a decoded action for a vertical command: the engine over the command's
/// own Seat or screen (`EngineStepPerformer`), or a controlled stand-in in the tests. It records the
/// step's samples under `context` through the call's recorder, and never records the call itself:
/// that is `StepRunner`'s, so the call's states are the same whatever performs it.
@MainActor
protocol StepPerforming: AnyObject {

    /// Checked before each step of a batch, once the step is started and before it acts: the window
    /// and Seat the batch began with must still be there.
    func checkTarget() throws

    /// Runs one decoded action under `context`; `evidence` is where its captures go, when asked.
    func perform(_ request: AgentCallRequest, context: ActionContext, evidence: String?) async throws -> StepResult
}

/// StepRunner records and runs a vertical command's actions as the tools record theirs: a call is
/// planned and started before any effect, the task's cancellation ending it there (nothing runs);
/// the action runs once; the call is concluded with the outcome and the effect the engine observed,
/// or failed with the error, or cancelled. A batch is planned with every step as its child, each step
/// started as it is reached, the rest `skipped` once it stops, and the batch concluded with its
/// summary: `found_acted` goes on, `acted_noop` goes on only for `set_toggle`, anything else, an
/// error or a cancellation stops it, earlier effects remain and nothing is replayed.
///
/// A stop of the invocation (`VerticalInvocation`) is the task's cancellation: a call not yet started
/// never runs, a batch runs no further step, and a call it catches mid-way is concluded as far as is
/// known. Only a process that dies (SIGKILL, a crash) leaves a call `planned` or `started` in the
/// memory, which the diagnosis reads as such.
@MainActor
enum StepRunner {

    /// Where the runner writes what a person reads; standard output in the product.
    typealias Output = (String) -> Void

    /// Runs one action as a call of its own and answers its outcome.
    static func single(
        _ request: AgentCallRequest,
        performer: any StepPerforming,
        memory   : MemoryService,
        trace    : CLITrace,
        app      : AppContextIdentity?,
        evidence : String? = nil,
        output   : Output = { print($0) }
    ) async throws -> ActOutcome {
        let call = CLICall(memory: memory, request: request, context: trace.context(request.tool), app: app)
        try await call.begin()
        let result: StepResult
        do {
            result = try await performer.perform(request, context: call.context, evidence: evidence)
        } catch {
            await call.fail(error)
            throw error
        }
        show(result.outcome, output)
        if let report = result.report { call.say(report) }
        await call.complete(.outcome(result.outcome.kind, message: result.outcome.message), effect: result.report?.effect)
        return result.outcome
    }

    /// What a batch did: how many steps ran and how many the rule accepted.
    struct BatchSummary: Equatable {
        let attempted: Int
        let verified: Int
    }

    /// Runs the steps in order in one batch call, stopping at the first one the rule does not accept.
    /// Throws `BatchFailure` for a stop, with the step and the cause, after the batch is concluded.
    @discardableResult
    static func batch(
        _ steps  : [BatchStep],
        performer: any StepPerforming,
        memory   : MemoryService,
        trace    : CLITrace,
        app      : AppContextIdentity?,
        evidence : String? = nil,
        output   : Output = { print($0) }
    ) async throws -> BatchSummary {
        let batch = CLICall(memory: memory, request: .batch, context: trace.context(.batch), app: app)
        let calls = steps.enumerated().map { position, step in
            CLICall(memory: memory, request: step.request,
                    context: trace.context(step.request.tool, parent: batch.context, position: position), app: app)
        }
        try await CLICall.begin(batch: batch, steps: calls)
        var attempted = 0, verified = 0
        // The last step concluded (it ran, failed or was cancelled); the ones after it never ran.
        var concluded = -1
        do {
            try await BatchSequence.run(steps) { number, step in
                let call = calls[number - 1]
                concluded = number - 1
                do {
                    try await call.beginStep()
                } catch {
                    // Cancelled before any effect of this step: the step and the rest never run.
                    await call.fail(error)
                    throw error
                }
                attempted += 1
                do {
                    try performer.checkTarget()
                    output("batch: step \(number)/\(steps.count): \(step.summary)")
                    let folder = evidence.map { ($0 as NSString).appendingPathComponent("step-\(number)") }
                    let result = try await performer.perform(step.request, context: call.context, evidence: folder)
                    show(result.outcome, output)
                    if let report = result.report { call.say(report) }
                    await call.complete(.outcome(result.outcome.kind, message: result.outcome.message),
                                        effect: result.report?.effect)
                    if step.accepts(result.outcome.kind) { verified += 1 }
                    return result.outcome.kind
                } catch {
                    await call.fail(error)
                    throw error
                }
            }
        } catch {
            let cause = (error as? BatchFailure)?.cause ?? error
            for call in calls.dropFirst(concluded + 1) { await call.skip() }
            if MemoryService.isCancellation(cause) {
                await batch.fail(cause)
            } else {
                await batch.complete(.batch(stopped: true, attempted: attempted, verified: verified))
            }
            throw error
        }
        await batch.complete(.batch(stopped: false, attempted: attempted, verified: verified))
        output("batch: completed \(steps.count)/\(steps.count) steps")
        return BatchSummary(attempted: attempted, verified: verified)
    }

    private static func show(_ outcome: ActOutcome, _ output: Output) {
        output("\(outcome.kind.rawValue): \(outcome.message)")
        if let scene = outcome.scene {
            output("")
            output(scene.text())
        }
    }
}
