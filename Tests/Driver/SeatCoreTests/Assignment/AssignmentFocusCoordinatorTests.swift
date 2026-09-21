//
//  AssignmentFocusCoordinatorTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCore
import Testing

/// The budgets and the verification of the focus protection, with every clock
/// value written down. Nothing here actuates focus, reads the frontmost process
/// or calls a primitive: the durations are handed in exactly as the restorer
/// reports them.
@Suite("Coordinating the focus of an assignment")
struct AssignmentFocusCoordinatorTests {

    typealias Fixture = AssignmentFixtures

    static let destination = Fixture.identity(900, of: Fixture.stranger)

    static func preparation(
        startedAt : UInt64 = 0,
        isAttested: Bool   = true
    ) -> FocusPreparation {
        FocusPreparation(
            destination         : destination,
            isAttested          : isAttested,
            startedAtNanoseconds: startedAt
        )
    }

    static func armed(
        _ preparation: FocusPreparation? = AssignmentFocusCoordinatorTests.preparation()
    ) -> AssignmentFocusCoordinator {
        var coordinator = AssignmentFocusCoordinator()
        coordinator.beginEpisode()
        if let preparation { coordinator.prepare(preparation) }
        return coordinator
    }

    static func decide(
        _ coordinator      : inout AssignmentFocusCoordinator,
        at now             : UInt64 = 1_000_000,
        userIntentPrevails : Bool   = false,
        topologyIsUnchanged: Bool   = true
    ) -> FocusAttemptDecision {

        coordinator.decide(
            at                 : now,
            userIntentPrevails : userIntentPrevails,
            topologyIsUnchanged: topologyIsUnchanged
        )
    }

    // MARK: One attempt per episode

    @Test("A prepared, attested destination may be asked for once")
    func onePreparedAttemptIsAllowed() {
        var coordinator = Self.armed()

        #expect(Self.decide(&coordinator) == .mayRequest(destination: Self.destination))
        #expect(!coordinator.hasAttemptAvailable)
        #expect(Self.decide(&coordinator) == .miss(.attemptAlreadySpent))
    }

    @Test("Outside an episode there is no automatic attempt at all")
    func noEpisodeNoAttempt() {
        var coordinator = AssignmentFocusCoordinator()
        #expect(Self.decide(&coordinator) == .miss(.notArmed))
    }

    @Test("A missing preparation is a miss, and it spends the episode rather than calling blind")
    func missingPreparationIsAMiss() {
        var coordinator = Self.armed(nil)

        #expect(Self.decide(&coordinator) == .miss(.preparationMissing))
        #expect(!coordinator.hasAttemptAvailable)
    }

    @Test("A destination nobody attested is a miss")
    func unattestedDestinationIsAMiss() {
        var coordinator = Self.armed(Self.preparation(isAttested: false))
        #expect(Self.decide(&coordinator) == .miss(.destinationNotAttested))
    }

