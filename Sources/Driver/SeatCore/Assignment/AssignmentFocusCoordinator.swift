//
//  AssignmentFocusCoordinator.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// FocusPreparation is the destination a focus restore was armed for, and when
/// the preparation that produced it started.
///
/// The start is the preparation's own, not the moment the notification arrived:
/// a preparation that took long is stale, and measuring its age from the event
/// that used it would make slow preparation renew itself.
nonisolated package struct FocusPreparation: Sendable, Equatable {

    package let destination: WindowIdentity

    /// True only when the destination window and its process were resolved
    /// through the attested chain. A destination named by PID or by title is a
    /// destination nobody verified, and it does not authorize a call.
    package let isAttested: Bool

    package let startedAtNanoseconds: UInt64

    package init(destination: WindowIdentity, isAttested: Bool, startedAtNanoseconds: UInt64) {
        self.destination          = destination
        self.isAttested           = isAttested
        self.startedAtNanoseconds = startedAtNanoseconds
    }
}

/// FocusMiss is why the automatic attempt was not made. Every case ends the
/// episode without a call: a miss is deliberately not a reason to call anyway.
nonisolated package enum FocusMiss: String, Sendable, Equatable {

    /// No episode is open. A Turn or a complete out of Turn operation opens one.
    case notArmed

    /// The single automatic attempt of this episode is used. A second
    /// notification of the same problem does not arm another.
    case attemptAlreadySpent

    /// Nothing was prepared, so there is no destination to ask for.
    case preparationMissing

    /// The preparation is older than its 1.25 s lifetime.
    case preparationExpired

    /// The destination was not attested.
    case destinationNotAttested

    /// The person chose a window themselves. Their choice always wins.
    case userIntentPrevails

    /// The display topology moved under the preparation.
    case topologyChanged
}

/// FocusAttemptDecision is the answer to "may the seat ask for the user's focus
/// back now". It is one of two things and never a maybe.
nonisolated package enum FocusAttemptDecision: Sendable, Equatable {

    case mayRequest(destination: WindowIdentity)

    /// No call is made and the episode is over. The reason is reported so the
    /// consumer can decide whether to rearm explicitly.
    case miss(FocusMiss)
}

/// FocusVerification is what the readings after a request say about the focus.
nonisolated package enum FocusVerification: String, Sendable, Equatable {

    /// No request has returned, so there is nothing to verify.
    case noRequest

    /// Fewer than two agreeing readings so far, inside the deadline.
    case pending

    /// Two consecutive readings named the exact destination inside the deadline.
    case verified

    /// The 250 ms from the request's return passed without two agreeing
    /// readings. The episode is over and the input gate stays closed.
    case timedOut

    /// A reading arrived after the deadline. It can update what is known about
    /// the world; it cannot declare the deadline met or reopen input.
    case lateOutcomeIgnored
}

/// LateActivationRefusal is why a late activation is not recovered from.
nonisolated package enum LateActivationRefusal: String, Sendable, Equatable {

    /// Nothing ties this activation to the agent's operation. An activation the
    /// person caused is not the seat's to undo.
    case correlationNotVerifiable

    case preparationMissing
    case preparationExpired

    /// The episode's attempt was already used. A late activation gets the
    /// original budget, never an extra attempt.
    case attemptAlreadyConsumed

    case notArmed

    /// The seat was torn down, or the episode invalidated. Teardown wins.
    case invalidated
}

/// LateActivationDecision is the answer for an activation that arrives after the
/// operation looked finished.
nonisolated package enum LateActivationDecision: Sendable, Equatable {

    /// The original attempt may still be spent on this destination. It grants no
    /// input authority and extends no Turn.
    case mayRecover(destination: WindowIdentity)

    case refused(LateActivationRefusal)
}

