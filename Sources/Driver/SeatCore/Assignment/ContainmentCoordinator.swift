//
//  ContainmentCoordinator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics

/// ContainmentBlock is one reason the assigned application's surfaces are not
/// all verified inside the Agent Seat. Every case names the surface it is about
/// where there is one, so a consumer is told which window to look at instead of
/// being handed "containment incomplete".
///
/// The set separates facts that are tempting to merge: a surface nobody could
/// attribute, a surface whose single sighting has not been confirmed, a surface
/// outside the seat whose one attempt is spent, and a reading that failed. They
/// lead to different consumer actions and none of them is an error.
nonisolated package enum ContainmentBlock: Sendable, Equatable {

    /// No application is assigned, so there is nothing to contain.
    case notAssigned

    /// The reading failed. Nothing was folded in and no earlier fact was
    /// discarded: a failed read is not an application with no windows.
    case readingUnavailable(reason: String)

    /// The last reading cannot be treated as the whole of the application's
    /// surfaces, so a window may exist that nothing here knows about.
    case inventoryNotQualified(reason: String)

    /// A surface that may belong and could not be attributed. It is never moved,
    /// and while it is there the input gate stays closed for every surface: a
    /// doubt about one window is a doubt about the set.
    case attributionUncertain(windowNumber: Int, doubt: AttributionDoubt)

    /// One sighting, not yet confirmed by a second agreeing reading.
    case surfaceUnverified(windowNumber: Int)

    /// A member is not in the seat.
    case surfaceOutsideSeat(windowNumber: Int)

    /// A member was not in the last reading. Membership persists and the absence
    /// proves nothing, so containment cannot be claimed either.
    case surfaceAbsent(windowNumber: Int)

    /// The one automatic transfer attempt for this surface in this episode has
    /// been used. Only an explicit consumer request arms another.
    case attemptSpent(windowNumber: Int)

    /// The effector refused, before any effect, with its reason.
    case effectRefused(windowNumber: Int, refusal: EffectRefusal)

    /// No usable destination could be computed inside the seat for this surface.
    case destinationUnusable(windowNumber: Int)

    /// The 250 ms from this surface's first detection to its verified
    /// containment has passed. It is an explicit timeout with its elapsed time,
    /// not a cancellation: effects already requested stand.
    case surfaceDeadlineExpired(windowNumber: Int, elapsedNanoseconds: UInt64)

    /// The 2 s from the start of the handover to the verified containment of the
    /// initial set has passed.
    case handoverDeadlineExpired(elapsedNanoseconds: UInt64)
}

/// SurfaceMove is one requested placement: an attested window and the frame
/// inside the seat it should occupy. It is a request and never a result.
nonisolated package struct SurfaceMove: Sendable, Equatable {

    package let identity        : WindowIdentity
    package let destinationFrame: CGRect

    package var windowNumber: Int { identity.windowNumber }

    package init(identity: WindowIdentity, destinationFrame: CGRect) {
        self.identity         = identity
        self.destinationFrame = destinationFrame
    }
}

/// ContainmentPlan is what one pass decided: the moves to request now and every
/// reason the set is not yet contained.
nonisolated package struct ContainmentPlan: Sendable, Equatable {

    package let moves : [SurfaceMove]
    package let blocks: [ContainmentBlock]

    /// True only when every member is verified inside the seat, the reading
    /// could carry the whole application, and no surface is in doubt.
    ///
    /// It is a precondition of admitting input and not the permission itself:
    /// identity, observation, the Cursor Fence, the Facility gate and the other
    /// causes of the gate are checked where input is admitted.
    package let isContained: Bool

    package init(moves: [SurfaceMove], blocks: [ContainmentBlock], isContained: Bool) {
        self.moves       = moves
        self.blocks      = blocks
        self.isContained = isContained
    }
}

