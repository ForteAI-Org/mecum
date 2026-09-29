//
//  LearnableStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import PerceptionCore

/// LearnableStep is one kind of step the living memory may learn from and recall: the semantic
/// arguments it keeps, the typed evidence that proves it, what a turn's call and evidence must show
/// to teach it, how a request asks for it again, and how a fresh scene shows its target. Each
/// conformer holds every rule of its kind, so a new kind is one conformer and one case of
/// `ExperienceStep`; admission, recall and briefing read a step only through these requirements.
///
/// A conformer keeps semantic arguments only, as `ExperienceStep` documents: no session, process or
/// window number, coordinate, permission flag or image. Its current value or state is always
/// resolved and read again in a fresh scene, never taken from memory.
protocol LearnableStep: Sendable, Hashable {

    /// Evidence is the typed proof of a step of this kind.
    associatedtype Evidence: StepEvidence

    /// Call is the semantic arguments of the tool call a step of this kind is made with.
    associatedtype Call: Sendable

    // MARK: The step

    /// The tool the step is remembered by.
    var tool: ExperienceStep.Tool { get }

    /// The label of the control the step acts on, as it read when the step was verified.
    var control: String { get }

    /// The step's semantic arguments by name, in the tool's own vocabulary, the only arguments recall
    /// may ever replay from.
    var arguments: [String: String] { get }

    /// The step's own goal tokens, so recall can find a phrase that names the result rather than
    /// repeating the learned sentence.
    var terms: Set<String> { get }

    /// The step in a few words for a person.
    var summary: String { get }

    /// The step's identity for deduplication: its tool and its normalized arguments. The natural key
    /// of every stored experience of this kind includes it, so it never changes once stored.
    var key: String { get }

    /// The step as an experience remembers it.
    var experienceStep: ExperienceStep { get }

    /// Writes the step's own fields into the flat object `ExperienceStep` writes its `tool` and
    /// `control` into.
    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws

    /// Reads the step of `tool` acting on `control` from the flat object `ExperienceStep` decodes.
    init(
        control       : String,
        tool          : ExperienceStep.Tool,
        from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>
    ) throws

    // MARK: Admission

    /// The reason a single-step turn that teaches a step of this kind is admitted with.
    static var admission: TurnAdmission.Reason { get }

    /// The proof of this kind that `proof` holds, or nil when it holds another kind's.
    static func evidence(in proof: ActEvidence) -> Evidence?

    /// The step `evidence` proves for `call`, or nil when it proves none.
    init?(proving evidence: Evidence, for call: Call)

    /// Why `evidence`, reported with outcome `kind`, does not prove a change this step could teach, or
    /// nil when it does: `notVerified`, or `alreadySet` when nothing needed to change.
    static func unverified(_ evidence: Evidence, kind: ActOutcomeKind) -> TurnAdmission.Reason?

    /// Whether `call` asked for what `evidence` proves, as the proof observed it, never the call's own
    /// words handed back.
    static func isAnswered(_ call: Call, by evidence: Evidence) -> Bool

    /// Why `request` is not the single goal `call` and `evidence` prove, or nil when it is.
    static func goalRefusal(_ request: String, call: Call, evidence: Evidence) -> TurnAdmission.Reason?

    /// Whether `other`, a step proven in the same context, repeats this one.
    func isRepeated(by other: Self) -> Bool

    // MARK: Recall

    /// How `request`, whose goal tokens are `tokens`, relates to this step remembered in `record`, and
    /// whether it asks for the step's single goal; nil when it does not match or asks for another step.
    func recallMatch(
        _ request: String,
        tokens   : Set<String>,
        in record: ExperienceRecord
    ) -> (match: Recall.Match, isGoal: Bool)?

    /// What a fresh scene of the remembered window resolves the step's targets to.
    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution]

    /// The labels whose sightings in the remembered window count as the step's history.
    var sightedLabels: [String] { get }

    /// The step's fields and guidance in a briefing for a model.
    var briefing: RecallBriefing.StepDetail { get }
}

extension LearnableStep {

    /// The first reason `call`, answered with outcome `kind` and `evidence`, cannot teach this kind of
    /// step for `request`, checked from the proof inward to the goal: the proof shows a change, the call
    /// asked for what it proves, its window is attributable, and the request is that single goal.
    static func refusal(
        _ request: String,
        call     : Call,
        kind     : ActOutcomeKind,
        evidence : Evidence
    ) -> TurnAdmission.Reason? {
        if let reason = unverified(evidence, kind: kind) { return reason }
        guard isAnswered(call, by: evidence) else { return .argumentsDoNotMatchEvidence }
        guard WindowContext(bundleID: evidence.bundleID, windowTitle: evidence.windowTitle) != nil else {
            return .noAttributableContext
        }
        return goalRefusal(request, call: call, evidence: evidence)
    }

    /// How a request that asks for this act step's single goal relates to `record`: its exact phrase,
    /// or the same step however it is phrased.
    static func goalMatch(_ tokens: Set<String>, in record: ExperienceRecord) -> (match: Recall.Match, isGoal: Bool) {
        (record.draft.phraseTokens == tokens ? .exactPhrase : .sameStep, true)
    }
}

extension ActGoal.Classification {

    /// The admission refusal this verdict gives, where `single` judges what the act clause asks for.
    func refusal(_ single: (Ask) -> TurnAdmission.Reason?) -> TurnAdmission.Reason? {
        switch self {
            case .single(let ask)         : single(ask)
            case .compound, .severalSteps : .compoundGoal
            case .uncertain, .noStep      : .uncertainGoal
            case .targetNotNamed          : .controlNotInGoal
            case .sectionNotNamed         : .sectionNotInGoal
            case .qualified               : .qualifierNotInStep
        }
    }
}
