//
//  ClickStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import EngineCore
import PerceptionCore

/// ClickStep is a remembered pointer gesture: perform `gesture` on the element labelled `target`,
/// with an opening or closure effect. It remembers semantic labels, never coordinates: the target is
/// resolved again and the effect verified again every time. It is proven by `ClickEvidence`, which
/// must attribute that one surface to the gesture, and asked for by a request `ClickGoal` reads as
/// that single gesture.
public struct ClickStep: Sendable, Hashable {

    public let gesture: ClickEvidence.Gesture

    /// The label of the element the gesture was performed on.
    public let target: String

    /// The panel the request named to narrow the target, nil when the request named none.
    public let section: String?

    /// The mutually exclusive opening or closure a fresh execution must verify again.
    public enum Effect: Sendable, Hashable {
        case opens(ClickEvidence.Surface)
        case closesWindow(String)
    }

    public let effect: Effect

    public var opens: ClickEvidence.Surface? {
        if case .opens(let surface) = effect { surface } else { nil }
    }

    public var closes: String? {
        if case .closesWindow(let title) = effect { title } else { nil }
    }

    public init(_ gesture: ClickEvidence.Gesture, target: String, section: String?, opens: ClickEvidence.Surface) {
        self.init(gesture, target: target, section: section, effect: .opens(opens))
    }

    public init(_ gesture: ClickEvidence.Gesture, target: String, section: String?, effect: Effect) {
        self.gesture = gesture
        self.target = target
        self.section = section
        self.effect = effect
    }

    /// The step a click's evidence describes, or nil when no surface is attributed to it. A panel is
    /// kept as for a toggle (`ToggleStep.init(_:requestedSection:)`).
    public init?(_ evidence: ClickEvidence, requestedSection: String?) {
        let effect: Effect
        if let surface = evidence.surface { effect = .opens(surface) }
        else if let title = evidence.closedWindow { effect = .closesWindow(title) }
        else { return nil }
        self.init(evidence.gesture, target: evidence.target,
                  section: ExperienceStep.place(named: requestedSection, section: evidence.section,
                                                container: evidence.container),
                  effect: effect)
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
        "\(gesture.rawValue) '\(target)'\(section.map { " in '\($0)'" } ?? "")"
            + (opens.map { " to open " + $0.summary } ?? " to close the window '\(closes ?? "")'")
    }

    var key: String {
        [tool.rawValue, LabelText.normalize(target), LabelText.normalize(section ?? ""), effectKey]
            .joined(separator: "|")
    }

    private var effectKey: String {
        opens.map(Self.surfaceKey) ?? "closes:" + LabelText.letters(closes ?? "")
    }

    var experienceStep: ExperienceStep { .click(self) }

    /// Keep the existing opening format; closures use their own mutually exclusive `closes` field.
    func encodeFields(to container: inout KeyedEncodingContainer<ExperienceStep.CodingKeys>) throws {
        try container.encodeIfPresent(section, forKey: .section)
        try container.encodeIfPresent(opens, forKey: .opens)
        try container.encodeIfPresent(closes, forKey: .closes)
    }

    init(
        control       : String,
        tool          : ExperienceStep.Tool,
        from container: KeyedDecodingContainer<ExperienceStep.CodingKeys>
    ) throws {
        let opens = try container.decodeIfPresent(ClickEvidence.Surface.self, forKey: .opens)
        let closes = try container.decodeIfPresent(String.self, forKey: .closes)
        let effect: Effect
        switch (opens, closes) {
            case (.some(let surface), nil): effect = .opens(surface)
            case (nil, .some(let title)) where !title.isEmpty: effect = .closesWindow(title)
            default:
                throw DecodingError.dataCorruptedError(forKey: .opens, in: container,
                                                       debugDescription: "Expected one opening or closure effect")
        }
        self.init(try container.decode(ClickEvidence.Gesture.self, forKey: .tool), target: control,
                  section: try container.decodeIfPresent(String.self, forKey: .section), effect: effect)
    }

    // MARK: Admission

    static var admission: TurnAdmission.Reason { .admittedSingleClick }

    static func evidence(in proof: ActEvidence) -> ClickEvidence? { proof.click }

    init?(proving evidence: ClickEvidence, for call: ActionArguments) {
        self.init(evidence, requestedSection: call.section)
    }

    /// A click is verified only by the surface attributed to it, never by a `found_acted` alone.
    static func unverified(_ evidence: ClickEvidence, kind: ActOutcomeKind) -> TurnAdmission.Reason? {
        evidence.isVerified && kind == .foundActed ? nil : .notVerified
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
                if asked.closes && evidence.closedWindow == nil { return .surfaceNotInGoal }
                if let opens = asked.opens, evidence.surface.map({ opens.matches($0) }) != true {
                    return .surfaceNotInGoal
                }
                return nil
            }
    }

    func isRepeated(by other: ClickStep) -> Bool {
        other.gesture == gesture && TurnAdmission.names(other.target, target)
            && TurnAdmission.names(other.section ?? "", section ?? "")
            && other.effectKey == effectKey
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
        guard case .single(let asked) = goal, asked.gesture == gesture,
              !asked.closes || closes != nil,
              asked.opens == nil || opens.map({ asked.opens?.matches($0) == true }) == true else { return nil }
        return Self.goalMatch(tokens, in: record)
    }

    func resolutions(in scene: SceneSnapshot) -> [SceneSnapshot.Resolution] {
        [scene.resolve(target: target, section: section, preferNativeControls: gesture != .rightClick)]
    }

    var sightedLabels: [String] { [target] }

    var briefing: RecallBriefing.StepDetail {
        RecallBriefing.StepDetail(section: section, opens: opens?.summary, closes: closes, guidance: " A remembered \(tool.rawValue) "
            + "is an effect to check, not a replay: use act with verb \(tool.rawValue) on the target resolved in "
            + "the current scene, then verify its opening or closure from the tool's typed evidence.")
    }
}
