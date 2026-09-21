//
//  ObservationAdmissionRefusal.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ObservationAdmissionRefusal is why a Command carrying an Observation
/// Reference was refused.
///
/// Every case is a rejection **before any effect**: it is answered at admission
/// and again after each await, up to the boundary immediately before the first
/// event. A Command whose first event has gone out is never described by this
/// type, because an event that went out is not cancelled retroactively, not
/// redirected to another window and never replayed.
nonisolated public enum ObservationAdmissionRefusal: Sendable, Equatable, Error {

    /// The value was not issued by this seat under this lifecycle. A reference
    /// the consumer assembled, or one kept from another seat, lands here.
    case foreignReference

    /// The reference is well formed and is not the outstanding one, so a newer
    /// observation replaced it.
    case referenceSuperseded

    /// There is no current observation at all, with why there is not.
    case noCurrentObservation(ObservationInvalidation)

    /// A Command completed, or something was invalidated, after this reference
    /// was issued. A new observation is required and the old plan is not
    /// resumed with a new token pasted onto it.
    case barrierAdvanced

    /// Another application instance is assigned now.
    case instanceChanged

    /// The reference's recipient is not the surface the seat holds as current.
    /// The Command is refused and is never redirected to the current target.
    case recipientNotCurrent(WindowIdentity)

    /// The selection moved, including a return to the same window under a new
    /// generation, which is the A to B to A case.
    case selectionSuperseded(observed: UInt64, current: UInt64)

    /// The observed surface's role changed, such as a menu that opened or closed
    /// under the reference.
    case roleChanged

    /// The window's geometry observation is not the one the Frame carried.
    case geometryChanged

    /// The age of the content is not known, with the reason it is not. An
    /// unknown age refuses input exactly as an expired one does.
    case frameAgeUnknown(ContentAgeDoubt)

    /// The content is older than the configured finite limit.
    case frameTooOld(ageNanoseconds: UInt64, limitNanoseconds: UInt64)

    /// An ordinary Command was addressed to the parent while a menu observation
    /// is the current one. Only the menu and its closing may be acted on.
    case ordinaryCommandDuringMenu(parent: WindowIdentity)

    /// The menu interaction this Command belongs to is over, cancelled or
    /// expired, so its context carries no authority any more.
    case menuContextRevoked
}
