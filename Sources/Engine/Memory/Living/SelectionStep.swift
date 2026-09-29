//
//  SelectionStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import PerceptionCore

/// SelectionStep is a remembered dropdown selection: choose `item` in the dropdown that read
/// `control`. It is proven by `DropdownEvidence`, whose readback after the menu closed must show the
/// item, and asked for by a request `SelectionGoal` reads as that single selection.
public struct SelectionStep: Sendable, Hashable {

    /// The label or value the dropdown read when the step was verified.
    public let control: String

    /// The item the step chose.
    public let item: String

    public init(control: String, item: String) {
        self.control = control
        self.item    = item
    }

    /// The step a dropdown selection's evidence describes.
    public init(_ evidence: DropdownEvidence) {
        self.init(control: evidence.control, item: evidence.requestedItem)
    }

    /// Call is a `select` call's arguments: the dropdown as the call named it, and the item.
    struct Call: Sendable {
        let control: String
        let item: String
    }
}

extension SelectionStep: LearnableStep {

    var tool: ExperienceStep.Tool { .select }

    var arguments: [String: String] { ["control": control, "item": item] }

    var terms: Set<String> { Set(GoalPhrase.tokens(control) + GoalPhrase.tokens(item)) }

    var summary: String { "select '\(item)' in '\(control)'" }

    /// A select's key is the one it has always had, so stored experiences keep their natural key.
    var key: String {
        [ExperienceStep.Tool.select.rawValue, LabelText.normalize(control), LabelText.normalize(item)]
            .joined(separator: "|")
    }

    var experienceStep: ExperienceStep { .select(self) }

    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws {
        try container.encode(item, forKey: .item)
    }

    init(
        control       : String,
        tool          : ExperienceStep.Tool,
        from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>
    ) throws {
        self.init(control: control, item: try container.decode(String.self, forKey: .item))
    }

    // MARK: Admission

    static var admission: TurnAdmission.Reason { .admittedSingleSelection }

    static func evidence(in proof: ActEvidence) -> DropdownEvidence? { proof.dropdown }

    init(proving evidence: DropdownEvidence, for call: Call) {
        self.init(evidence)
    }

    static func unverified(_ evidence: DropdownEvidence, kind: ActOutcomeKind) -> TurnAdmission.Reason? {
        guard kind == .foundActed, evidence.isVerified else { return .notVerified }
        guard evidence.change == .changed else { return .alreadySet }
        return nil
    }

    /// The call may name the dropdown by its label or by the value it showed, both as the proof read them.
    static func isAnswered(_ call: Call, by evidence: DropdownEvidence) -> Bool {
        let control = TurnAdmission.names(call.control, evidence.control)
            || TurnAdmission.names(call.control, evidence.valueBefore)
        return control && TurnAdmission.names(call.item, evidence.requestedItem)
    }

    static func goalRefusal(
        _ request: String,
        call     : Call,
        evidence : DropdownEvidence
    ) -> TurnAdmission.Reason? {
        switch SelectionGoal.classify(request, item: evidence.requestedItem, control: evidence.control,
                                      shown: evidence.valueBefore, windows: evidence.windowTitles) {
            case .single                          : nil
            case .compound, .severalSelections    : .compoundGoal
            case .uncertain, .hedged, .noSelection: .uncertainGoal
            case .itemNotNamed                    : .itemNotInGoal
            case .qualified, .unexplained         : .qualifierNotInStep
            case .itemIsOrigin                    : .itemIsOrigin
        }
    }

    func isRepeated(by other: SelectionStep) -> Bool {
        TurnAdmission.names(other.control, control) && TurnAdmission.names(other.item, item)
    }

    // MARK: Recall

    /// A selection is found by its exact goal words or by asking for the same single selection
    /// (`SelectionGoal` over the step's own item and control, so a different phrasing of the same step is
    /// found without lowering any threshold), and by the hint coverage as history only; never for a
    /// request `SelectionGoal` shows asks for another step.
    func recallMatch(
        _ request: String,
        tokens   : Set<String>,
        in record: ExperienceRecord
    ) -> (match: Recall.Match, isGoal: Bool)? {
        let goal = SelectionGoal.classify(request, item: item, control: control,
                                          shown: record.latestProof?.dropdown?.valueBefore,
                                          windows: record.latestProof?.windowTitles ?? [])
        // Phrase tokens are an unordered set without short words, so they cannot outweigh the goal.
        guard !goal.asksForAnotherStep else { return nil }
        let exact = record.draft.phraseTokens == tokens
        if goal == .single { return (exact ? .exactPhrase : .sameStep, true) }
        // Shared words without the step's single goal are history at most, never a suggestion.
        if exact { return (.exactPhrase, false) }
        if MemoryHint.coverage(of: GoalPhrase.tokens(record.phrase), by: tokens) != nil {
            return (.partialPhrase, false)
        }
        return nil
    }

    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution] {
        [control, item].map { scene.resolve(target: $0) }
    }

    var sightedLabels: [String] { [control, item] }

    var briefing: RecallBriefing.StepDetail { RecallBriefing.StepDetail(item: item) }
}
