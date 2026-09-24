//
//  ExperienceStep.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import PerceptionCore

/// ExperienceStep is the one step an experience remembers, as its semantic arguments only.
///
/// The fields are the whole allowlist. A tool call's payload is never copied: its session, process
/// and window numbers, coordinates, permission flags and images have no field here. `control` is a
/// historical description, the label the control showed when the step was verified; its current
/// value is always resolved again in a fresh scene.
public struct ExperienceStep: Sendable, Hashable, Codable {

    /// The tools an experience may remember. The first milestone learns a single `select`.
    public enum Tool: String, Sendable, Hashable, Codable {
        case select
    }

    public let tool: Tool
    public let control: String
    public let item: String

    public init(tool: Tool, control: String, item: String) {
        self.tool    = tool
        self.control = control
        self.item    = item
    }

    /// The step a dropdown selection's evidence describes.
    public init(_ evidence: DropdownEvidence) {
        self.init(tool: .select, control: evidence.control, item: evidence.requestedItem)
    }

    /// The step's semantic arguments by name, the only arguments recall may ever replay from.
    public var arguments: [String: String] { ["control": control, "item": item] }

    /// The step's own goal content: the control's and the item's goal tokens, so recall can match a
    /// phrase that names the result rather than repeating the learned sentence.
    public var terms: Set<String> { Set(GoalPhrase.tokens(control) + GoalPhrase.tokens(item)) }

    /// The step's identity for deduplication: the tool and the normalized control and item.
    var key: String { [tool.rawValue, LabelText.normalize(control), LabelText.normalize(item)].joined(separator: "|") }
}