/// ContainmentCoordinator turns the membership the inventory holds into the
/// transfers the seat may ask for, and into the reasons it may not.
///
/// ## One logical attempt per surface per episode
///
/// An episode is one handover, or one explicit rearm after it. Inside it each
/// surface gets one logical transfer attempt: a refusal and a move that did not
/// land both spend it, and neither is retried automatically. The count is about
/// logical attempts, not about how many native calls one transfer needs, and
/// rearming is the consumer's explicit act with fresh evidence.
///
/// ## A window already in the seat is taken in where it stands
///
/// A member that two readings put inside the virtual bounds produces no move at
/// all. Moving it anyway to prove it is managed would be an artificial
/// displacement of a window that is already exactly where it belongs.
///
/// ## Deadlines are reported, never enforced by giving up
///
/// 250 ms from a surface's first detection to its verified containment, and 2 s
/// from the start of the handover to the verified containment of the initial
/// set. Passing either produces an explicit block carrying the elapsed time. It
/// does not cancel a native call already made, does not end the assignment and
/// does not open the input gate.
///
/// It reads nothing: members, clock and bounds are handed in, and the effects
/// are performed by whoever owns the effector.
nonisolated package struct ContainmentCoordinator: Sendable {

    /// From the first detection of a surface to its verified containment.
    package static let surfaceBudgetNanoseconds: UInt64 = 250_000_000

    /// From the start of the handover to the verified containment of the set
    /// the handover found.
    package static let handoverBudgetNanoseconds: UInt64 = 2_000_000_000

    package let handoverStartedAtNanoseconds: UInt64

    /// Surfaces whose one attempt in this episode is used, whether the request
    /// was issued or refused. Kept as the record of partial effects too: a
    /// transfer that was asked for happened, whatever the reading says next.
    package private(set) var attemptedSurfaces: Set<Int> = []

    package private(set) var refusals: [Int: EffectRefusal] = [:]

    /// Counts episodes, starting at one. An explicit rearm opens the next one.
    package private(set) var episode: UInt64 = 1

    package init(handoverStartedAtNanoseconds: UInt64) {
        self.handoverStartedAtNanoseconds = handoverStartedAtNanoseconds
    }

    /// Window IDs whose transfer was requested in this episode, in order. These
    /// are the partial effects a timeout or a refusal has to be reported with.
    package var issuedMoves: [Int] {
        attemptedSurfaces.subtracting(refusals.keys).sorted()
    }

    /// Decides what to do with the membership as it stands.
    ///
    /// The caller performs the moves through its effector and reports each one
    /// back with `noteMoveIssued` or `noteMoveRefused`; calling `plan` again
    /// afterwards yields the settled picture, with the attempts spent.
    package func plan(
        members      : [AssignedSurface],
        uncertain    : [Int: AttributionDoubt],
        completeness : InventoryCompleteness,
        virtualBounds: CGRect,
        at now       : UInt64
    ) -> ContainmentPlan {

        var moves : [SurfaceMove]      = []
        var blocks: [ContainmentBlock] = []

        if let reason = completeness.unqualifiedReason {
            blocks.append(.inventoryNotQualified(reason: reason))
        }
        for (number, doubt) in uncertain.sorted(by: { $0.key < $1.key }) {
            blocks.append(.attributionUncertain(windowNumber: number, doubt: doubt))
        }

        for member in members {
            let number = member.windowNumber
            switch member.presence {
                case .absentUncertain:
                    blocks.append(.surfaceAbsent(windowNumber: number))

                case .containedInSeat:
                    // Already where it belongs: taken into management as it
                    // stands, with no move to prove anything.
                    if !member.isVerified {
                        blocks.append(.surfaceUnverified(windowNumber: number))
                    }

                case .outsideSeat:
                    blocks.append(.surfaceOutsideSeat(windowNumber: number))
                    if let refusal = refusals[number] {
                        blocks.append(.effectRefused(windowNumber: number, refusal: refusal))
                    } else if attemptedSurfaces.contains(number) {
                        blocks.append(.attemptSpent(windowNumber: number))
                    } else if !member.isVerified {
                        blocks.append(.surfaceUnverified(windowNumber: number))
                    } else if let destination = SurfacePlacement.visibleFrame(
                        forSizeOf: member.reference.frame,
                        on       : virtualBounds
                    ) {
                        moves.append(
                            SurfaceMove(identity: member.identity, destinationFrame: destination)
                        )
                    } else {
                        blocks.append(.destinationUnusable(windowNumber: number))
                    }
            }
        }

        let isContained = blocks.isEmpty && moves.isEmpty
        blocks.append(contentsOf: expiries(members: members, isContained: isContained, at: now))
        return ContainmentPlan(moves: moves, blocks: blocks, isContained: isContained)
    }

    /// Records that a transfer request left for this surface. The attempt is
    /// spent whether or not the window ends up where it was asked to go.
    package mutating func noteMoveIssued(_ windowNumber: Int) {
        attemptedSurfaces.insert(windowNumber)
        refusals[windowNumber] = nil
    }

    /// Records that the effector refused, which spends the attempt too: a
    /// refusal is an answer, and repeating the same request against the same
    /// evidence is the automatic retry this kit does not perform.
    package mutating func noteMoveRefused(_ windowNumber: Int, _ refusal: EffectRefusal) {
        attemptedSurfaces.insert(windowNumber)
        refusals[windowNumber] = refusal
    }

    /// Opens the next episode on the consumer's explicit request, clearing the
    /// spent attempts and the refusals so the surfaces can be tried once more.
    ///
    /// Deadlines are not cleared: the handover started when it started, and a
    /// rearm that reset it would turn a bounded budget into an unbounded one.
    package mutating func rearm() {
        episode          &+= 1
        attemptedSurfaces  = []
        refusals           = [:]
    }

    /// The deadline blocks, appended after the state is decided so that a set
    /// which is contained in time reports nothing at all.
    private func expiries(
        members    : [AssignedSurface],
        isContained: Bool,
        at now     : UInt64
    ) -> [ContainmentBlock] {

        guard !isContained else { return [] }

        var expired: [ContainmentBlock] = []
        for member in members where !member.isContained {
            let elapsed = now &- member.firstDetectedAtNanoseconds
            guard elapsed > Self.surfaceBudgetNanoseconds else { continue }
            expired.append(
                .surfaceDeadlineExpired(windowNumber: member.windowNumber, elapsedNanoseconds: elapsed)
            )
        }

        let handoverElapsed = now &- handoverStartedAtNanoseconds
        if handoverElapsed > Self.handoverBudgetNanoseconds {
            expired.append(.handoverDeadlineExpired(elapsedNanoseconds: handoverElapsed))
        }
        return expired
    }
}
