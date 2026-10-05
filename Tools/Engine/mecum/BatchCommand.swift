import AutomationRuntime
import AppKit
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SeatDriving

/// BatchCommand owns one Seat and one runtime for a sequence in the requested window. Every step was
/// decoded by the tools' decoder before adoption (`BatchPlan`); each step perceives again. A lost or
/// changed target stops the sequence instead of acting on its parent. The batch and every step are
/// recorded as the tools' batch is (`StepRunner.batch`): the steps never run are skipped, and the
/// batch concludes with the summary its steps allow.
enum BatchCommand {

    static func run(_ invocation: Invocation) async throws {
        let plan = try BatchPlan(arguments: invocation.arguments)
        let application = try ApplicationLookup.running(plan.application)
        let memory = await CLIMemory.open(plan.invocation)
        do {
            try await SeatRuntime.withSeat(application, plan.invocation) { target in
                let performer = try EngineStepPerformer(
                    runtime: Runtime(invocation: plan.invocation, seat: target, memory: memory), target: target,
                    application: application, allowsDestructive: plan.invocation.flags.contains("allow-destructive"),
                    dryRun: false, guardsWindow: true
                )
                try await StepRunner.batch(plan.steps, performer: performer, memory: memory, trace: CLITrace(),
                                           app: AppContextIdentity(application), evidence: plan.invocation.options["evidence"])
            }
        } catch {
            await memory.close()
            throw error
        }
        await memory.close()
    }
}
