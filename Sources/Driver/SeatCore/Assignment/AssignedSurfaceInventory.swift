//
//  AssignedSurfaceInventory.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// SurfaceOrigin separates the windows the assignment inherited from the ones it
/// produced. The two go home differently, so the distinction is recorded when
/// the surface is first seen and never recomputed later.
nonisolated package enum SurfaceOrigin: String, Sendable, Equatable {

    /// It was already open when the application was handed over. The baseline is
    /// not an exemption from containment: it is only the memory of where the
    /// window has to go back to.
    case preexisting

    /// It was opened while the application was assigned, so it has no place in
    /// the User Seat to return to and needs a destination from the consumer.
    case bornDuringAssignment
}

/// SurfacePresence is where a member surface was last seen. Absence is its own
/// case rather than a missing record, because "I did not see it" and "it is
/// gone" are the two facts this kit must never merge.
nonisolated package enum SurfacePresence: String, Sendable, Equatable {

    case containedInSeat
    case outsideSeat

    /// It was not in the last reading. It may be hidden, minimised, on another
    /// Space or closed, and none of those is established by an absence.
    case absentUncertain
}

/// ClosureEvidence is what is offered as proof that a window is gone.
///
/// It is public because it is also the cause a `windowUnavailable` Issue is
/// published with: the question "why is this window not there" has one set of
/// answers in this kit and this is it.
nonisolated public enum ClosureEvidence: String, Sendable, Equatable {

    /// The window server confirmed the window was destroyed.
    case windowServerConfirmedDestruction

    /// The window server retains this identity but has ordered out its geometry.
    /// The shared hidden-window ledger has accepted its later return, so it no
    /// longer belongs to this assignment's inventory. The window is still alive.
    case windowServerConfirmedOrderingOut

    /// It was missing from a reading, which proves nothing.
    case absentFromReading

    /// The application stopped listing the window among its own, while the
    /// window server still holds a visible surface for it.
    ///
    /// This is the application's own statement and not a reading that missed
    /// something: where the enumeration is positively scoped by the application,
    /// a window it no longer scopes is not one of its windows. It is separate
    /// from `absentFromReading` because that one is the opposite case — nobody
    /// said anything — and separate from a window server destruction because
    /// nothing was destroyed: measured on DaVinci Resolve, the Project Manager
    /// it closes keeps a visible window server surface. Only a repeated
    /// observation, held long enough that a slow or momentarily unavailable
    /// accessibility reading is excluded, may offer it.
    case applicationWithdrewTheWindow

    public var provesClosure: Bool { self != .absentFromReading }
}

/// AssignedSurface is one surface the seat holds membership of, with everything
/// a containment decision and a later return need and nothing else.
nonisolated package struct AssignedSurface: Sendable, Equatable {

    package let identity   : WindowIdentity
    package let attribution: SurfaceAttribution
    package let origin     : SurfaceOrigin

    /// Where the surface was when it was first attributed, which is where a
    /// pre-existing window goes back to if that place is still valid.
    package let originalFrame: CGRect

    /// The physical display that contained the original frame's centre, nil when
    /// none did. Nil is the honest answer for a window that was already on the
    /// Virtual Display or parked off every edge, and it is never replaced by an
    /// arbitrary display later.
    package let originalDisplayID: CGDirectDisplayID?

    /// The desktop (Space) the surface was on when it was first attributed, nil
    /// when it was not read or the surface was already inside the seat. It is
    /// carried to the return so a verification can tell the desktop it is owed.
    package let originalSpaceID: Int?

    /// When the surface was first seen, which is where the containment deadline
    /// for a new window is measured from.
    package let firstDetectedAtNanoseconds: UInt64

    package fileprivate(set) var reference: WindowReference
    package fileprivate(set) var presence : SurfacePresence

    /// True when two consecutive readings carried this identity at the same
    /// frame. A single reading is a sighting: a window publishes itself before
    /// its geometry settles, so acting on one reading acts on a frame that is
    /// about to change.
    package fileprivate(set) var isVerified: Bool

    /// True while the seat owes this surface a return: a transfer into the seat
    /// was requested for it, or a reading put it inside the seat. It is the
    /// claim, and membership is not one: every window of the assigned
    /// application is a member, including the ones the seat never touched.
    ///
    /// It starts on the first sighting inside rather than on the agreeing pair,
    /// because a lost return obligation strands a window on a display the person
    /// cannot see, while a claim that turns out to be wrong costs one no-op
    /// placement. It ends only when two agreeing readings put the surface
    /// outside the seat again: an absence is not a window that went home.
    package fileprivate(set) var isHeldBySeat: Bool

    /// True when this surface is drawn inside another window of the same
    /// application and moves with it: an AppKit sheet is the case that exists.
    ///
    /// Such a surface is never held by the seat. It was not moved in, it has no
    /// place of its own in the User Seat, and the frame a reading finds it at is
    /// its host's minus the host's own inset, so a return computed from it would
    /// send the sheet somewhere nobody put it. It is a member like any other and
    /// its host answers for where it goes.
    package fileprivate(set) var isAttachedToHost = false

    /// True once two readings put this surface inside the seat, until a later
    /// pair puts it outside again. It is what makes "it left" a different fact
    /// from "it is outside": the reading where a window starts moving disagrees
    /// with the one before it, so the escape is only agreed on afterwards, when
    /// the current presence no longer remembers where the window used to be.
    package fileprivate(set) var hadBeenContained = false

    /// True while the last reading found the surface ordered out by its
    /// application: nothing can move it and nobody can reach it, so its
    /// containment waits until it is shown again. It stays a member, with the
    /// place it was found at, so its return is still known then.
    package fileprivate(set) var isOrderedOut = false

    package var windowNumber: Int { identity.windowNumber }

    /// True only for a surface that two agreeing readings put inside the seat.
    /// Membership, visibility and containment are three different facts, and
    /// this property is the third one.
    package var isContained: Bool { isVerified && presence == .containedInSeat }
}

