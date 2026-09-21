//
//  SelectedTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// SelectedTarget is the identified window chosen for the agent's next
/// observation and input, together with the generation of that choice and why
/// it was made.
///
/// Being selected is not being ready. Identity, containment, an up-to-date Frame
/// of this same window and every other cause of the gate are checked separately,
/// and a Selected Target that satisfies none of them is still the selected one.
///
/// The generation is the versioned observational boundary: it advances whenever
/// the selection moves to a different surface or is given up. A consumer that
/// observed the target under one generation cannot act under another, which is
/// what stops A to B to A from reviving the observation taken of the first A.
nonisolated package struct SelectedTarget: Sendable, Equatable {

    /// Why this surface is the selected one, kept so that a report can tell an
    /// automatic choice from the consumer's own and from a return.
    nonisolated package enum Reason: String, Sendable, Equatable {

        /// It carries the most recent qualified appearance, reappearance or
        /// return to the front.
        case qualifiedRecency

        /// It is the one eligible surface left, with nothing to order against.
        case onlyCandidate

        /// A dialog closed and this is the parent it was attested to belong to.
        case returnToParent

        /// The consumer chose it explicitly.
        case explicitChoice
    }

    package let surface   : WindowIdentity
    package let generation: UInt64
    package let reason    : Reason

    package init(surface: WindowIdentity, generation: UInt64, reason: Reason) {
        self.surface    = surface
        self.generation = generation
        self.reason     = reason
    }
}

/// TargetObservationClaim is what a consumer hands back to say which selection
/// its observation was taken of: the surface, the selection generation it was
/// taken under, and the frame the surface had at that moment.
///
/// It is not an Observation Reference and it carries no Frame. This nucleus
/// creates neither: it answers whether what the consumer observed is still the
/// current selection of the current window at its current geometry, and that
/// answer authorizes nothing by itself. Binding a Command to an observation is
/// the admission step's work, with its own age profile and its own gate.
nonisolated package struct TargetObservationClaim: Sendable, Equatable {

    package let surface            : WindowIdentity
    package let selectionGeneration: UInt64

    /// The window's frame when the observation was taken, compared against the
    /// membership reading so a Frame of a window that has since moved is stale.
    package let frame: CGRect

    package init(surface: WindowIdentity, selectionGeneration: UInt64, frame: CGRect) {
        self.surface             = surface
        self.selectionGeneration = selectionGeneration
        self.frame               = frame
    }
}
