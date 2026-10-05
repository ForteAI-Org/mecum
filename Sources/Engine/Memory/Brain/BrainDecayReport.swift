//
//  BrainDecayReport.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation

/// AnchorRetirementCause is the rule of `BrainUpdater.decay` that dropped an anchor, in the order
/// the rules are evaluated: the wall-clock backstop, staleness, a transient, the cap. The raw
/// values are the vocabulary the living memory stores in `brain_anchors.retirement_cause`.
public enum AnchorRetirementCause: String, Sendable, Equatable, Hashable, CaseIterable {
    case transient, stale, backstop, cap
}

/// GroupRetirementCause is the rule that dissolved a sibling group: fewer than three members left,
/// staleness, or the backstop. Raw values as stored in `brain_groups.retirement_cause`.
public enum GroupRetirementCause: String, Sendable, Equatable, Hashable, CaseIterable {
    case members, stale, backstop
}

/// TransitionRetirementCause is the rule that dropped a learned transition: its anchor went, the
/// backstop, staleness, or an evidence-one coincidence. Raw values as stored in
/// `brain_transitions.retirement_cause`.
public enum TransitionRetirementCause: String, Sendable, Equatable, Hashable, CaseIterable {
    case anchor, stale, coincidence, backstop
}

/// DecayReport is what one `BrainUpdater.decay` removed and under which rule, recorded as the
/// algorithm evaluates its rules, so a projection can retire the same rows with the cause the
/// algorithm had rather than a cause guessed from a missing row. The report changes no result:
/// decay keeps and drops exactly what it kept and dropped before it existed.
public struct DecayReport: Sendable, Equatable {

    /// Anchors dropped, by key.
    public var anchors: [String: AnchorRetirementCause]

    /// Groups dissolved, by id.
    public var groups: [UUID: GroupRetirementCause]

    /// Transitions dropped, by the triple evidence accumulates under.
    public var transitions: [LearnedTransition.Key: TransitionRetirementCause]

    public init(
        anchors    : [String: AnchorRetirementCause] = [:],
        groups     : [UUID: GroupRetirementCause] = [:],
        transitions: [LearnedTransition.Key: TransitionRetirementCause] = [:]
    ) {
        self.anchors     = anchors
        self.groups      = groups
        self.transitions = transitions
    }

    /// True when the decay dropped nothing.
    public var isEmpty: Bool { anchors.isEmpty && groups.isEmpty && transitions.isEmpty }
}
