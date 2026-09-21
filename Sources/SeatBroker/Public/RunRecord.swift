import Foundation

/// One executed step as it is kept on disk: no images, just the verdict.
public struct RunStepRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let verb: String
    public let element: Int
    public let targetLabel: String
    /// What the Command came to. Optional so records written before the five
    /// outcomes existed still read back; nil there means nobody asked.
    public let outcome: ActionOutcome?
    public let sceneChanged: Bool
    public let effect: String?
    public let pixelDifference: Double?
    public let eventCount: Int
    public let milliseconds: Int
}

/// One planner run, kept across launches as evidence: what was asked, which
/// model answered, what was done and verified, and where the last frame is.
public struct RunRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case completed, blocked, failed, cancelled }

    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let app: String
    public let bundleID: String
    public let windowTitle: String
    public let goal: String
    public let provider: ModelProvider
    public let model: String
    public let effort: ReasoningEffort
    public let outcome: Outcome
    public let reason: String
    public let decisions: Int
    public let steps: [RunStepRecord]
    /// PNG of the last frame the agent saw, relative to the recording directory.
    public let finalFrameFile: String?
    /// Tokens the model reported over the whole run; nil when the provider
    /// reports none (the Codex CLI). Older records have no field at all.
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Wall-clock time spent waiting for the model, summed over decisions.
    public var modelSeconds: Double?

    public var duration: Duration { .seconds(finishedAt.timeIntervalSince(startedAt)) }
    /// Steps whose expected effect was verified. A scene that changed is not
    /// one of them, and a record written before the outcomes existed counts
    /// none: nobody asked the question there.
    public var verifiedSteps: Int { steps.filter { $0.outcome?.isVerified == true }.count }
}
