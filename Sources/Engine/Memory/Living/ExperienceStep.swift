//
//  ExperienceStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import PerceptionCore

/// ExperienceStep is the one step an experience remembers, as its semantic arguments only: a
/// dropdown selection, a toggle set to a state, or a click, double-click or right-click on a target
/// and the surface it opened. Each case holds a `LearnableStep`, which carries every rule of its kind.
///
/// The cases are the whole allowlist. A tool call's payload is never copied: its session, process
/// and window numbers, coordinates, permission flags and images have no field here. A remembered
/// control is a historical description, the label it showed when the step was verified; its current
/// value or state is always resolved and read again in a fresh scene.
public enum ExperienceStep: Sendable, Hashable {

    case select(SelectionStep)
    case setToggle(ToggleStep)
    case click(ClickStep)

    /// The tools an experience may remember: a single `select`, a single `set_toggle`, or a single
    /// `click`, `double_click`, `triple_click` or `right_click`, each by its own name. No request
    /// asks for a triple-click yet, so none is admitted; the case keeps the gestures one set.
    public enum Tool: String, Sendable, Hashable, Codable {
        case select
        case setToggle   = "set_toggle"
        case click
        case doubleClick = "double_click"
        case tripleClick = "triple_click"
        case rightClick  = "right_click"
    }

    /// Choose `item` in the dropdown that read `control`.
    public static func select(control: String, item: String) -> Self {
        .select(SelectionStep(control: control, item: item))
    }

    /// Bring the toggle labelled `control`, in the panel `section` the request named, to `state`.
    public static func setToggle(control: String, section: String?, state: ControlState) -> Self {
        .setToggle(ToggleStep(control: control, section: section, state: state))
    }

    /// Perform `gesture` on the element labelled `target`, in the panel `section` the request named,
    /// which opened `opens`.
    public static func click(
        _ gesture: ClickEvidence.Gesture,
        target   : String,
        section  : String?,
        opens    : ClickEvidence.Surface
    ) -> Self {
        .click(ClickStep(gesture, target: target, section: section, opens: opens))
    }

    /// The step a dropdown selection's evidence describes.
    public init(_ evidence: DropdownEvidence) {
        self = .select(SelectionStep(evidence))
    }

    /// The step a toggle's evidence describes, with the panel the request named as the evidence observed it.
    public init(_ evidence: ToggleEvidence, requestedSection: String?) {
        self = .setToggle(ToggleStep(evidence, requestedSection: requestedSection))
    }

    /// The step a click's evidence describes, or nil when no surface is attributed to it.
    public init?(_ evidence: ClickEvidence, requestedSection: String?) {
        guard let step = ClickStep(evidence, requestedSection: requestedSection) else { return nil }
        self = .click(step)
    }

    /// The step, whichever kind it is.
    var learnable: any LearnableStep {
        switch self {
            case .select(let step)   : step
            case .setToggle(let step): step
            case .click(let step)    : step
        }
    }

    public var tool: Tool { learnable.tool }

    /// The label of the control the step acts on.
    public var control: String { learnable.control }

    /// The step's semantic arguments by name, in the tool's own vocabulary, the only arguments recall
    /// may ever replay from.
    public var arguments: [String: String] { learnable.arguments }

    /// The step's own goal content, so recall can match a phrase that names the result rather than
    /// repeating the learned sentence.
    public var terms: Set<String> { learnable.terms }

    /// The step in a few words for a person: "select 'B' in 'A'", "set 'Mute' on", or "right_click
    /// 'Track 1' to open a menu".
    public var summary: String { learnable.summary }

    /// The step's identity for deduplication: the tool and the normalized arguments.
    var key: String { learnable.key }

    /// Whether `other`, a step proven in the same context, repeats this one: the same kind of step,
    /// which says what repeating it means.
    func isRepeated(by other: ExperienceStep) -> Bool {
        switch (self, other) {
            case (.select(let step), .select(let other))      : step.isRepeated(by: other)
            case (.setToggle(let step), .setToggle(let other)): step.isRepeated(by: other)
            case (.click(let step), .click(let other))        : step.isRepeated(by: other)
            default                                            : false
        }
    }

    /// The observed panel a request's section names: the element's scene section, by the rule the
    /// resolver finds a section by, else its container. Nil when the request named no panel, or named
    /// neither of the two, which the evidence then does not support.
    static func place(named requested: String?, section: String?, container: String?) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        if let section,
           SceneSnapshot.section(named: section, answers: requested) || TurnAdmission.names(requested, section) {
            return section
        }
        if let container, TurnAdmission.names(requested, container) { return container }
        return nil
    }
}

extension ExperienceStep: Codable {

    /// A step encodes as one flat object: the `tool` discriminator, the `control` it acts on, a click's
    /// target included, and its own fields. A select is the `tool`, `control`, `item` object it has
    /// always been stored as.
    enum CodingKeys: String, CodingKey {
        case tool, control, item, section, state, opens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let control = try container.decode(String.self, forKey: .control)
        let tool = try container.decode(Tool.self, forKey: .tool)
        switch tool {
            case .select:
                self = .select(try SelectionStep(control: control, tool: tool, from: container))
            case .setToggle:
                self = .setToggle(try ToggleStep(control: control, tool: tool, from: container))
            case .click, .doubleClick, .tripleClick, .rightClick:
                self = .click(try ClickStep(control: control, tool: tool, from: container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let step = learnable
        try container.encode(step.tool, forKey: .tool)
        try container.encode(step.control, forKey: .control)
        try step.encodeFields(to: &container)
    }
}
