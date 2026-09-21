//
//  SeatObservationReference.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// ObservedSurfaceRole says which surface an observation is of, and what may be
/// done while it is the current one.
///
/// A transient menu is not a target: it belongs to the parent it was opened
/// from, it does not enter the history of targets, and while it is the observed
/// surface an ordinary Command on the parent is refused. That refusal is the
/// reason the role travels on the reference instead of being remembered
/// somewhere else.
nonisolated public enum ObservedSurfaceRole: Sendable, Equatable {

    /// The Selected Target itself.
    case ordinaryTarget

    /// A contextual menu attributed to the parent it was opened from.
    case transientMenu(parent: WindowIdentity)

    public var isTransientMenu: Bool {
        if case .transientMenu = self { return true }
        return false
    }

    public var parent: WindowIdentity? {
        guard case .transientMenu(let parent) = self else { return nil }
        return parent
    }
}

/// SeatObservationReference binds one Frame to the exact situation it was taken
/// in, so that a Command decided on that Frame can be checked against the world
/// as it is when the Command is admitted.
///
/// ## What it binds, and why each part is there
///
/// The issuing seat and its lifecycle, so a value from another seat or from a
/// previous assignment is not authority here. The assigned instance, so a reused
/// PID inherits nothing. The observed surface and the selection generation it
/// was chosen under, which is what stops a return from A to B to A from reviving
/// the observation of the first A. The geometry version and the frame the window
/// had, so an image of where the window used to be is not accepted for where it
/// is. The role and the parent, so a menu observation cannot drive the window
/// underneath it. And the barrier, which advances after every complete Command
/// and on every invalidation, so a second Command needs a second observation.
///
/// ## The consumer cannot build one
///
/// There is no public initializer, and there is deliberately no way to assemble
/// one from identifiers the consumer already holds. A pair of numbers is not an
/// observation, and a value that could be typed out by the caller would be a
/// permission the caller granted itself. The consumer keeps the value it was
/// handed across its own awaits and hands the same value back; the kit verifies
/// it against live facts at admission, not at delivery.
///
/// It is not `SeatObservation`, which is the User Seat diagnostic taken around
/// an action, and it is not a Receipt, which is proof of delivery.
nonisolated public struct SeatObservationReference: Sendable, Equatable {

    /// Which seat issued it, and under which lifecycle of that seat.
    public let issuer: ObservationIssuerToken

    /// The application instance that was assigned when it was issued.
    public let instance: ProcessIdentity

    /// The surface the pixels are of.
    public let surface: WindowIdentity

    /// The generation of the selection the observation was taken under.
    public let selectionGeneration: UInt64

    /// The observer generation and sequence of the geometry carried by the
    /// sample, so a Frame of an older geometry observation is not reused.
    public let geometryVersion: GeometryObservationVersion

    /// The surface's screen rectangle at the moment of the observation.
    public let observedFrame: CGRect

    public let role: ObservedSurfaceRole

    /// The value of the seat's observation barrier when it was issued. The
    /// barrier advances after a complete Command and on every invalidation, so
    /// a reference issued before one of those is no longer the current one.
    public let barrier: UInt64

    /// How old the content was when the observation was delivered, measured or
    /// explicitly unknown. Admission ages it forward and compares it with the
    /// configured finite limit.
    public let contentAge: FrameContentAge

    /// The caller's monotonic clock reading when the observation was delivered,
    /// which is what the forward ageing is measured from.
    public let deliveredAtNanoseconds: UInt64

    package init(
        issuer                : ObservationIssuerToken,
        instance              : ProcessIdentity,
        surface               : WindowIdentity,
        selectionGeneration   : UInt64,
        geometryVersion       : GeometryObservationVersion,
        observedFrame         : CGRect,
        role                  : ObservedSurfaceRole,
        barrier               : UInt64,
        contentAge            : FrameContentAge,
        deliveredAtNanoseconds: UInt64
    ) {
        self.issuer                 = issuer
        self.instance               = instance
        self.surface                = surface
        self.selectionGeneration    = selectionGeneration
        self.geometryVersion        = geometryVersion
        self.observedFrame          = observedFrame
        self.role                   = role
        self.barrier                = barrier
        self.contentAge             = contentAge
        self.deliveredAtNanoseconds = deliveredAtNanoseconds
    }

    /// Which window a Command carried by this reference is addressed to. For a
    /// menu observation it is the menu's own surface, because that is where the
    /// item click has to land.
    public var recipient: WindowIdentity { surface }
}
