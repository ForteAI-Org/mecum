import AutomationRuntime
import AppKit
import EngineCore
import Foundation
import PerceptionCore
import SeatDriving
import SeatSession
import WindowServerListing

/// BatchCommand owns one Seat and one runtime for a sequence in the requested window. Each step
/// perceives again. A lost or changed target stops the sequence instead of acting on its parent.
enum BatchCommand {

    static func run(_ invocation: Invocation) async throws {
        let plan = try BatchPlan(arguments: invocation.arguments)
        let application = try ApplicationLookup.running(plan.application)
        let processID = application.processIdentifier
        let identity = ApplicationIdentity(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            name: application.localizedName ?? "pid \(processID)"
        )
        try await SeatRuntime.withSeat(application, plan.invocation) { target in
            let original = try target.currentWindow()
            let runtime = Runtime(invocation: plan.invocation, seat: target)
            do {
                try await BatchSequence.run(plan.steps) { number, step in
                    let seat = try target.agentSeat()
                    let current = try target.currentWindow()
                    let windows = try runtime.windows.windows(ownedBy: processID)
                    guard seat.state == .ready, current.id == original.id,
                          windows.contains(where: { $0.number == original.id }) else {
                        throw UsageError.invalid(option: "window", value: original.title,
                                                 expected: "the original batch window still available in a ready Seat")
                    }
                    print("batch: step \(number)/\(plan.steps.count): \(step.summary)")
                    switch step {
                        case .select(let control, let item):
                            let directory = plan.invocation.options["evidence"].map {
                                ($0 as NSString).appendingPathComponent("step-\(number)")
                            }
                            return try await SelectCommand.perform(
                                control: control,
                                item: item,
                                identity: identity,
                                target: target,
                                invocation: plan.invocation,
                                evidenceDirectory: directory
                            )
                        case .act(let action):
                            let request = ActionRequest(
                                processID: processID,
                                bundleID: identity.bundleID,
                                appName: identity.name,
                                target: action.target,
                                verb: action.verb,
                                section: action.section,
                                desiredState: action.desiredState
                            )
                            return await ActCommand.perform(request, runtime, plan.invocation)
                    }
                }
                await runtime.finish()
            } catch {
                await runtime.finish()
                throw error
            }
            print("batch: completed \(plan.steps.count)/\(plan.steps.count) steps")
        }
    }
}