    @Test("A preparation older than its lifetime from its own start is a miss")
    func expiredPreparationIsAMiss() {
        var coordinator = Self.armed(Self.preparation(startedAt: 0))

        #expect(
            Self.decide(&coordinator, at: AssignmentFocusCoordinator.preparationLifetimeNanoseconds + 1)
                == .miss(.preparationExpired)
        )
    }

    @Test("A preparation exactly at the lifetime is still usable")
    func preparationAtTheLimitIsUsable() {
        var coordinator = Self.armed(Self.preparation(startedAt: 0))

        #expect(
            Self.decide(&coordinator, at: AssignmentFocusCoordinator.preparationLifetimeNanoseconds)
                == .mayRequest(destination: Self.destination)
        )
    }

    @Test("The person's own choice wins over the automatic attempt")
    func userIntentWins() {
        var coordinator = Self.armed()
        #expect(Self.decide(&coordinator, userIntentPrevails: true) == .miss(.userIntentPrevails))
    }

    @Test("A topology that moved under the preparation is a miss")
    func topologyChangeIsAMiss() {
        var coordinator = Self.armed()
        #expect(Self.decide(&coordinator, topologyIsUnchanged: false) == .miss(.topologyChanged))
    }

    // MARK: Rearming is the consumer's explicit act

    @Test("A rearm without fresh evidence or without reconciled effects changes nothing")
    func rearmNeedsBothConditions() {
        var coordinator = Self.armed()
        _ = Self.decide(&coordinator)

        // Each answer is bound first because rearming mutates the coordinator,
        // and the expectation would capture it as an immutable value.
        let withoutEvidence   = coordinator.rearm(hasFreshEvidence: false, previousEffectsReconciled: true)
        let withoutReconciled = coordinator.rearm(hasFreshEvidence: true, previousEffectsReconciled: false)
        let withNeither       = coordinator.rearm(hasFreshEvidence: false, previousEffectsReconciled: false)

        #expect(!withoutEvidence)
        #expect(!withoutReconciled)
        #expect(!withNeither)
        #expect(!coordinator.hasAttemptAvailable)
    }

    @Test("An explicit rearm with fresh evidence opens the next episode")
    func explicitRearmOpensTheNextEpisode() {
        var coordinator = Self.armed()
        _ = Self.decide(&coordinator)
        let episode = coordinator.episode
        let rearmed = coordinator.rearm(hasFreshEvidence: true, previousEffectsReconciled: true)

        #expect(rearmed)
        #expect(coordinator.episode == episode &+ 1)
        #expect(coordinator.hasAttemptAvailable)
        // The preparation belonged to the episode that failed.
        #expect(coordinator.preparation == nil)
        #expect(Self.decide(&coordinator) == .miss(.preparationMissing))
    }

    // MARK: Verification

    @Test("Nothing to verify before a request returned")
    func nothingToVerifyWithoutARequest() {
        var coordinator = Self.armed()
        #expect(coordinator.observe(frontmost: Self.destination, at: 10) == .noRequest)
    }

    @Test("Two agreeing readings of the exact destination verify the focus")
    func twoAgreeingReadingsVerify() {
        var coordinator = Self.armed()
        _ = Self.decide(&coordinator)
        coordinator.noteRequest(
            destination           : Self.destination,
            restoreCallNanoseconds: 3_000_000,
            returnedAt            : 1_000_000
        )

        #expect(coordinator.observe(frontmost: Self.destination, at: 1_010_000) == .pending)
        #expect(coordinator.observe(frontmost: Self.destination, at: 1_020_000) == .verified)
    }

    @Test("A reading of another window breaks the agreement rather than extending it")
    func aDifferentWindowBreaksTheAgreement() {
        var coordinator = Self.armed()
        _ = Self.decide(&coordinator)
        coordinator.noteRequest(
            destination           : Self.destination,
            restoreCallNanoseconds: 3_000_000,
            returnedAt            : 0
        )

        #expect(coordinator.observe(frontmost: Self.destination, at: 1_000) == .pending)
        #expect(coordinator.observe(frontmost: Fixture.identity(11), at: 2_000) == .pending)
        #expect(coordinator.observe(frontmost: Self.destination, at: 3_000) == .pending)
        #expect(coordinator.observe(frontmost: Self.destination, at: 4_000) == .verified)
    }

    @Test("A reading that could not name the frontmost window breaks the agreement")
    func anUnreadableFrontmostBreaksTheAgreement() {
        var coordinator = Self.armed()
        coordinator.noteRequest(
            destination           : Self.destination,
            restoreCallNanoseconds: 1_000_000,
            returnedAt            : 0
        )

        #expect(coordinator.observe(frontmost: Self.destination, at: 1_000) == .pending)
        #expect(coordinator.observe(frontmost: nil, at: 2_000) == .pending)
        #expect(coordinator.observe(frontmost: Self.destination, at: 3_000) == .pending)
    }

    @Test("After 250 ms the verification times out, and a late agreement does not reopen it")
    func lateOutcomeDoesNotVerify() {
        var coordinator = Self.armed()
        coordinator.noteRequest(
            destination           : Self.destination,
            restoreCallNanoseconds: 1_000_000,
            returnedAt            : 0
        )

        #expect(coordinator.observe(frontmost: Self.destination, at: 250_000_001) == .timedOut)
        #expect(coordinator.observe(frontmost: Self.destination, at: 260_000_000) == .lateOutcomeIgnored)
        #expect(coordinator.observe(frontmost: Self.destination, at: 270_000_000) == .lateOutcomeIgnored)
    }

    // MARK: The 8 ms of the whole call

    @Test("The budget keeps the maximum and the overruns, and offers no average")
    func budgetKeepsMaximumAndOverruns() {
        var coordinator = Self.armed()
        for duration in [1_000_000, 9_000_000, 2_000_000] as [UInt64] {
            coordinator.noteRequest(
                destination           : Self.destination,
                restoreCallNanoseconds: duration,
                returnedAt            : 0
            )
        }

        #expect(coordinator.budget.callCount == 3)
        #expect(coordinator.budget.overrunCount == 1)
        #expect(coordinator.budget.maximumNanoseconds == 9_000_000)
        #expect(!coordinator.budget.isWithinLimit)
    }

    @Test("A call exactly at the limit is not an overrun, and an empty budget has proved nothing")
    func budgetBoundary() {
        var budget = FocusCallBudget()
        #expect(budget.isWithinLimit)
        #expect(budget.callCount == 0)

        budget.record(restoreCallNanoseconds: FocusCallBudget.limitNanoseconds)
        #expect(budget.isWithinLimit)

        budget.record(restoreCallNanoseconds: FocusCallBudget.limitNanoseconds &+ 1)
        #expect(!budget.isWithinLimit)
        #expect(budget.overrunCount == 1)
    }

    // MARK: A late activation uses the original budget

    @Test("A correlated late activation with a valid preparation may still be recovered from")
    func lateActivationMayRecover() {
        var coordinator = Self.armed()

        #expect(
            coordinator.noteLateActivation(isCorrelated: true, at: 500_000_000)
                == .mayRecover(destination: Self.destination)
        )
    }

    @Test("An activation nothing ties to the operation is the person's own")
    func uncorrelatedLateActivationIsRefused() {
        var coordinator = Self.armed()

        #expect(
            coordinator.noteLateActivation(isCorrelated: false, at: 1_000)
                == .refused(.correlationNotVerifiable)
        )
    }

    @Test("A late activation never adds an attempt to an episode that spent one")
    func lateActivationDoesNotAddAnAttempt() {
        var coordinator = Self.armed()
        _ = Self.decide(&coordinator)

        #expect(
            coordinator.noteLateActivation(isCorrelated: true, at: 2_000)
                == .refused(.attemptAlreadyConsumed)
        )
    }

    @Test("A late activation after the preparation's lifetime is refused")
    func lateActivationAfterTheLifetimeIsRefused() {
        var coordinator = Self.armed(Self.preparation(startedAt: 0))

        #expect(
            coordinator.noteLateActivation(
                isCorrelated: true,
                at          : AssignmentFocusCoordinator.preparationLifetimeNanoseconds + 1
            ) == .refused(.preparationExpired)
        )
    }

    @Test("Teardown wins over a late activation")
    func teardownWinsOverLateActivation() {
        var coordinator = Self.armed()
        coordinator.endEpisode()

        #expect(
            coordinator.noteLateActivation(isCorrelated: true, at: 1_000)
                == .refused(.notArmed)
        )
    }

    @Test("An invalidated preparation is not recovered from")
    func invalidatedPreparationIsNotRecovered() {
        var coordinator = Self.armed()
        coordinator.invalidate()

        #expect(
            coordinator.noteLateActivation(isCorrelated: true, at: 1_000)
                == .refused(.preparationMissing)
        )
    }
}
