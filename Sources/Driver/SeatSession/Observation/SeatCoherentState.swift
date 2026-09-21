//
//  SeatCoherentState.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// SeatMonitorHealth separates a Monitor that stopped from a capture the agent's
/// own observation depends on.
///
/// The distinction is the whole contract of ADR 0024 and 0030 in one value: a
/// Monitor is the live view of the Virtual Display shown to a person, and losing
/// it costs the person the preview and costs the agent nothing. Losing the
/// display, or the capture the observation needs, is a shared fault and blocks
/// input. A stale last image may remain presented only while it is marked stale,
/// and the age of what is on screen and the instant it was visible are two
/// different questions, one of which is often unanswerable.
nonisolated public enum SeatMonitorHealth: Sendable, Equatable {

    /// No Monitor was asked for. It is not an error and implies no obligation to
    /// run one.
    case notRequested

    /// Running and presenting live frames of the Virtual Display.
    case live

    /// The Monitor alone failed. Input that is otherwise valid keeps working and
    /// the consumer is told. The last image may still be on screen and is stale.
    case isolatedFault(lastImageIsStale: Bool)

    /// The fault also reaches the display or the capture the observation needs,
    /// so it blocks input as well as the preview.
    case sharedFault

    /// True when this health alone must close the input gate.
    public var blocksInput: Bool { self == .sharedFault }
}

/// SeatCoherentState is one revisioned reading of everything a consumer needs to
/// show and to decide with: the assignment, the Selected and Operational Target,
/// every active cause of suspension, whether an observation is current, the
/// Monitor's own health and any restitution still owed.
///
/// ## What the revision is for
///
/// It lets a consumer tell an update it has already seen from a newer one, and
/// it is scoped to `lifecycle` so that a revision of a previous assignment can
/// never look current. Updates may be coalesced to bound memory; each one is a
/// complete snapshot, so the current state is always reconstructible from the
/// latest value. It is not a journal and nothing here promises every
/// intermediate state was published.
///
/// ## What it is not
///
/// It is not authority. A reading that says `operational` does not admit a
/// Command: the Observation Reference and the gate are checked where input is
/// admitted, however recently this value said the target was ready. It also does
/// not promise that the Monitor's pixels and the observation's pixels describe
/// one instant: they are two captures of two sources.
nonisolated public struct SeatCoherentState: Sendable, Equatable {

    /// Advances on every change. Meaningful only inside one `lifecycle`.
    public let revision: UInt64

    /// The observation lifecycle these facts belong to. A handover of another
    /// instance opens the next one.
    public let lifecycle: UInt64

    /// The assigned instance, nil when nothing is assigned.
    public let instance: ProcessIdentity?

    /// The chosen surface, which is not the same as one that may be acted on.
    public let selectedTarget: WindowIdentity?

    /// The surface the agent may act on right now, nil whenever any cause of
    /// suspension stands.
    public let operationalTarget: WindowIdentity?

    /// Every active cause, reported together and independent of one another.
    public let suspensions: [SeatSuspensionCause]

    /// True while an Observation Reference issued by this seat is outstanding.
    public let hasCurrentObservation: Bool

    /// Why the last observation stopped being current, nil while one is.
    public let lastInvalidation: ObservationInvalidation?

    /// The role of the current observation, which is how a consumer knows a menu
    /// interaction is scoping what may be sent.
    public let observedRole: ObservedSurfaceRole?

    public let monitor: SeatMonitorHealth

    /// Window IDs whose return is owed and not verified. A non empty list means
    /// the stop is incomplete: input authority is revoked and the resources the
    /// remaining windows need are still held.
    public let outstandingReturns: [Int]

    package init(
        revision            : UInt64,
        lifecycle           : UInt64,
        instance            : ProcessIdentity?,
        selectedTarget      : WindowIdentity?,
        operationalTarget   : WindowIdentity?,
        suspensions         : [SeatSuspensionCause],
        hasCurrentObservation: Bool,
        lastInvalidation    : ObservationInvalidation?,
        observedRole        : ObservedSurfaceRole?,
        monitor             : SeatMonitorHealth,
        outstandingReturns  : [Int]
    ) {
        self.revision              = revision
        self.lifecycle             = lifecycle
        self.instance              = instance
        self.selectedTarget        = selectedTarget
        self.operationalTarget     = operationalTarget
        self.suspensions           = suspensions
        self.hasCurrentObservation = hasCurrentObservation
        self.lastInvalidation      = lastInvalidation
        self.observedRole          = observedRole
        self.monitor               = monitor
        self.outstandingReturns    = outstandingReturns
    }
}
