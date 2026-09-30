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
    ///
    /// The elapsed time is the time the kit had a reading it could trust, which
    /// is what the budget is measured on. It is smaller than the wall clock
    /// whenever a pass could not carry the whole application.
    case surfaceDeadlineExpired(windowNumber: Int, elapsedNanoseconds: UInt64)

    /// The 2 s from the start of the handover to the verified containment of the
    /// initial set has passed, counted in trustworthy time like the surface one.
    case handoverDeadlineExpired(elapsedNanoseconds: UInt64)

    /// This surface's wall clock ceiling has passed although its qualified time
    /// has not: the world has been unreadable around it for so long that
    /// waiting for evidence has become waiting for ever.
    ///
    /// It carries both figures because they answer different questions. The
    /// qualified time is what the 250 ms budget is judged on; the total is what
    /// the person has actually waited, and only the total can say that the
    /// outage, and not the application, is what the seat is stuck behind.
    case surfaceStalled(windowNumber: Int, totalNanoseconds: UInt64, qualifiedNanoseconds: UInt64)

    /// The same ceiling for the handover: its qualified time is still inside
    /// the 2 s budget only because almost none of the wall clock counted.
    case handoverStalled(totalNanoseconds: UInt64, qualifiedNanoseconds: UInt64)
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
/// ## Both budgets count trustworthy time only
///
/// `InventoryCompleteness.isQualified` is already this kit's answer to whether a
/// reading may be treated as the whole of the application's surfaces, and
/// `surfaceAbsent` already says that an absence from a reading proves nothing.
/// Put together they decide the clock: while the last pass could not carry the
/// whole application, nothing that pass says about a surface is evidence, so a
/// budget whose job is to bound how long a surface may stay uncontained **on
/// evidence** has nothing to count. `notePass` adds every such interval to
/// `unreadableNanoseconds`, and both deadlines are measured on the remainder.
/// The seat therefore waits while the world is unreadable and gives up promptly
/// once it has a reading it can trust.
///
/// ## The account is cumulative, and every surface enters it where it stands
///
/// `unreadableNanoseconds` is one growing number for the whole assignment, so
/// on its own it would be subtracted whole from a surface that did not exist
/// for most of it. A dialog born after a ten second outage would start its life
/// with ten seconds of credit and could sit outside the seat for all of it
/// without a single block: the budget that is supposed to bound its wait would
/// have been spent by windows it never shared the screen with.
///
/// So the account is snapshotted per surface. `noteSurfaces` writes down what
/// the account read when a surface was first folded in, and the pause charged
/// to that surface is only what the account has grown by since. The handover
/// budget keeps the whole account, which is right: the handover is the thing
/// that started at zero.
///
/// ## Total time and qualified time are different answers
///
/// Subtracting the outages is what makes the 250 ms and the 2 s fair, but an
/// outage that never ends would suspend them for ever, and a seat that waits
/// for ever is the failure the budgets exist to prevent. Past the qualified
/// budget plus `unreadableAllowanceNanoseconds` of wall clock a surface is
/// reported `surfaceStalled` with both figures, which says the wait is about
/// the reading and not about the application without pretending the qualified
/// budget expired.
///
/// It reads nothing: members, clock and bounds are handed in, and the effects
/// are performed by whoever owns the effector.
nonisolated package struct ContainmentCoordinator: Sendable {

    /// From the first detection of a surface to its verified containment.
    package static let surfaceBudgetNanoseconds: UInt64 = 250_000_000

    /// From the start of the handover to the verified containment of the set
    /// the handover found.
    package static let handoverBudgetNanoseconds: UInt64 = 2_000_000_000

    /// How much unreadable wall clock a budget may absorb before the wait is
    /// reported as stalled. It is the five seconds this kit already allows a
    /// window to stay unreadable in a recovery, written here because the number
    /// is the same question and SeatCore is below the recovery that owns it.
    package static let unreadableAllowanceNanoseconds: UInt64 = 5_000_000_000

    /// The wall clock ceilings the two qualified budgets are reported against.
    package static let surfaceStallNanoseconds
        = surfaceBudgetNanoseconds + unreadableAllowanceNanoseconds
    package static let handoverStallNanoseconds
        = handoverBudgetNanoseconds + unreadableAllowanceNanoseconds

    package let handoverStartedAtNanoseconds: UInt64

    /// Surfaces whose one attempt in this episode is used, whether the request
    /// was issued or refused. Kept as the record of partial effects too: a
    /// transfer that was asked for happened, whatever the reading says next.
    package private(set) var attemptedSurfaces: Set<Int> = []

    package private(set) var refusals: [Int: EffectRefusal] = [:]

    /// Counts episodes, starting at one. An explicit rearm opens the next one.
    package private(set) var episode: UInt64 = 1

    /// How much of the wall clock since the handover the kit spent without a
    /// reading it could treat as the whole of the application. Both budgets are
    /// measured on the wall clock minus this, and it only ever grows.
    package private(set) var unreadableNanoseconds: UInt64 = 0

    /// What the account read when each current member was first folded in. A
    /// surface is charged the difference and never the whole, which is what
    /// keeps an outage that happened before it existed out of its budget.
    package private(set) var entryPauseNanoseconds: [Int: UInt64] = [:]

    /// When the last pass was noted and whether its reading qualified. The
    /// handover instant seeds it as unqualified, because a seat that has not
    /// read anything yet has no evidence about any surface.
    private var lastPassAtNanoseconds: UInt64
    private var lastPassIsQualified  = false

    package init(handoverStartedAtNanoseconds: UInt64) {
        self.handoverStartedAtNanoseconds = handoverStartedAtNanoseconds
        self.lastPassAtNanoseconds        = handoverStartedAtNanoseconds
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

                case .outsideSeat where member.isOrderedOut:
                    // Hidden by its application where the person had it: no
                    // element to move and no one to reach it, until it is shown.
                    continue

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

    /// Notes one pass over the assigned application's surfaces, so the budgets
    /// can be charged for the time the kit had evidence and for no other time.
    ///
    /// It is called once per reading, including for a reading that failed
    /// outright, which is the purest case of the world being unreadable. The
    /// interval charged is the one **ending** here: it is the stretch during
    /// which the kit's most recent reading was the unqualified one, and that is
    /// the stretch in which it could judge no surface.
    ///
    /// Separate from `plan` on purpose. `plan` is pure and one ingest calls it
    /// twice, before and after the moves it issues, so accumulating inside it
    /// would charge the same interval twice.
    package mutating func notePass(completeness: InventoryCompleteness, at now: UInt64) {

        if !lastPassIsQualified, now > lastPassAtNanoseconds {
            unreadableNanoseconds &+= now &- lastPassAtNanoseconds
        }
        lastPassAtNanoseconds = now
        lastPassIsQualified   = completeness.isQualified
    }

    /// Opens a pause account for every surface the fold has just produced and
    /// closes the accounts of the ones that are gone.
    ///
    /// Called after the fold and before the plan, which is the one moment at
    /// which a new surface exists and the pass that carried it has already been
    /// charged: the account it reads is therefore everything the assignment
    /// waited through before this surface was born, and none of it is its own.
    ///
    /// A surface that comes back under the same Window ID after being dropped
    /// enters again at the account as it stands now, which is the same rule and
    /// not a special case: what it is owed is a budget for the wait it is
    /// starting, not for the one it left.
    package mutating func noteSurfaces(_ members: [AssignedSurface]) {

        var entries: [Int: UInt64] = [:]
        for member in members {
            let number = member.windowNumber
            entries[number] = entryPauseNanoseconds[number] ?? unreadableNanoseconds
        }
        entryPauseNanoseconds = entries
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
    /// The unreadable account is kept for the same reason, from the other side:
    /// it is what the budgets are already measured net of, and the per surface
    /// entries into it are the halves of that same account.
    package mutating func rearm() {
        episode          &+= 1
        attemptedSurfaces  = []
        refusals           = [:]
    }

    /// The deadline blocks, appended after the state is decided so that a set
    /// which is contained in time reports nothing at all.
    ///
    /// The elapsed time an expiry carries is the qualified time, not the wall
    /// clock, so the figure a consumer reads is the one the budget was judged
    /// against rather than a number that looks like a hang. A stall carries
    /// both, because the wall clock is the whole of what it is reporting.
    private func expiries(
        members    : [AssignedSurface],
        isContained: Bool,
        at now     : UInt64
    ) -> [ContainmentBlock] {

        guard !isContained else { return [] }

        var expired: [ContainmentBlock] = []
        for member in members where !member.isContained && !(member.isOrderedOut && member.presence == .outsideSeat) {

            let number    = member.windowNumber
            let total     = now &- member.firstDetectedAtNanoseconds
            let qualified = subtracting(pauseCharged(to: number), from: total)

            if qualified > Self.surfaceBudgetNanoseconds {
                expired.append(
                    .surfaceDeadlineExpired(windowNumber: number, elapsedNanoseconds: qualified)
                )
            } else if total > Self.surfaceStallNanoseconds {
                expired.append(.surfaceStalled(
                    windowNumber        : number,
                    totalNanoseconds    : total,
                    qualifiedNanoseconds: qualified
                ))
            }
        }

        let handoverTotal     = now &- handoverStartedAtNanoseconds
        let handoverQualified = subtracting(unreadableNanoseconds, from: handoverTotal)
        if handoverQualified > Self.handoverBudgetNanoseconds {
            expired.append(.handoverDeadlineExpired(elapsedNanoseconds: handoverQualified))
        } else if handoverTotal > Self.handoverStallNanoseconds {
            expired.append(.handoverStalled(
                totalNanoseconds    : handoverTotal,
                qualifiedNanoseconds: handoverQualified
            ))
        }
        return expired
    }

    /// The part of the account this surface lived through, which is everything
    /// it has grown by since the surface entered.
    ///
    /// A surface nothing announced falls back to the whole account. It cannot
    /// happen through an ingest, where the fold and `noteSurfaces` are one
    /// step, and the fallback errs towards waiting rather than towards a block
    /// nobody can explain.
    private func pauseCharged(to windowNumber: Int) -> UInt64 {
        subtracting(entryPauseNanoseconds[windowNumber] ?? 0, from: unreadableNanoseconds)
    }

    /// A difference that floors at zero rather than wrapping.
    private func subtracting(_ pause: UInt64, from total: UInt64) -> UInt64 {
        total > pause ? total &- pause : 0
    }
}
