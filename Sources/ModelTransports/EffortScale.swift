//
//  EffortScale.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// EffortScale is the reasoning effort a model offers, as the detents of a
/// rail (§6.4).
///
/// The positions are `ModelSelection.supportedEfforts` exactly: not
/// normalised to four, and empty for a model with no effort parameter, which
/// then offers no level at all. Ollama's knob is thinking on or off, so its
/// scale is a switch rather than a rail.
///
/// A click, a drag and an arrow key all end in `effort(atFraction:)` or
/// `effort(from:steps:)`, which only ever answer a position of this scale,
/// so the three gestures cannot disagree and none can land between detents.
public struct EffortScale: Sendable, Hashable {

    public let provider : ModelProvider
    public let positions: [ReasoningEffort]

    public init(provider: ModelProvider, model: String) {
        self.provider  = provider
        self.positions = ModelSelection.supportedEfforts(provider: provider, model: model)
    }

    /// True when the model takes no effort parameter.
    public var isEmpty: Bool { positions.isEmpty }

    /// True when the model's only control is thinking on or off.
    public var isSwitch: Bool { provider == .ollama && positions.count == 2 }

    public func index(of effort: ReasoningEffort) -> Int? {
        positions.firstIndex(of: effort)
    }

    /// The detent `steps` away from `effort`, held at both ends. An effort not
    /// on this scale starts from the first detent. Nil on an empty scale.
    public func effort(from effort: ReasoningEffort, steps: Int) -> ReasoningEffort? {
        guard !positions.isEmpty else { return nil }
        let start = index(of: effort) ?? 0
        return positions[min(positions.count - 1, max(0, start + steps))]
    }

    /// The detent nearest a point on the rail, 0 at the first and 1 at the
    /// last, clamped outside that range. Nil on an empty scale.
    public func effort(atFraction fraction: Double) -> ReasoningEffort? {
        guard !positions.isEmpty else { return nil }
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        return positions[Int((clamped * Double(positions.count - 1)).rounded())]
    }

    /// Where `effort` sits on the rail, 0 at the first detent and 1 at the last.
    public func fraction(of effort: ReasoningEffort) -> Double {
        guard positions.count > 1, let index = index(of: effort) else { return 0 }
        return Double(index) / Double(positions.count - 1)
    }

    /// What a level trades, in processing and speed. It promises nothing about
    /// the quality of an answer, because nothing measures that per level.
    public func summary(of effort: ReasoningEffort) -> String {
        if isSwitch {
            return effort == .low ? "Answers directly, with no thinking pass: the quickest replies."
                                  : "Thinks before answering, which takes longer."
        }
        switch effort {
        case .low:    return "The least processing before answering: the quickest replies."
        case .medium: return "A balance between processing and speed."
        case .high:   return "More processing before answering, so replies take longer."
        case .xhigh:  return "Extended processing: noticeably slower replies."
        case .max:    return "The most processing this model allows: the slowest replies."
        }
    }
}
