//
//  ClickStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import PerceptionCore

/// ClickStep is a remembered pointer gesture: perform `gesture` on the element labelled `target`,
/// which opened `opens`. It remembers the gesture and what it opened, never where: the target is
/// resolved again and the effect verified again every time. It is proven by `ClickEvidence`, which
/// must attribute that one surface to the gesture, and asked for by a request `ClickGoal` reads as
/// that single gesture.
public struct ClickStep: Sendable, Hashable {

    public let gesture: ClickEvidence.Gesture

    /// The label of the element the gesture was performed on.
    public let target: String

    /// The panel the request named to narrow the target, nil when the request named none.
    public let section: String?

    /// What the gesture opened. A window is remembered by the title it showed, compared by its letters.
    public let opens: ClickEvidence.Surface

    public init(_ gesture: ClickEvidence.Gesture, target: String, section: String?, opens: ClickEvidence.Surface) {
        self.gesture = gesture
        self.target  = target
        self.section = section
        self.opens   = opens
    }

    /// The step a click's evidence describes, or nil when no surface is attributed to it. A panel is
    /// kept as for a toggle (`ToggleStep.init(_:requestedSection:)`).
    public init?(_ evidence: ClickEvidence, requestedSection: String?) {
        guard let surface = evidence.surface else { return nil }
        self.init(evidence.gesture, target: evidence.target,
                  section: ExperienceStep.place(named: requestedSection, section: evidence.section,
                                                container: evidence.container),
                  opens: surface)
    }

    /// A surface's identity: a menu, or a window by its title's letters, as window families compare.
    static func surfaceKey(_ surface: ClickEvidence.Surface) -> String {
        switch surface {
            case .menu              : "menu"
            case .window(let title) : "window:" + LabelText.letters(title)
        }
    }
}

extension ClickStep: LearnableStep {

    var tool: ExperienceStep.Tool {
        switch gesture {
            case .click      : .click
            case .doubleClick: .doubleClick
            case .tripleClick: .tripleClick
            case .rightClick : .rightClick
        }
    }

    var control: String { target }

    var arguments: [String: String] {
        var arguments = ["target": target, "verb": gesture.rawValue]
        if let section { arguments["section"] = section }
        return arguments
    }

    var terms: Set<String> { Set(GoalPhrase.tokens(target) + GoalPhrase.tokens(section ?? "")) }

    var summary: String {
        "\(gesture.rawValue) '\(target)'\(section.map { " in '\($0)'" } ?? "") to open " + opens.summary
    }

    var key: String {
        [tool.rawValue, LabelText.normalize(target), LabelText.normalize(section ?? ""), Self.surfaceKey(opens)]
            .joined(separator: "|")
    }

    var experienceStep: ExperienceStep { .click(self) }

    /// A click's surface is kept under `opens`; its target is the `control` `ExperienceStep` writes.
    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws {
        try container.encodeIfPresent(section, forKey: .section)
        try container.encode(opens, forKey: .opens)
    }

    init(
        control       : String,
        tool          : ExperienceStep.Tool,
        from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>
    ) throws {
        self.init(try container.decode(ClickEvidence.Gesture.self, forKey: .tool), target: control,
                  section: try container.decodeIfPresent(String.self, forKey: .section),
                  opens: try container.decode(ClickEvidence.Surface.self, forKey: .opens))
    }

    // MARK: Admission

    static var admission: TurnAdmission.Reason { .admittedSingleClick }

    static func evidence(in proof: ActEvidence) -> ClickEvidence? { proof.click }

    init?(proving evidence: ClickEvidence, for call: ActionArguments) {
        self.init(evidence, requestedSection: call.section)
    }

    /// A click is verified only by the surface attributed to it, never by a `found_acted` alone.
    static func unverified(_ evidence: ClickEvidence, kind: ActOutcomeKind) -> TurnAdmission.Reason? {
        evidence.isVerified && kind == .foundActed && evidence.surface != nil ? nil : .notVerified
    }

    /// The gesture the call made, on the target the evidence resolved, in the section it observed.
    static func isAnswered(_ call: ActionArguments, by evidence: ClickEvidence) -> Bool {
        TurnAdmission.names(call.target, evidence.target) && call.verb == evidence.gesture.verb
            && (call.section == nil || observedSection(call, evidence) != nil)
    }

    /// The gesture must be the one the request asks for, and a surface the request names must be the
    /// one that opened.
    static func goalRefusal(
        _ request: String,
        call     : ActionArguments,
        evidence : ClickEvidence
    ) -> TurnAdmission.Reason? {
        ClickGoal.classify(request, target: evidence.target, section: observedSection(call, evidence),
                           windows: evidence.windowTitles)
            .refusal { asked in
                guard asked.gesture == evidence.gesture else { return .gestureNotInGoal }
                if let opens = asked.opens, let surface = evidence.surface, !opens.matches(surface) {
                    return .surfaceNotInGoal
                }
                return nil
            }
    }

    func isRepeated(by other: ClickStep) -> Bool {
        other.gesture == gesture && TurnAdmission.names(other.target, target)
            && TurnAdmission.names(other.section ?? "", section ?? "")
            && Self.surfaceKey(other.opens) == Self.surfaceKey(opens)
    }

    private static func observedSection(_ call: ActionArguments, _ evidence: ClickEvidence) -> String? {
        ExperienceStep.place(named: call.section, section: evidence.section, container: evidence.container)
    }

    // MARK: Recall

    /// A click is found only by a request for its own gesture on its target (`ClickGoal.single`) that
    /// names no other surface: goal words alone cannot tell a click from a right-click.
    func recallMatch(
        _ request: String,
        tokens   : Set<String>,
        in record: ExperienceRecord
    ) -> (match: Recall.Match, isGoal: Bool)? {
        let goal = ClickGoal.classify(request, target: target, section: section,
                                      windows: record.latestProof?.windowTitles ?? [])
        guard case .single(let asked) = goal, asked.isAnswered(by: gesture, opening: opens) else { return nil }
        return Self.goalMatch(tokens, in: record)
    }

    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution] {
        [scene.resolve(target: target, section: section, preferNativeControls: gesture != .rightClick)]
    }

    var sightedLabels: [String] { [target] }

    var briefing: RecallBriefing.StepDetail {
        RecallBriefing.StepDetail(section: section, opens: opens.summary, guidance: " A remembered \(tool.rawValue) "
            + "is an effect to check, not a replay: use act with verb \(tool.rawValue) on the target resolved in "
            + "the current scene, then confirm that what it opens is there.")
    }
}
