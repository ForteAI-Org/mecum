//
//  WindowRecency.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// RecencySignal is one thing that can be reported about a surface. Three of
/// them move the Window Recency and the rest, deliberately, do not.
///
/// The five that do not are listed rather than omitted because each of them is a
/// real event that keeps being mistaken for recency: being attributed to the
/// assignment is membership, two agreeing frames are settled geometry, coming
/// back from an absence nobody could explain is not a fresh appearance, the
/// application becoming frontmost in the User Seat is the global focus, and a
/// placement this kit asked for is the kit moving a window.
nonisolated package enum RecencySignal: String, Sendable, Equatable, CaseIterable {

    /// The surface appeared, established visible and interactive.
    case appeared

    /// The surface appeared again after an established hiding or minimising.
    case reappeared

    /// The surface came to the front of the application without having been
    /// hidden first.
    case returnedToFront

    /// The assignment took the surface into membership.
    case attributedToAssignment

    /// Two readings agreed on the surface's frame.
    case geometryVerified

    /// The surface was in a reading again after an uncertain absence.
    case returnedFromUncertainAbsence

    /// The application became frontmost in the User Seat.
    case globalApplicationFocusChanged

    /// The kit asked for the surface to be placed or raised.
    case placementIssuedByKit

    /// True for the three qualified events of ASI-D-020 and no other.
    package var qualifiesRecency: Bool {
        switch self {
            case .appeared, .reappeared, .returnedToFront:        true
            case .attributedToAssignment,
                 .geometryVerified,
                 .returnedFromUncertainAbsence,
                 .globalApplicationFocusChanged,
                 .placementIssuedByKit:                           false
        }
    }
}

/// RecencyClaim is one reported event about one attested surface, with the
/// instant it was observed at, where the report came from, and who brought the
/// surface forward.
///
/// ## Why the instant is carried and the call order is not
///
/// The order of these calls is the order of the consumer's callbacks, and the
/// order of an inventory's members is Window ID order. Neither is a chronology,
/// so the nucleus orders by the observed instant a qualified source hands in,
/// and two events reported at the same instant stay unordered instead of being
/// separated by the order they arrived in.
///
/// ## Why the origin is a separate field
///
/// A return to the front is only the application's when it is not the kit's own
/// raise during containment, staging or preparation. Telling the two apart is a
/// conclusion of its own, with its own provenance, so `origin` carries the
/// evidence for it: an `unattributed` raise is refused exactly like the kit's.
nonisolated package struct RecencyClaim: Sendable, Equatable {

    /// Who brought the surface forward, and on what evidence.
    nonisolated package enum Origin: Sendable, Equatable {

        /// The application, or the person working in it. The provenance has to
        /// carry `SelectionConclusion.raiseProvenance`.
        case application(provenance: SelectionProvenance)

        /// This kit, while containing, staging or preparing. Never recency.
        case kitPlacement

        /// Nobody could say. Not recency either: an unattributed raise is
        /// exactly the case the kit's own raises hide in.
        case unattributed
    }

    package let surface   : WindowIdentity
    package let signal    : RecencySignal
    package let provenance: SelectionProvenance
    package let origin    : Origin

    /// When the event was observed, on the caller's monotonic clock.
    package let observedAtNanoseconds: UInt64

    package init(
        surface              : WindowIdentity,
        signal               : RecencySignal,
        provenance           : SelectionProvenance,
        origin               : Origin,
        observedAtNanoseconds: UInt64
    ) {
        self.surface               = surface
        self.signal                = signal
        self.provenance            = provenance
        self.origin                = origin
        self.observedAtNanoseconds = observedAtNanoseconds
    }

    /// Why this claim cannot move the recency, and nil when it can. The three
    /// checks are separate conclusions and each one is answered on its own
    /// evidence.
    package var unqualifiedReason: SelectionClaimRefusal? {

        guard signal.qualifiesRecency else { return .signalIsNotRecency(signal) }
        guard provenance.attests(.frontOrder) else {
            return .provenanceCannotCarry(conclusion: .frontOrder, provenance: provenance)
        }
        guard case .application(let raiseProvenance) = origin else {
            return .raiseIsNotFromApplication(origin)
        }
        guard raiseProvenance.attests(.raiseProvenance) else {
            return .provenanceCannotCarry(conclusion: .raiseProvenance, provenance: raiseProvenance)
        }
        return nil
    }
}
