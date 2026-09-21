import Foundation
import LocatorCore

/// Relocates an element (the recall cascade), abstracted so the runner is testable.
public protocol StepRelocating: Sendable {
    func relocate(_ descriptor: Descriptor) async -> RelocationResult
}

/// Focuses an app and actuates a resolved element (AXPress or synthetic click).
public protocol StepActuating: Sendable {
    func focus(bundleID: String) async
    func actuate(descriptor: Descriptor, result: RelocationResult) async -> Bool
}

public struct FlowRunReport: Sendable, Equatable {
    public struct StepResult: Sendable, Equatable {
        public var index: Int
        public var method: RelocationResult.Method
        public var relocated: Bool
        public var actuated: Bool
    }
    public var steps: [StepResult]
    public var allActuated: Bool { !steps.isEmpty && steps.allSatisfy { $0.actuated } }
}

/// Plays a recorded flow: focus the app, then relocate + actuate each step in order, with a delay
/// between steps. By default (`stopOnMiss`) the run ABORTS at the first step that doesn't actuate —
/// in a flow whose own clicks drive the UI forward, a step that can't act means the screen the rest
/// of the flow expects never appeared, so continuing would click into the wrong UI. Pass
/// `stopOnMiss: false` for a flow of independent steps where partial replay is preferable.
public struct FlowRunner: Sendable {
    let relocator: any StepRelocating
    let actuator: any StepActuating

    public init(relocator: any StepRelocating, actuator: any StepActuating) {
        self.relocator = relocator
        self.actuator = actuator
    }

    public func run(
        _ flow: Flow,
        descriptors: [UUID: Descriptor],
        stepDelaySeconds: Double = 0.5,
        focusSettleSeconds: Double = 0.3,
        stopOnMiss: Bool = true,
        onStep: (@Sendable (FlowRunReport.StepResult) -> Void)? = nil
    ) async -> FlowRunReport {
        await actuator.focus(bundleID: flow.bundleID)
        if focusSettleSeconds > 0 { try? await Task.sleep(for: .seconds(focusSettleSeconds)) }

        var results: [FlowRunReport.StepResult] = []
        for (i, id) in flow.stepIDs.enumerated() {
            let result: FlowRunReport.StepResult
            if let descriptor = descriptors[id] {
                let reloc = await relocator.relocate(descriptor)
                let relocated = reloc.isHit
                let actuated = relocated ? await actuator.actuate(descriptor: descriptor, result: reloc) : false
                result = .init(index: i, method: reloc.method, relocated: relocated, actuated: actuated)
            } else {
                result = .init(index: i, method: .notFound, relocated: false, actuated: false)
            }
            results.append(result)
            onStep?(result)
            // Abort on a step that didn't ACTUATE (not merely "didn't relocate"): an `.offscreen`
            // outcome reports relocated=true yet clicks nothing, and a later step usually depends on
            // this one's action — continuing would act against the wrong/unchanged UI.
            if stopOnMiss, !result.actuated { break }
            if i < flow.stepIDs.count - 1, stepDelaySeconds > 0 { try? await Task.sleep(for: .seconds(stepDelaySeconds)) }
        }
        return FlowRunReport(steps: results)
    }
}
