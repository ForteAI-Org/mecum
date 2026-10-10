//
//  CommandLineBatch.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory

/// CommandLineBatch records a `mecum batch` as the tools record a batch: one call with its steps planned
/// at their positions, confirmed before the first gesture; each step started before it acts and ended by
/// its own command, with that command's check; the steps that never ran recorded as skipped once the
/// batch stops; and the batch's end with the summary its steps allow. The batch itself proves nothing:
/// only its steps carry checks. A batch the memory does not confirm does nothing; a step it does not
/// confirm is not run, and stops the batch.
enum CommandLineBatch {

    /// The call a step is, as the contract keeps it.
    static func request(of step: BatchStep) -> AgentCallRequest {
        switch step {
            case .select(let control, let item):
                .select(control: control, item: item)
            case .act(let action):
                .act(target: action.target, verb: action.verb, value: action.desiredState, section: action.section)
        }
    }

    /// Runs `steps` as one recorded batch. `prepare` checks a step before it starts (nothing acts there);
    /// `perform` runs the started step with its recorder, which its command ends.
    static func run(
        _ steps : [BatchStep],
        app     : AppContextIdentity,
        parent  : CallRecorder,
        children: [CallRecorder],
        prepare : (Int, BatchStep) async throws -> Void = { _, _ in },
        perform : (Int, BatchStep, CallRecorder) async throws -> ActOutcomeKind
    ) async throws {
        precondition(children.count == steps.count, "one recorder per step")
        do {
            try await parent.begin(batch: zip(children, steps).map { ($0, request(of: $1)) }, app: app)
        } catch {
            print("refused: Mecum's memory did not confirm the batch before it could act (\(error)); nothing was done")
            throw ActFailure(.refused)
        }
        var started = 0, verified = 0
        var stop: (any Error)?
        do {
            try await BatchSequence.run(steps) { number, step in
                try await prepare(number, step)
                do {
                    try await children[number - 1].startStep()
                } catch {
                    print("refused: Mecum's memory did not confirm step \(number) before it could act (\(error)); "
                        + "it was not run")
                    return .refused
                }
                started += 1
                let kind = try await perform(number, step, children[number - 1])
                if step.accepts(kind) { verified += 1 }
                return kind
            }
        } catch {
            stop = error
        }
        for child in children.dropFirst(started) {
            do {
                try await child.skip()
            } catch {
                print("memory: a step that never ran could not be recorded as skipped (\(error))")
            }
        }
        do {
            try await parent.end(
                .completed,
                result: .batch(stopped: started < steps.count || verified < started, attempted: started,
                               verified: verified),
                tool  : .batch
            )
            if let gap = await parent.recordingGap { print("memory: part of the batch was not recorded: \(gap)") }
        } catch {
            print("memory: the batch ran, but its record was not saved (\(error)); do not repeat it")
            if stop == nil { stop = CommandLineCall.Unsaved(reason: "\(error)") }
        }
        if let stop { throw stop }
    }
}
