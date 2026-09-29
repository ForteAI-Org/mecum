//
//  ToggleStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import PerceptionCore

/// ToggleStep is a remembered toggle: bring the control labelled `control` to `state`, `on` or `off`.
/// It remembers the state to reach, never a click: whether a click is needed is decided by reading the
/// control again. It is proven by `ToggleEvidence`, which must read the other definite state before,
/// a click sent, and the requested state after, and asked for by a request `ToggleGoal` reads as that
/// single state.
public struct ToggleStep: Sendable, Hashable {

    /// The label the control showed when the step was verified.
    public let control: String

    /// The panel the request named to narrow the control, nil when the request named none.
    public let section: String?

    /// The state to reach: `on` or `off`.
    public let state: ControlState

    public init(control: String, section: String?, state: ControlState) {
        self.control = control
        self.section = section
        self.state   = state
    }

    /// The step a toggle's evidence describes. A panel is kept only when the request named one, so an
    /// experience never depends on a panel name nobody asked for, and it is the panel the evidence
    /// observed under that name (`ExperienceStep.place(named:section:container:)`).
    public init(_ evidence: ToggleEvidence, requestedSection: String?) {
        self.init(control: evidence.control,
                  section: ExperienceStep.place(named: requestedSection, section: evidence.section,
                                                container: evidence.container),
                  state: evidence.desiredState)
    }
}

extension ToggleStep: LearnableStep {

    var tool: ExperienceStep.Tool { .setToggle }

    /// A toggle's arguments are `set_toggle`'s: its target, its value and its section.
    var arguments: [String: String] {
        var arguments = ["target": control, "value": state.rawValue]
        if let section { arguments["section"] = section }
        return arguments
    }

    var terms: Set<String> { Set(GoalPhrase.tokens(control) + GoalPhrase.tokens(section ?? "")) }

    var summary: String { "set '\(control)'\(section.map { " in '\($0)'" } ?? "") \(state.rawValue)" }

    var key: String {
        [ExperienceStep.Tool.setToggle.rawValue, LabelText.normalize(control), LabelText.normalize(section ?? ""),
         state.rawValue].joined(separator: "|")
    }

    var experienceStep: ExperienceStep { .setToggle(self) }

    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws {
        try container.encodeIfPresent(section, forKey: .section)
        try container.encode(state, forKey: .state)
    }

    init(
        control       : String,
        tool          : ExperienceStep.Tool,
        from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>
    ) throws {
        let state = try container.decode(ControlState.self, forKey: .state)
        guard state == .on || state == .off else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: container,
                                                   debugDescription: "a toggle step reaches on or off")
        }
        let section = try container.decodeIfPresent(String.self, forKey: .section)
        self.init(control: control, section: section, state: state)
    }

    // MARK: Admission

    static var admission: TurnAdmission.Reason { .admittedSingleToggle }

    static func evidence(in proof: ActEvidence) -> ToggleEvidence? { proof.toggle }

    init(proving evidence: ToggleEvidence, for call: ActionArguments) {
        self.init(evidence, requestedSection: call.section)
    }

    /// A toggle is verified only by its readings: `found_acted` after a proven change, or the
    /// `acted_noop` of a control that already read the state, which is kept but never learned.
    static func unverified(_ evidence: ToggleEvidence, kind: ActOutcomeKind) -> TurnAdmission.Reason? {
        let expectedKind: ActOutcomeKind = evidence.change == .alreadySet ? .actedNoop : .foundActed
        guard evidence.isVerified, kind == expectedKind else { return .notVerified }
        guard evidence.change == .changed else { return .alreadySet }
        return nil
    }

    /// The section the call named must be the control's section or container as observed.
    static func isAnswered(_ call: ActionArguments, by evidence: ToggleEvidence) -> Bool {
        TurnAdmission.names(call.target, evidence.control) && call.desiredState == evidence.desiredState
            && (call.section == nil || observedSection(call, evidence) != nil)
    }

    /// The goal must name the section the call narrowed the control to, as the remembered step keeps it.
    static func goalRefusal(
        _ request: String,
        call     : ActionArguments,
        evidence : ToggleEvidence
    ) -> TurnAdmission.Reason? {
        ToggleGoal.classify(request, control: evidence.control, section: observedSection(call, evidence),
                            windows: evidence.windowTitles)
            .refusal { state in state == evidence.desiredState ? nil : .stateNotInGoal }
    }

    func isRepeated(by other: ToggleStep) -> Bool {
        TurnAdmission.names(other.control, control) && other.state == state
            && TurnAdmission.names(other.section ?? "", section ?? "")
    }

    /// The panel the proof observed under the name the call gave, nil when the call gave none or the
    /// proof does not support it.
    private static func observedSection(_ call: ActionArguments, _ evidence: ToggleEvidence) -> String? {
        ExperienceStep.place(named: call.section, section: evidence.section, container: evidence.container)
    }

    // MARK: Recall

    /// A toggle is found only by a request for its own state on its control (`ToggleGoal.single`),
    /// however it is phrased: goal words alone cannot tell on from off.
    func recallMatch(
        _ request: String,
        tokens   : Set<String>,
        in record: ExperienceRecord
    ) -> (match: Recall.Match, isGoal: Bool)? {
        let goal = ToggleGoal.classify(request, control: control, section: section,
                                       windows: record.latestProof?.windowTitles ?? [])
        guard case .single(let asked) = goal, asked == state else { return nil }
        return Self.goalMatch(tokens, in: record)
    }

    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution] {
        [scene.resolve(target: control, preferStateful: true, section: section)]
    }

    var sightedLabels: [String] { [control] }

    var briefing: RecallBriefing.StepDetail {
        RecallBriefing.StepDetail(state: state.rawValue, section: section, guidance: " A remembered toggle is a state "
            + "to reach, not a click: use act with verb set_toggle and the remembered value, which reads the "
            + "current state and does nothing when it already matches.")
    }
}
