import Foundation
import ModelTransports

/// One planned step as the model returned it, after local validation.
public struct PlanStep: Sendable, Hashable {
    public let action: SemanticAction
    public let reason: String
}

/// One model decision.
public struct PlanDecision: Sendable, Hashable {
    /// What the model wants done. `open` acts on the environment rather than
    /// on the scene: no step of it is a `SemanticAction`, because every one of
    /// those carries an index into a scene that the open is about to replace.
    public enum Status: String, Sendable, Codable { case plan, completed, blocked, open }
    public let status: Status
    public let reason: String
    public let steps: [PlanStep]
    /// The application `open` names, and nothing for any other status.
    /// Validation guarantees it is present and non-empty when status is
    /// `open`; resolving it to something launchable is the runtime's job.
    public let application: String?
}

/// What a run reports while it goes. The app renders these live.
public enum AgentRunEvent: @unchecked Sendable {
    /// The scene was observed and the model is being asked. No observation
    /// when nothing is adopted yet: the seat is empty, there is nothing to
    /// perceive, and the model is being asked what to open.
    case thinking(decision: Int, observation: SceneObservation?)
    case planned(PlanDecision, usage: ModelUsage?)
    case executed(ActionReport)
    /// Something the run measured that the person is owed and the planner does
    /// not act on; a focus recovery that succeeded is the first of them. It
    /// carries a whole sentence rather than fields, because the Seat session
    /// types stay behind the driver and only the rendered sentence crosses.
    case notice(String)
    /// The run ended: completed, blocked, or out of budget.
    case finished(status: PlanDecision.Status, reason: String, decisions: Int, actions: Int)
}