/// SurfaceEvent is what one folded reading changed about membership. It carries
/// no instruction: what to do about a surface that left the seat is the
/// containment coordinator's, and what to do about an uncertain one is the
/// consumer's.
nonisolated package enum SurfaceEvent: Sendable, Equatable {

    /// A surface entered membership. It is not yet verified.
    case attributed(WindowReference)

    /// Two readings agreed on it, so it may be acted on.
    case verified(WindowReference)

    /// A member left the readings. Membership persists and the reference stays
    /// valid: this is the hidden, minimised and unreadable case as much as it is
    /// the closed one.
    case absenceUncertain(windowNumber: Int)

    /// A member came back after an uncertain absence and has to be verified
    /// again before anything is done to it.
    case returnedFromAbsence(WindowReference)

    /// A Window ID that had been confirmed closed carries a surface again. The
    /// old reference was discarded, so this is a new surface with a reused
    /// number and it starts from verification.
    case returnedAfterConfirmedClosure(WindowReference)

    /// A surface that may belong and cannot be attributed. It is reported and
    /// never moved.
    case uncertainAttribution(windowNumber: Int, doubt: AttributionDoubt)

    /// A verified member that was inside the seat is now, on two agreeing
    /// readings, outside it.
    case leftSeat(WindowReference)
}