/// AssignmentFocusCoordinator is the budget and verification half of protecting
/// the person's focus while an application is handed over, staged and contained.
///
/// ## One automatic attempt per episode
///
/// An episode is one Turn, or one complete handover or containment operation
/// outside a Turn. It is not one window and not one notification: an application
/// that activates itself ten times during a transfer gets one attempt, and after
/// a miss or a failure only an explicit consumer request with fresh evidence
/// opens the next episode.
///
/// ## The limited exception, and only it
///
/// Containment being incomplete does not block the focus request. That is the
/// explicit exception: during a handover or a transfer the person's focus may be
/// restored while surfaces the seat is sure about are still to be moved. It is
/// limited to this one guard. Input stays closed, the destination still has to
/// be attested and prepared, the person's own choice still wins, and a restored
/// focus proves nothing about containment.
///
/// ## Verification is not the call and not the containment
///
/// Two readings that name the exact destination, within 250 ms of the request
/// returning, verify the focus. That deadline, the 8 ms of the call itself and
/// the 250 ms a surface has to be contained in are three separate budgets. A
/// reading after the deadline updates the facts and never reopens input.
///
/// It performs no call and reads no state: decisions are taken from values the
/// caller hands in, which is why the whole of it is a unit test.
nonisolated package struct AssignmentFocusCoordinator: Sendable {

    /// A preparation is usable for 1.25 s from its own start: the 1 s of the
    /// heartbeat that rebuilds it, plus the 250 ms this repository already
    /// treats as a late reading's slack.
    ///
    /// At 1 s the two numbers were equal, so a preparation stamped on one beat
    /// was exactly at its expiry on the next, and the beat's own lateness plus
    /// the rebuild's duration was a window in which an activation got
    /// `preparationExpired`. It is the single source for the whole package:
    /// `UserFocusRecovery` reads this rather than carrying its own literal.
    package static let preparationLifetimeNanoseconds: UInt64 = 1_250_000_000

    /// From the return of the focus request to two agreeing readings.
    package static let verificationBudgetNanoseconds: UInt64 = 250_000_000

    package private(set) var budget = FocusCallBudget()

    /// Counts episodes, starting at zero for "nothing armed yet".
    package private(set) var episode: UInt64 = 0

    package private(set) var preparation: FocusPreparation?

    private var isArmed  = false
    private var isSpent  = false

    /// The destination of the request that was made, and when it returned.
    private var requestedDestination: WindowIdentity?
    private var requestReturnedAtNanoseconds: UInt64?
    private var agreeingReading: WindowIdentity?

    /// The terminal answer of this request's verification, once there is one.
    /// Kept so a reading that arrives afterwards is told it is late instead of
    /// being folded into a window that is closed.
    private var settledVerification: FocusVerification?

    package init() {}

    /// True while the episode still holds its one automatic attempt.
    package var hasAttemptAvailable: Bool { isArmed && !isSpent }

    /// Opens an episode: one Turn, or one complete operation outside a Turn.
    /// Any preparation and any pending verification of the previous episode are
    /// dropped, because they belong to an operation that is over.
    package mutating func beginEpisode() {
        episode &+= 1
        isArmed  = true
        isSpent  = false
        invalidate()
    }

    /// Arms a destination. Replacing a preparation invalidates the previous one
    /// rather than keeping the older, more favourable age.
    package mutating func prepare(_ preparation: FocusPreparation) {
        self.preparation = preparation
        requestedDestination         = nil
        requestReturnedAtNanoseconds = nil
        agreeingReading              = nil
        settledVerification          = nil
    }

    /// Drops the preparation and any pending verification, leaving the spent
    /// attempt spent. Teardown, an invalidated observation and a destination
    /// that changed all come through here.
    package mutating func invalidate() {
        preparation                  = nil
        requestedDestination         = nil
        requestReturnedAtNanoseconds = nil
        agreeingReading              = nil
        settledVerification          = nil
    }

    /// Ends the episode without opening another. Used at teardown and when the
    /// assignment ends: the next attempt needs an explicit rearm.
    package mutating func endEpisode() {
        isArmed = false
        invalidate()
    }

    /// Decides whether the one automatic attempt may be spent now, and spends it
    /// either way.
    ///
    /// `containmentIsComplete` is deliberately absent from the parameters: it is
    /// the guard the exception waives, and a value nobody reads cannot be read
    /// by accident.
    package mutating func decide(
        at now            : UInt64,
        userIntentPrevails: Bool,
        topologyIsUnchanged: Bool
    ) -> FocusAttemptDecision {

        guard isArmed  else { return .miss(.notArmed) }
        guard !isSpent else { return .miss(.attemptAlreadySpent) }

        isSpent = true

        guard let preparation else { return .miss(.preparationMissing) }
        guard preparation.isAttested else { return .miss(.destinationNotAttested) }
        guard now &- preparation.startedAtNanoseconds <= Self.preparationLifetimeNanoseconds else {
            return .miss(.preparationExpired)
        }
        guard !userIntentPrevails  else { return .miss(.userIntentPrevails) }
        guard topologyIsUnchanged  else { return .miss(.topologyChanged) }

        return .mayRequest(destination: preparation.destination)
    }

    /// Records one complete restore call and opens the verification window.
    ///
    /// `restoreCallNanoseconds` is the whole of `UserFocusRestorer.restore`,
    /// entry to exit, as that type reports it. An overrun is recorded and does
    /// not produce a second call.
    package mutating func noteRequest(
        destination           : WindowIdentity,
        restoreCallNanoseconds: UInt64,
        returnedAt            : UInt64
    ) {
        budget.record(restoreCallNanoseconds: restoreCallNanoseconds)
        requestedDestination         = destination
        requestReturnedAtNanoseconds = returnedAt
        agreeingReading              = nil
        settledVerification          = nil
    }

    /// Folds one reading of the frontmost destination in and answers what it
    /// establishes. `frontmost` is nil when the reading could not name one,
    /// which breaks the agreement rather than extending it.
    package mutating func observe(frontmost: WindowIdentity?, at now: UInt64) -> FocusVerification {

        guard let requested = requestedDestination, let returnedAt = requestReturnedAtNanoseconds else {
            return .noRequest
        }
        if let settledVerification {
            return settledVerification == .verified ? .verified : .lateOutcomeIgnored
        }

        // The deadline is checked before the agreement, so a reading that
        // arrives late cannot verify by being correct.
        guard now &- returnedAt <= Self.verificationBudgetNanoseconds else {
            settledVerification = .timedOut
            return .timedOut
        }
        guard let frontmost, frontmost == requested else {
            agreeingReading = nil
            return .pending
        }
        guard agreeingReading == frontmost else {
            agreeingReading = frontmost
            return .pending
        }
        settledVerification = .verified
        return .verified
    }

    /// Answers whether an activation noticed after the operation may still be
    /// recovered from, on the original budget.
    ///
    /// `isCorrelated` has to come from evidence that ties the activation to the
    /// agent's operation. The policy being approved does not make a local signal
    /// sufficient, and an uncorrelated activation is the person's own.
    package mutating func noteLateActivation(
        isCorrelated: Bool,
        at now      : UInt64
    ) -> LateActivationDecision {

        guard isArmed              else { return .refused(.notArmed) }
        guard isCorrelated         else { return .refused(.correlationNotVerifiable) }
        guard let preparation      else { return .refused(.preparationMissing) }
        guard !isSpent             else { return .refused(.attemptAlreadyConsumed) }
        guard now &- preparation.startedAtNanoseconds <= Self.preparationLifetimeNanoseconds else {
            return .refused(.preparationExpired)
        }
        return .mayRecover(destination: preparation.destination)
    }

    /// Opens the next episode on the consumer's explicit request.
    ///
    /// Both conditions are the consumer's to establish: evidence taken after the
    /// failure, and the previous episode's effects reconciled. A duplicate
    /// notification of the same problem satisfies neither, which is what keeps a
    /// miss from rearming itself.
    @discardableResult
    package mutating func rearm(
        hasFreshEvidence         : Bool,
        previousEffectsReconciled: Bool
    ) -> Bool {

        guard hasFreshEvidence, previousEffectsReconciled else { return false }
        beginEpisode()
        return true
    }
}
