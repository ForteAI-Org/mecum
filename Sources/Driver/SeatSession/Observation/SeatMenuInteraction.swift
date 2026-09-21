//
//  SeatMenuInteraction.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Dispatch
import SeatCapture
import SeatCore

/// SeatMenuInteraction is the scoped access a consumer is given **inside** one
/// menu interaction, and nowhere else.
///
/// ## Scoped on purpose
///
/// The consumer receives it as the parameter of a closure and may keep the
/// object afterwards; keeping it buys nothing, because every entry point
/// re-checks the generation and the deadline and answers `menuContextRevoked`
/// once the interaction is over, cancelled or expired. There is no handle that
/// holds a menu open past the end of the call, and there is no way to be given
/// one: an open contextual menu is a modal tracking loop inside somebody else's
/// process.
///
/// ## What it may do
///
/// Observe the menu's own dedicated surface, and post a Command inside it
/// against an observation of that surface. Ordinary Commands on the parent are
/// refused while this is current, which is the rule of ASI-D-019 expressed where
/// input is admitted rather than in a convention.
///
/// ## What it cannot do here
///
/// Observing the dedicated surface needs a native ability nothing has qualified
/// on this system, so the shipped source refuses `observe` before any effect
/// with `capabilityUnqualified(.menuSurfaceStill)`. The parent's Frame is not
/// offered in its place and the desktop is not a fallback. Choosing an item
/// consequently cannot be reached in a shipped deployment: the refusal is the
/// state of the evidence, not a placeholder.
@MainActor
public final class SeatMenuInteraction {

    /// The window the menu was opened from. It stays the parent for the whole
    /// interaction and the menu never becomes a target of its own.
    public let parent: WindowIdentity

    /// The menu window the window server showed.
    public let menu: ContextMenu

    /// The absolute monotonic instant the 180 s interaction budget ends at.
    public let deadlineNanoseconds: UInt64

    private weak var seat: AgentSeat?
    private let generation: UInt64

    init(
        parent             : WindowIdentity,
        menu               : ContextMenu,
        deadlineNanoseconds: UInt64,
        seat               : AgentSeat,
        generation         : UInt64
    ) {
        self.parent              = parent
        self.menu                = menu
        self.deadlineNanoseconds = deadlineNanoseconds
        self.seat                = seat
        self.generation          = generation
    }

    /// Nanoseconds left of the interaction budget, zero once it has passed.
    /// Reading it is not a renewal and it never grows.
    public var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < deadlineNanoseconds ? deadlineNanoseconds - now : 0
    }

    /// True once the context carries no authority: the interaction ended, was
    /// cancelled, or its budget passed.
    public var isRevoked: Bool {
        guard let seat else { return true }
        return remainingNanoseconds == 0 || !seat.menuContextIsCurrent(generation)
    }

    /// Observes the menu's own dedicated surface.
    ///
    /// The capture shares whatever is left of the interaction budget as well as
    /// its own 5 s and 2 attempts, so the tighter of the two wins and neither is
    /// renewed. A revoked context answers `menuContextRevoked` without touching
    /// the capture path.
    public func observe() async -> Result<SeatObservationDelivery, ObservationUnavailable> {
        guard let seat else { return .failure(.menuContextRevoked) }
        return await seat.observeMenuSurface(generation: generation)
    }

    /// Posts one Command inside the menu, against an observation of the menu's
    /// own surface.
    ///
    /// The reference is verified at admission and again immediately before the
    /// first event, like every other Command. A reference of the parent, of an
    /// earlier interaction or of an expired context is refused before any
    /// effect, and the recipient is never recomputed from the current target.
    @discardableResult
    public func send(
        _ command  : InputCommand,
        observation: SeatObservationReference
    ) async throws -> InputReceipt {
        guard let seat else { throw ObservationAdmissionRefusal.menuContextRevoked }
        return try await seat.sendInsideMenu(
            command,
            observation: observation,
            generation : generation
        )
    }

    /// The screen point a pixel of the menu's Frame maps to, through the
    /// geometry that exact sample carried. It is a pure conversion and posts
    /// nothing; a point the geometry cannot map answers nil rather than a
    /// guessed coordinate.
    public func screenPoint(
        ofPixel pixelPoint: CGPoint,
        in delivery       : SeatObservationDelivery
    ) -> CGPoint? {
        delivery.frame.geometry.screenPoint(fromPixelPoint: pixelPoint)
    }
}