/// AssignedSurfaceInventory is the membership half of an assignment: which
/// surfaces belong to the assigned application, where each of them was last
/// seen, and which of them may be acted on.
///
/// ## The handover reading is membership, not a baseline exemption
///
/// The first reading records its surfaces as `preexisting` **members**. That is
/// the deliberate difference from the window watch's baseline, which exists to
/// leave the person's windows alone: an explicitly assigned application is
/// entrusted whole, so the windows it already had are contained like the rest
/// and their original frames are kept for the return.
///
/// ## Nothing here reads anything
///
/// Every reading is handed in, every clock value is passed in, and no system
/// call is made, which is why the whole of it is a unit test with no display
/// attached. A failed reading leaves the inventory exactly as it was: an empty
/// list answered for a failed read is how every window of an application reads
/// as closed at once.
nonisolated package struct AssignedSurfaceInventory: Sendable {

    package private(set) var surfaces: [Int: AssignedSurface] = [:]

    /// Surfaces of the last reading that might belong and could not be
    /// attributed, by Window ID. They are not members and are never moved.
    package private(set) var uncertain: [Int: AttributionDoubt] = [:]

    /// The completeness of the last reading that was not a failure.
    package private(set) var completeness: InventoryCompleteness = .incomplete(reason: "No reading yet")

    /// True while a member is waiting for the second reading that agrees with
    /// it, which is what tells the caller another pass soon is worth its cost.
    package private(set) var hasUnverifiedSighting = false

    /// Window IDs whose closure was confirmed. Kept so that the same number
    /// coming back is answered as a new surface needing verification rather than
    /// as the old one returning.
    private var closed: Set<Int> = []

    package init() {}

    /// Every member, in Window ID order.
    package var members: [AssignedSurface] {
        surfaces.keys.sorted().compactMap { surfaces[$0] }
    }

    /// Members that are verified and inside the seat. Membership alone is not
    /// containment, and this is the list that says so.
    package var containedMembers: [AssignedSurface] {
        members.filter(\.isContained)
    }

    /// Members the seat owes a return: the ones it asked to move in, and the
    /// ones a reading found inside it. It is the list a handback has to see
    /// empty and the list an ending assignment turns into return obligations,
    /// because those are one question and membership answers neither.
    ///
    /// It is deliberately not `containedMembers`: that one is "verified **and**
    /// inside", so a window the seat moved whose containment no pair of readings
    /// has agreed on yet would drop out of it, and the return it is owed with it.
    package var heldMembers: [AssignedSurface] {
        members.filter(\.isHeldBySeat)
    }

    /// Records which members are drawn inside another window of the same
    /// application, and drops the claim on the ones that are.
    ///
    /// The set is handed in whole on every fold rather than accumulated, so a
    /// sheet that closed and left a plain window behind the same Window ID stops
    /// being attached at the same moment it stops being a modal. Dropping the
    /// claim here and not only in `heldMembers` is what keeps a later reading
    /// from opening it again.
    package mutating func noteAttachedSurfaces(_ identities: Set<WindowIdentity>) {

        for (number, surface) in surfaces {
            let attached = identities.contains(surface.identity)
            guard surface.isAttachedToHost != attached else { continue }
            surfaces[number]?.isAttachedToHost = attached
            if attached { surfaces[number]?.isHeldBySeat = false }
        }
    }

    /// Folds one reading in and answers what changed.
    ///
    /// `isHandover` marks the reading taken at the moment of the handover, whose
    /// surfaces are recorded as pre-existing. `displays` maps online physical
    /// displays to their bounds and is used once per surface, to remember which
    /// display held it; an empty map means no display is known, never that the
    /// surface belongs to an arbitrary one. `spaceOf` answers the desktop of a
    /// Window ID and is asked only for a surface outside the seat, once, when
    /// it is first recorded.
    @discardableResult
    package mutating func fold(
        _ reading           : SurfaceInventoryReading,
        attributor          : SurfaceAttributor,
        within virtualBounds: CGRect,
        displays            : [CGDirectDisplayID: CGRect] = [:],
        spaceOf             : ((Int) -> Int?)? = nil,
        at now              : UInt64,
        isHandover          : Bool = false
    ) -> [SurfaceEvent] {

        guard !reading.completeness.isReadFailure else { return [] }
        completeness = reading.completeness

        var events: [SurfaceEvent]          = []
        var seen  : Set<Int>                = []
        var doubts: [Int: AttributionDoubt] = [:]
        var pending                         = false

        for row in reading.rows {
            let attribution = attributor.attribution(of: row.surface, provenance: row.provenance)
            let reference   = row.surface.reference
            let number      = reference.windowNumber

            if case .uncertain(let doubt) = attribution {
                doubts[number] = doubt
                if uncertain[number] != doubt {
                    events.append(.uncertainAttribution(windowNumber: number, doubt: doubt))
                }
                continue
            }
            guard attribution.isAttributed, let identity = reference.identity else { continue }
            seen.insert(number)

            if closed.remove(number) != nil {
                events.append(.returnedAfterConfirmedClosure(reference))
                surfaces[number] = record(
                    identity   : identity,
                    attribution: attribution,
                    reference  : reference,
                    origin     : .bornDuringAssignment,
                    displays   : displays,
                    bounds     : virtualBounds,
                    spaceOf    : spaceOf,
                    at         : now
                )
                surfaces[number]?.isOrderedOut = row.isOrderedOut
                pending = true
                continue
            }

            guard var existing = surfaces[number], existing.identity == identity else {
                // Never seen, or a different window behind a Window ID the
                // server handed out again: either way it starts from scratch.
                surfaces[number] = record(
                    identity   : identity,
                    attribution: attribution,
                    reference  : reference,
                    origin     : isHandover ? .preexisting : .bornDuringAssignment,
                    displays   : displays,
                    bounds     : virtualBounds,
                    spaceOf    : spaceOf,
                    at         : now
                )
                events.append(.attributed(reference))
                surfaces[number]?.isOrderedOut = row.isOrderedOut
                pending = true
                continue
            }

            let wasAbsent   = existing.presence == .absentUncertain
            let wasVerified = existing.isVerified
            let agrees      = !wasAbsent && VirtualWindowPlacementCheck.framesMatch(
                existing.reference.frame,
                reference.frame
            )

            existing.reference    = reference
            existing.presence     = Self.presence(of: reference.frame, within: virtualBounds)
            existing.isVerified   = agrees
            existing.isOrderedOut = row.isOrderedOut
            if existing.isContained { existing.hadBeenContained = true }
            // The claim starts at the first sighting inside the seat and ends
            // only on the two agreeing readings that put the surface outside.
            if existing.presence == .containedInSeat {
                existing.isHeldBySeat = !existing.isAttachedToHost
            } else if agrees, existing.presence == .outsideSeat {
                existing.isHeldBySeat = false
            }
            surfaces[number]    = existing

            if wasAbsent {
                events.append(.returnedFromAbsence(reference))
                pending = true
                continue
            }
            guard agrees else {
                pending = true
                continue
            }
            if !wasVerified { events.append(.verified(reference)) }
            if existing.presence == .outsideSeat, existing.hadBeenContained {
                surfaces[number]?.hadBeenContained = false
                events.append(.leftSeat(reference))
            }
        }

        for (number, member) in surfaces where !seen.contains(number) {
            guard member.presence != .absentUncertain else { continue }
            surfaces[number]?.presence   = .absentUncertain
            surfaces[number]?.isVerified = false
            events.append(.absenceUncertain(windowNumber: number))
        }

        uncertain             = doubts
        hasUnverifiedSighting = pending
        return events.sorted { Self.order(of: $0) < Self.order(of: $1) }
    }

    /// Discards a member on confirmed evidence of its closure, and answers
    /// whether it did.
    ///
    /// An absence is refused here: it is the whole point of the distinction. A
    /// confirmed closure invalidates the reference, and the same Window ID seen
    /// later is reported as a new surface that has to be verified again.
    @discardableResult
    package mutating func confirmClosure(
        of windowNumber: Int,
        evidence       : ClosureEvidence
    ) -> Bool {

        guard evidence.provesClosure, surfaces[windowNumber] != nil else { return false }
        surfaces[windowNumber] = nil
        closed.insert(windowNumber)
        return true
    }

    /// Marks a member as no longer verified because a move was just requested
    /// for it, so the next agreement is measured against where the window ends
    /// up rather than against where it used to be.
    ///
    /// The same request is what makes the seat answerable for the return: a
    /// transfer that was asked for happened, whatever the next reading says, so
    /// a window on its way in is already one the seat has to put back.
    package mutating func noteContainmentRequested(of windowNumber: Int) {
        surfaces[windowNumber]?.isVerified   = false
        surfaces[windowNumber]?.isHeldBySeat = true
    }

    private func record(
        identity   : WindowIdentity,
        attribution: SurfaceAttribution,
        reference  : WindowReference,
        origin     : SurfaceOrigin,
        displays   : [CGDirectDisplayID: CGRect],
        bounds     : CGRect,
        spaceOf    : ((Int) -> Int?)?,
        at now     : UInt64
    ) -> AssignedSurface {

        let presence = Self.presence(of: reference.frame, within: bounds)
        return AssignedSurface(
            identity                  : identity,
            attribution               : attribution,
            origin                    : origin,
            originalFrame             : reference.frame,
            originalDisplayID         : Self.display(containing: reference.frame, in: displays),
            originalSpaceID           : presence == .outsideSeat ? spaceOf?(reference.windowNumber) : nil,
            firstDetectedAtNanoseconds: now,
            reference                 : reference,
            presence                  : presence,
            isVerified                : false,
            isHeldBySeat              : presence == .containedInSeat
        )
    }

    private static func presence(of frame: CGRect, within bounds: CGRect) -> SurfacePresence {
        SurfacePlacement.isContained(frame, within: bounds) ? .containedInSeat : .outsideSeat
    }

    /// The display whose bounds contain the frame's centre, or nil. The
    /// identifiers are sorted so two displays overlapping a point answer the
    /// same way on every run.
    package static func display(
        containing frame: CGRect,
        in displays     : [CGDirectDisplayID: CGRect]
    ) -> CGDirectDisplayID? {

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return displays.keys.sorted().first { displays[$0]?.contains(centre) == true }
    }

    /// A stable order for the events of one fold, so a suite can assert on the
    /// whole batch instead of on a set.
    private static func order(of event: SurfaceEvent) -> Int {
        switch event {
            case .attributed:                    0
            case .returnedAfterConfirmedClosure: 1
            case .returnedFromAbsence:           2
            case .verified:                      3
            case .leftSeat:                      4
            case .absenceUncertain:              5
            case .uncertainAttribution:          6
        }
    }
}
