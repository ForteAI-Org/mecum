//
//  ClosureTransitionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The episode of one dialog closure: what is taken before the Command, what
/// the steal may and may not change, how many times it may ask, and when it
/// stops asking.
///
/// Every oracle here is independent of the code under test: the windows the
/// restorer was asked for, the causes the gate holds, the counters the recovery
/// publishes, and the sentences the reports carry. Nothing asserts that a
/// method was called by asking the method.
@Suite("Closure transition")
@MainActor
struct ClosureTransitionTests {

    private static func reference(
        processID   : Int32,
        windowNumber: Int,
        frame       : CGRect
    ) -> WindowReference {
        WindowReference(
            identity: WindowIdentity(
                process: ProcessIdentity(
                    processID       : processID,
                    serialNumberHigh: 1,
                    serialNumberLow : UInt32(bitPattern: processID)
                ),
                windowNumber     : windowNumber,
                ownerConnectionID: processID &+ 1_000
            ),
            frame: frame
        )
    }

    /// The person's window, on the physical display.
    private static let user = reference(
        processID   : 99,
        windowNumber: 801,
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500)
    )

    /// A second window of the person's, on the physical display: the one a
    /// genuine choice of another application goes to.
    private static let other = reference(
        processID   : 100,
        windowNumber: 802,
        frame       : CGRect(x: 110, y: 110, width: 600, height: 500)
    )

    /// The modal the Command is expected to close, drawn inside the host's
    /// rectangle on the virtual display.
    private static let sheet = reference(
        processID   : FakeGeometry.targetPID,
        windowNumber: 47_781,
        frame       : FakeGeometry.adoptedWindow.frame
    )

    /// The nested dialog above it, which the same closure takes with it.
    private static let nested = reference(
        processID   : FakeGeometry.targetPID,
        windowNumber: 47_790,
        frame       : FakeGeometry.adoptedWindow.frame
    )

    /// The remote service that draws the panel's content. A different process
    /// with a different connection, reached only through the relation the seat
    /// attested: it is never adopted here and never becomes a destination.
    private static let helper = reference(
        processID   : 39_218,
        windowNumber: 47_782,
        frame       : FakeGeometry.adoptedWindow.frame
    )

    // MARK: What is taken before the Command

    @Test("the transition opens on the preparation of its own Command, and only on one")
    func opensOnTheCommandsOwnPreparation() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.recovery.beginHold()

        // Declared before the post, opened by the preparation the driver
        // awaits immediately before it. The declaration alone opens nothing.
        fixture.expectClosure()
        #expect(!fixture.recovery.isInClosureTransition)

        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.recovery.isInClosureTransition)
        #expect(fixture.preparedDestinations.last == Self.user,
                "the destination retained for the transition is the person's own window")
        #expect(fixture.preparedSurfaces.last?.contains(Self.helper) == true,
                "the helper's serial number is retained beside the targets'")
    }

    @Test("an expectation whose Command never prepared does not open a later one's transition")
    func expectationIsDropped() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.recovery.beginHold()
        fixture.expectClosure()
        fixture.recovery.dropClosureExpectation()
        try await fixture.recovery.prepareBeforeAction()
        #expect(!fixture.recovery.isInClosureTransition)
    }

    @Test("the steal never teaches the transition a new destination")
    func theStealTeachesNothing() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()

        // After the steal the only readable window is the application's own,
        // which is neither a destination nor the person.
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])
        #expect(fixture.reports.last?.destination == Self.user)
    }

    // MARK: The post, the effect and the recovery are three facts

    @Test("a posted closure stays posted while the recovery runs, and is never posted again")
    func postedIsKeptApartFromTheRecovery() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.recovery.noteClosureCommandPosted()

        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.recovery.closureCommandWasPosted, "the post survives the steal")
        #expect(fixture.reports.first?.outcome == .restoring)

        // The verification does not agree at once, the state the Lab read as
        // a failed Cancel. The post is still a post.
        fixture.time += UserFocusRecovery.verificationWindowNanoseconds
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.recovery.closureCommandWasPosted)

        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(fixture.recovery.closureCommandWasPosted)
        #expect(fixture.requested == [Self.user],
                "the recovery asked once and posted no Command of its own")
    }

    // MARK: Preparations and requests are counted apart

    @Test("a refusal costs a preparation attempt and no request, and the next activation may ask")
    func arefusalSpendsNoRequest() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.recovery.preparationAttempts == 1)

        // A valid preparation the front-process witness refuses: the request
        // path is reached and no request is made.
        fixture.frontOverride = false
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.recovery.restoreRequests == 0,
                "the flag this replaced was raised before any of that was known")
        #expect(fixture.reports.last?.detail
            == "The front process no longer matches the activating target")

        // The person comes back and the budget of this episode is still there.
        fixture.frontOverride = nil
        fixture.returnUser()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])
        #expect(fixture.recovery.restoreRequests == 1)
    }

    @Test("a request that throws or is refused still counts: its effect is not knowable",
          arguments: 0..<2)
    func anUncertainRequestIsSpent(_ variant: Int) async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        if variant == 0 { fixture.restoreFailure = .inputPaused([.destinationNotPrepared]) }
        else { fixture.restoreCode = 1 }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])
        #expect(fixture.recovery.restoreRequests == 1)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
    }

    // MARK: The bounded renewal with the gate closed

    @Test("a refused preparation is renewed with the gate closed, keeping the same person")
    func renewalKeepsTheSamePerson() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()

        // The ordinary build cannot replace this evidence: it needs the
        // person's application in front, and the driven one is.
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused, "the renewal runs with the gate closed")

        await fixture.settle()
        #expect(fixture.preparedDestinations.last == Self.user)
        #expect(fixture.requested == [Self.user],
                "the renewed evidence armed the request the steal had refused")
    }

    @Test("the renewal asks accessibility nothing about the person")
    func renewalReadsNothingAboutThePerson() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)

        let reads = fixture.sensing.userWindowReadCount
        #expect(await fixture.recovery.reconcileClosureEvidence())
        #expect(fixture.sensing.userWindowReadCount == reads,
                "the person's focused window is not derived again after the steal")
        #expect(fixture.preparedDestinations.last == Self.user)
    }

    @Test("a destroyed remote helper keeps its pre-close PSN while the user destination renews")
    func renewalDoesNotResolveDestroyedRemoteHelper() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.remoteHelperDestroyed = true
        let preparationsBeforeRenewal = fixture.preparedSurfaces.count

        #expect(await fixture.recovery.reconcileClosureEvidence())
        #expect(fixture.renewedDestinations == [Self.user])
        #expect(fixture.preparedSurfaces.count == preparationsBeforeRenewal,
                "the helper was retained before the Command and never resolved after it closed")
    }

    @Test("the renewal never learns a destination from whatever is active now")
    func renewalLearnsNothingFromTheTarget() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)

        // A second window of the person's is here to be mistaken for a choice
        // they never made.
        fixture.sensing.focusedUserWindow = Self.other
        await fixture.settle()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.reports.last?.destination == Self.user)
    }

    @Test("a destination that is no longer the window it was ends the renewal, not in another window")
    func renewalRefusesAnExpiredOwner() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)

        fixture.sensing.additionalWindows[Self.user.windowNumber] = nil
        await fixture.settle()
        #expect(fixture.requested.isEmpty, "the seat waits for a real choice by the person")
        #expect(fixture.gate.isPaused)
    }

    @Test("the renewal is bounded: a destination that stays unreadable costs a fixed number of reads")
    func renewalIsBounded() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)
        fixture.sensing.additionalWindows[Self.user.windowNumber] = nil

        for _ in 0..<5 { await fixture.settle() }
        #expect(fixture.requested.isEmpty)
        #expect(fixture.recovery.preparationAttempts <= 1 + UserFocusRecovery.closureRequestBudget,
                "the count stops it, not the caller")
    }

    // MARK: The operating set after the closure

    @Test("the closed dialog and the nested one above it are reconciled before the set is validated")
    func closedIDsAreReconciled() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.targets = [FakeGeometry.adoptedWindow, Self.sheet, Self.nested]
        fixture.snapshotWindows = [Self.user, Self.other, FakeGeometry.adoptedWindow,
                                   Self.sheet, Self.nested]
        try await fixture.openTransition()

        // The two surfaces are gone from the operating set, which is the
        // effect the Command was posted for and not stale evidence.
        fixture.targets = [FakeGeometry.adoptedWindow]
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])
    }

    @Test("a window the preparation never saw still disarms the transition")
    func anUnknownWindowStillDisarms() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.targets = [FakeGeometry.adoptedWindow, Self.sheet]
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.reports.last?.detail.hasPrefix(
            "The adopted windows changed after the preparation") == true)
    }

    @Test("a real window out of place is still an obligation and still refuses")
    func aMisplacedWindowStillRefuses() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        // The surviving target is on the person's display in the evidence.
        fixture.snapshotWindows = [
            Self.user, Self.other,
            Self.reference(processID   : FakeGeometry.targetPID,
                           windowNumber: FakeGeometry.windowNumber,
                           frame       : Self.user.frame)
        ]
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.reports.last?.detail
            .contains("outside the virtual display") == true)
    }

    // MARK: Focus alone during containment

    @Test("the focus goes back while the containment cause holds the gate closed")
    func focusOnlyDuringContainment() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        // A window is still being transferred, and that cause is not the
        // focus lane's to resolve.
        fixture.gate.pause(.windowTransfer)
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user], "the restoration is allowed mid containment")
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(fixture.gate.pauseCauses == [.windowTransfer],
                "a recovered focus is not permission to send input")
        #expect(throws: InputFailure.inputPaused([.windowTransfer])) { try fixture.gate.check() }
    }

    // MARK: Duplicates, distinct activations and the budget

    @Test("a second notification of the same activation is a duplicate and buys no request")
    func duplicateActivation() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        fixture.activate(FakeGeometry.targetPID)
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])
        #expect(fixture.recovery.restoreRequests == 1)
    }

    @Test("a steal after a verified return is distinct and may ask, outside any Turn")
    func distinctActivationAfterAVerifiedReturn() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        // No Turn is held: the reset used to miss this, returning the attempt
        // only while a hold was armed.
        fixture.recovery.beginOperation()
        fixture.expectClosure()
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.recovery.isInClosureTransition)

        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.count == 1)
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)

        // The application takes the focus again a moment later, on evidence
        // the beat renewed: out of Turn nothing else runs.
        await fixture.recovery.refreshPreparation()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.count == 2, "the second steal of the same closure may ask")

        // And the third may not: two is the whole budget of one transition.
        fixture.returnUser()
        await fixture.recovery.refreshPreparation()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.count == 2)
        #expect(fixture.reports.last?.detail
            == "Both automatic requests of this closure transition were already spent")
    }

    @Test("a consumed snapshot is never the evidence of the next request")
    func aConsumedSnapshotIsNotReused() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.count == 1)
        fixture.returnUser()

        // Nothing renewed anything in between.
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.count == 1)
        #expect(fixture.reports.last?.detail
            == "No prepared action was held when this activation arrived")
    }

    @Test("an expired preparation is named and the transition renews rather than reusing it")
    func anExpiredPreparationIsRenewed() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.reports.last?.detail.hasPrefix("The prepared action expired") == true)

        await fixture.settle()
        #expect(fixture.requested == [Self.user])
    }

    @Test("a preparation renewed after activation can restore the saved user window")
    func renewalAfterActivationUsesCurrentAge() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)

        // The renewal starts after the activation whose request was refused.
        // Its age must not wrap by subtracting from that older notification.
        fixture.time += 10_000_000
        await fixture.settle()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.recovery.restoreRequests == 1)
    }

    // MARK: The protection after the surface goes

    @Test("two readings an instant apart do not end the episode while the protection holds")
    func protectionAfterTheSurfaceDisappears() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        fixture.recovery.noteClosureSurfaceGone(Self.sheet.windowNumber)

        fixture.returnUser()
        #expect(fixture.recovery.isPaused, "the panel's completion is deferred; so is the verdict")
        #expect(fixture.gate.isPaused)

        fixture.time += UserFocusRecovery.closureProtectionNanoseconds
        fixture.returnUser()
        #expect(!fixture.recovery.isPaused)
        #expect(fixture.reports.last?.outcome == .restored)
    }

    /// The extra live case: the host moved across a verified closure and
    /// nothing had measured it. The transition is the only thing that still
    /// holds the frame from before the Command, and this is it being read and
    /// classified. Nothing on the path posts: the dialog stays closed.
    @Test("the host's frame before the closure is kept, and the movement after it is measured")
    func theHostMovementIsMeasured() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.recovery.noteClosureCommandPosted()
        fixture.recovery.noteClosureSurfaceGone(Self.sheet.windowNumber)
        #expect(fixture.recovery.closureSurfaceIsGone)

        let before = try #require(fixture.recovery.closureSurfacesBefore.first {
            $0.windowNumber == FakeGeometry.adoptedWindow.windowNumber
        })
        #expect(before.frame == FakeGeometry.adoptedWindow.frame)

        let moved = FakeGeometry.reference(frame: CGRect(
            origin: CGPoint(x: before.frame.minX + 120, y: before.frame.minY + 60),
            size  : before.frame.size
        ))
        #expect(ClosureGeometryEffect.classify(
            before: before, after: moved, within: FakeGeometry.virtual
        ) == .hostMoved(from: before.frame, to: moved.frame))

        // The same reading with a size that changed as well stays unknown, and
        // neither verdict is a reason to drive the dialog again.
        let resized = FakeGeometry.reference(frame: CGRect(
            origin: moved.frame.origin,
            size  : CGSize(width: before.frame.width + 80, height: before.frame.height)
        ))
        #expect(ClosureGeometryEffect.classify(
            before: before, after: resized, within: FakeGeometry.virtual
        ) == .unknownEffect)
        #expect(fixture.recovery.closureCommandWasPosted,
                "the post stays one post; measuring geometry sends nothing")
    }

    @Test("a surface that is not the one the transition is about starts no protection")
    func anotherSurfaceStartsNoProtection() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        fixture.recovery.noteClosureSurfaceGone(Self.nested.windowNumber)
        fixture.returnUser()
        #expect(!fixture.recovery.isPaused)
        #expect(fixture.reports.last?.outcome == .restored)
    }

    // MARK: The end of the fight

    @Test("the transition's deadline names the impossibility once and stops asking")
    func theDeadlineEndsTheFight() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.frontOverride = false
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)

        fixture.time += UserFocusRecovery.closureTransitionNanoseconds
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .unrecoverable)
        let named = fixture.reports.filter { $0.outcome == .unrecoverable }.count
        fixture.recovery.verify()
        fixture.recovery.verify()
        #expect(fixture.reports.filter { $0.outcome == .unrecoverable }.count == named,
                "it is said once, not on every tick")

        // Waiting, not stopped: the person coming back still ends it.
        fixture.frontOverride = nil
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)

        // And nothing automatic asks again inside the transition that ran out.
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.reports.last?.detail
            == "The closure transition ran out of time before this request")
    }

    // MARK: Who the activation belongs to

    @Test("a remote helper of the seat's own relation is the application stealing, not the person")
    func aRemoteHelperIsNotThePerson() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()

        // The service that draws the panel takes the front. It is not adopted
        // and it is not a destination.
        fixture.sensing.frontmostProcessID = Self.helper.processID
        fixture.sensing.focusedUserWindow = Self.helper
        fixture.recovery.activationChanged(to: Self.helper.processID)
        #expect(fixture.requested == [Self.user])
        #expect(fixture.reports.last?.destination == Self.user)
        #expect(fixture.reports.first?.outcome == .restoring)
    }

    @Test("an activation nothing can classify keeps the gate closed and the destination alone")
    func anUnclassifiableActivationChangesNothing() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])

        // A process the seat cannot attest, whose window is no destination
        // either: neither the application's nor the person's.
        fixture.sensing.frontmostProcessID = 8_888
        fixture.sensing.focusedUserWindow = nil
        fixture.recovery.activationChanged(to: 8_888)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.destination == Self.user,
                "an unknown helper is not read as the person")
        #expect(fixture.reports.last?.outcome != .userTookControl)
    }

    @Test("a genuine choice of another application by the person wins and asks for nothing")
    func aGenuineUserChoiceWins() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        try await fixture.openTransition()
        fixture.activate(FakeGeometry.targetPID)
        #expect(fixture.requested == [Self.user])

        fixture.sensing.frontmostProcessID = Self.other.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.activationChanged(to: Self.other.processID)
        fixture.recovery.verify()
        #expect(fixture.requested == [Self.user], "the person's own choice is never overridden")
        #expect(fixture.reports.last?.outcome == .userTookControl)
        #expect(fixture.reports.last?.destination == Self.other)
        #expect(!fixture.gate.isPaused)
    }

    // MARK: The panic control

    @Test("stopping the seat closes the gate, terminally, and takes nothing down")
    func panicClosesTheGateFirst() async throws {
        let sender = FakeSender()
        let seat = makeSeat(sender: sender)

        seat.stopAdmittingCommands()
        #expect(sender.gate.pauseCauses == [.deliberateStop])
        #expect(throws: InputFailure.inputPaused([.deliberateStop])) { try sender.gate.check() }

        // Terminal: nothing else owns this cause, so nothing reopens it.
        sender.gate.resume(.focusRecovery)
        sender.gate.resume(.windowTransfer)
        #expect(sender.gate.isPaused)

        // The gate and nothing else: no window returned, no teardown.
        #expect(seat.adoptedWindows.isEmpty)
        #expect(seat.state != .failed)
    }

    @Test("closing the gate leaves an admitted Command alone: the stop is at the next boundary")
    func anAdmittedGestureIsNotInterrupted() throws {
        let gate = InputCommandGate()
        // The admitted Command passed this check; the driver posts its whole
        // gesture, release included, without asking again.
        try gate.check()
        gate.pause(.deliberateStop)
        #expect(throws: InputFailure.inputPaused([.deliberateStop])) { try gate.check() }
        #expect(gate.pauseCauses == [.deliberateStop],
                "the stop adds a cause and cancels nothing in flight")
    }

    // MARK: -

    @MainActor
    private final class Harness {
        let sensing = FakeSensing()
        let gate = InputCommandGate()
        var targets = [FakeGeometry.adoptedWindow]
        var preparedDestinations: [WindowReference] = []
        var preparedSurfaces: [[WindowReference]] = []
        var renewedDestinations: [WindowReference] = []
        var remoteHelperDestroyed = false
        var frontOverride: Bool?
        var requested: [WindowReference] = []
        var restoreFailure: InputFailure?
        var restoreCode: Int32 = 0
        var reports: [UserFocusRecoveryReport] = []
        var time: UInt64 = 1_000_000_000
        var snapshotWindows: [WindowReference] = [
            ClosureTransitionTests.user,
            ClosureTransitionTests.other,
            FakeGeometry.adoptedWindow
        ]

        lazy var recovery = UserFocusRecovery(sensing: sensing, gate: gate,
            adopted: { [unowned self] in targets },
            restore: { [unowned self] window in
                #expect(gate.isPaused, "The restoration call must never precede the input stop")
                requested.append(window)
                if let restoreFailure { throw restoreFailure }
                return restoreCode
            }, now: { [unowned self] in time },
            prepareDestination: { [unowned self] destination, surfaces in
                if remoteHelperDestroyed && surfaces.contains(ClosureTransitionTests.helper) {
                    throw InputFailure.inputPaused([.destinationNotPrepared])
                }
                preparedDestinations.append(destination)
                preparedSurfaces.append(surfaces)
            },
            renewDestination: { [unowned self] destination in
                renewedDestinations.append(destination)
            },
            isFrontmost: { [unowned self] in frontOverride ?? (sensing.frontmostProcessID == $0) },
            changed: { [unowned self] in reports.append($0) })

        init() {
            sensing.additionalWindows = [
                ClosureTransitionTests.user.windowNumber : ClosureTransitionTests.user,
                ClosureTransitionTests.other.windowNumber: ClosureTransitionTests.other
            ]
            sensing.focusedUserWindow = ClosureTransitionTests.user
            sensing.snapshotPreparation = { [unowned self] in
                FocusRecoverySnapshot(topologyIsValid: true,
                    virtualBounds : FakeGeometry.virtual,
                    physicalBounds: [FakeGeometry.physical],
                    windows       : snapshotWindows)
            }
        }

        /// Declares the closure the Command about to be posted is expected to
        /// make, with the remote surface the endpoint resolved for it.
        func expectClosure() {
            recovery.expectClosure(
                dialog : ClosureTransitionTests.sheet.identity,
                helpers: [ClosureTransitionTests.helper]
            )
        }

        /// A Turn, the declaration, and the preparation the driver awaits
        /// immediately before the post: the real order.
        func openTransition() async throws {
            recovery.beginHold()
            expectClosure()
            try await recovery.prepareBeforeAction()
            #expect(recovery.isInClosureTransition)
        }

        /// The driven application taking the front.
        func activate(_ processID: Int32) {
            sensing.frontmostProcessID = processID
            sensing.focusedUserWindow = FakeGeometry.adoptedWindow
            recovery.activationChanged(to: processID)
        }

        /// Turns the verification clock by hand and lets the renewal it starts
        /// run to its end, which is what the live 5 ms timer does.
        func settle() async {
            for _ in 0..<8 {
                recovery.verify()
                await Task.yield()
            }
        }

        func returnUser() {
            sensing.frontmostProcessID = ClosureTransitionTests.user.processID
            sensing.focusedUserWindow = ClosureTransitionTests.user
            recovery.verify()
            recovery.verify()
        }
    }
}
