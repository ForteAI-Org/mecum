import EngineCore
import Foundation
import Memory
import PerceptionCore

extension EngineRuntime {

    /// Feeds an existing scene through Brain and living memory, returning its enrichment.
    /// A sighting write failure is reported separately; a Brain failure remains an observation error.
    public func learn(_ scene: SceneSnapshot, in livingMemory: (any LivingMemoryStoring)?) async throws -> SceneSnapshot {
        let learning = try await SceneIntake(brain: memory, livingMemory: livingMemory).learn(from: scene)
        if case .failed(let reason) = learning.sightings { diagnoseLearning(reason) }
        return learning.scene
    }

    /// Learns from an action's existing scene. Persistence failure never changes the action verdict
    /// or repeats its effects. Transient application identities never produce durable action evidence.
    public func learn(_ outcome: ActOutcome, in livingMemory: (any LivingMemoryStoring)?) async -> ActOutcome {
        var scene = outcome.scene
        if let captured = scene {
            do { scene = try await learn(captured, in: livingMemory) }
            catch { diagnoseLearning(String(describing: error)) }
        }
        let proof = outcome.evidence.flatMap { evidence -> ActEvidence? in
            WindowContext(bundleID: evidence.bundleID, windowTitle: evidence.windowTitle) == nil ? nil : evidence
        }
        return ActOutcome(outcome.kind, outcome.message, scene: scene, evidence: proof)
    }

    private func diagnoseLearning(_ reason: String) {
        FileHandle.standardError.write(Data(("[memory] scene learning failed: " + reason + "\n").utf8))
    }
}
