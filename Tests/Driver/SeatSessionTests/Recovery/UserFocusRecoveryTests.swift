import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@Suite("User focus recovery")
@MainActor
struct UserFocusRecoveryTests {
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

    private static let user = reference(
        processID   : 99,
        windowNumber: 801,
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500)
    )
    private static let other = reference(
        processID   : 100,
        windowNumber: 802,
        frame       : CGRect(x: 110, y: 110, width: 600, height: 500)
    )

    @Test("notification provenance survives verification without changing the recovery gate")
    func notificationProvenance() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
        fixture.recovery.activationChanged(to: FakeGeometry.targetPID,
            source: .workspaceNotification, receivedAt: fixture.time - 300)
        fixture.returnUser()
        #expect(fixture.reports.last?.timing.activationSource == .workspaceNotification)
        #expect(fixture.reports.last?.timing.notificationReceivedAtUptimeNanoseconds == fixture.time - 300)
        #expect(fixture.reports.last?.outcome == .restored)
        fixture.recovery.stop()
    }

    @Test("the gate closes before restoration and needs two matching focus readings")
    func closesBeforeRestoring() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.gate.isPaused)
        #expect(throws: InputFailure.inputPaused([.focusRecovery])) { try fixture.gate.check() }
        fixture.sensing.frontmostProcessID = Self.user.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.verify()
        #expect(fixture.gate.isPaused, "An active app is not proof of the correct focused window")
        fixture.sensing.focusedUserWindow = Self.user
        fixture.recovery.verify()
        #expect(fixture.gate.isPaused)
        fixture.recovery.verify()
        #expect(!fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .restored)
        fixture.recovery.stop()
    }

    @Test("a removed, physical target, uncertain user gesture or missing destination cannot be restored",
          arguments: 0..<5)
    func refusesUnsafeDestination(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        switch variant {
        case 0:
            fixture.sensing.additionalWindows[Self.user.windowNumber] = nil
            fixture.sensing.focusRecoverySnapshot = nil
        case 1:
            fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
                virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
                windows: [Self.user, FakeGeometry.reference(frame: Self.user.frame)])
        case 2: fixture.sensing.userMayBeSwitchingApplications = true
        case 3: fixture.sensing.userWindowIsPhysical = false
        default: fixture.sensing.physicalTopologyIsUnchanged = false
        }
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        fixture.recovery.stop()
    }

    @Test("a window raised between Turns names its outcome instead of leaving the seat silent")
    func activationOutsideATurnOpensAnEpisode() async throws {
        let fixture = Harness()
        // The person is in their own window, and the watch keeps it current.
        fixture.sensing.frontmostProcessID = Self.user.processID
        fixture.recovery.activationChanged(to: Self.user.processID)

        // No Turn is held and no Command ran: this is the dialog the driven
        // application raises by itself, which used to reach no armed recovery.
        fixture.activateTarget()
        #expect(fixture.gate.isPaused, "the gate closes before any validation or private call")
        #expect(fixture.reports.first?.outcome == .restoring)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.reports.last?.detail
            == "No prepared action was held when this activation arrived",
            "the miss is named: the preparation belongs to the input path")
        #expect(fixture.requested.isEmpty, "an unprepared destination is never asked for")

        // The person coming back is still what reopens the gate, and it reopens
        // nothing else.
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a refresh arms the activation an application raises by itself, once")
    func refreshArmsAnActivationOutsideATurn() async throws {
        let fixture = Harness()
        // No Turn, no operation and no Command: the beat's refresh is the only
        // thing that ran, and the person's application is the front one while
        // it does. This is the popup that used to meet a named miss.
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.snapshotReadCount == 1)

        fixture.activateTarget()
        #expect(fixture.requested == [Self.user], "the refreshed evidence survives the episode it opens")
        #expect(fixture.reports.first?.outcome == .restoring)
        #expect(fixture.sensing.snapshotReadCount == 1, "the urgent path enumerates nothing")

        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(!fixture.gate.isPaused)

        // The budget is untouched: this is still one operation, and its one
        // automatic request is spent however fresh the next preparation is.
        await fixture.recovery.refreshPreparation()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)
        #expect(fixture.reports.last?.detail
            == "The one automatic request of this episode was already spent")
        fixture.recovery.stop()
    }

    @Test("a refresh stores nothing when any guard of a preparation fails", arguments: 0..<6)
    func refreshKeepsEveryGuard(_ variant: Int) async throws {
        let fixture = Harness()
        switch variant {
        // The constraint the whole feature turns on: once the driven
        // application has the front, no preparation can be built at all.
        case 0: fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
        case 1: fixture.sensing.userMayBeSwitchingApplications = true
        case 2: fixture.sensing.userWindowIsPhysical = false
        case 3: fixture.sensing.fenceIsActive = false
        case 4: fixture.identityUnavailable = true
        default: fixture.sensing.preparedSnapshot = nil
        }
        // Twice, because the second beat is the one that reuses whatever
        // destination the first left in hand instead of deriving it again.
        await fixture.recovery.refreshPreparation()
        await fixture.recovery.refreshPreparation()

        // The guards go back to passing, so what the activation meets is the
        // absent preparation and never a live refusal standing in for it.
        fixture.sensing.userMayBeSwitchingApplications = false
        fixture.sensing.fenceIsActive = true
        fixture.identityUnavailable = false
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail
            == "No prepared action was held when this activation arrived")
        fixture.recovery.stop()
    }

    @Test("the beat derives the destination on a focus signal and never once a second for nothing")
    func beatDerivesTheDestinationOnlyOnASignal() async throws {
        let fixture = Harness()
        await fixture.recovery.refreshPreparation()
        let firstBeat = fixture.sensing.userWindowReadCount
        #expect(firstBeat > 0, "the first beat holds no destination, so it derives one")

        // Nothing signalled in between, so the person's focused window is the
        // one already in hand and their application is asked nothing.
        await fixture.recovery.refreshPreparation()
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.userWindowReadCount == firstBeat)
        #expect(fixture.sensing.snapshotReadCount == 3,
                "the snapshot is what expires, so every beat still renews it")

        // The notification the watch delivers when the person moves within
        // their own application. The beat after it derives again.
        fixture.recovery.userWindowChanged()
        let afterSignal = fixture.sensing.userWindowReadCount
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.userWindowReadCount > afterSignal)
        fixture.recovery.stop()
    }

    @Test("an activation is armed by a beat that reused the destination it already held")
    func reusedDestinationStillArmsAnActivation() async throws {
        let fixture = Harness()
        await fixture.recovery.refreshPreparation()
        let firstBeat = fixture.sensing.userWindowReadCount
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.userWindowReadCount == firstBeat)

        // The popup the driven application raises by itself, arriving on the
        // evidence of a beat that derived nothing of its own.
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a destination that turned invalid with no signal behind it is refused at the activation")
    func silentlyInvalidDestinationIsRefusedByTheSnapshot() async throws {
        let fixture = Harness()
        await fixture.recovery.refreshPreparation()

        // The person drags their own window over the virtual display's area.
        // No focus notification describes that, so the beat keeps the
        // destination and the snapshot prepared beside it is what refuses.
        let moved = Self.user.replacingFrame(FakeGeometry.virtual)
        fixture.sensing.additionalWindows[Self.user.windowNumber] = moved
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
            virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
            windows: [moved, Self.other, FakeGeometry.adoptedWindow])
        await fixture.recovery.refreshPreparation()

        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail == "The prepared user window is absent or invalid")
        fixture.recovery.stop()
    }

    @Test("a beat that derived nothing derives again instead of waiting for the next signal")
    func anEmptyDerivationIsRetriedOnTheNextBeat() async throws {
        let fixture = Harness()
        // What a 50 ms accessibility timeout in the person's application looks
        // like from here: the read answers nothing and leaves nothing in hand.
        fixture.sensing.focusedUserWindow = nil
        await fixture.recovery.refreshPreparation()
        let firstBeat = fixture.sensing.userWindowReadCount

        fixture.sensing.focusedUserWindow = Self.user
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.userWindowReadCount > firstBeat)

        fixture.activateTarget()
        #expect(fixture.requested == [Self.user], "the retried beat armed this activation")
        fixture.recovery.stop()
    }

    @Test("a refreshed preparation expires at the same age as a prepared one")
    func refreshedPreparationExpires() async throws {
        let fixture = Harness()
        await fixture.recovery.refreshPreparation()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail
            == "The prepared action expired: 1250.0 ms old, and the limit is 1250.0 ms")
        fixture.recovery.stop()
    }

    @Test("a refresh during a held Turn leaves the Turn exactly as it is")
    func refreshDuringAHoldChangesNothing() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        await fixture.recovery.refreshPreparation()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(!fixture.gate.isPaused)

        // And a refresh while the seat waits for the person rearms nothing:
        // the episode is open, its request is spent, and a reading taken now
        // would only describe a seat the person has not come back to.
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.time += UserFocusRecovery.verificationWindowNanoseconds
        fixture.recovery.verify()
        let reads = fixture.sensing.snapshotReadCount
        await fixture.recovery.refreshPreparation()
        #expect(fixture.sensing.snapshotReadCount == reads)
        #expect(fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("one automatic attempt for the whole operation, however many activations arrive")
    func oneRequestPerOperation() async throws {
        let fixture = Harness()
        fixture.recovery.beginOperation()
        // Out of Turn only the input path builds a preparation, so the test
        // builds the one this operation would otherwise miss on.
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)

        // The focus verified, and the operation is still the same operation:
        // the second window it raises does not buy a second request.
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)
        #expect(fixture.reports.last?.detail
            == "The one automatic request of this episode was already spent")
        #expect(fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("the episode ends with the operation, and ending it opens no other")
    func episodeEndsWithTheOperation() async throws {
        let fixture = Harness()
        fixture.recovery.beginOperation()
        try await fixture.recovery.prepareBeforeAction()
        fixture.recovery.endOperation()

        await #expect(throws: InputFailure.inputPaused([.holdEnded])) {
            try await fixture.recovery.prepareBeforeAction()
        }
        // The next activation is the next operation: it may ask once, and what
        // the ended episode prepared is not there to authorize it.
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.reports.last?.detail
            == "No prepared action was held when this activation arrived")
        fixture.recovery.stop()
    }

    /// An activation outside a Turn, armed by the beat, restored and verified,
    /// with no transfer after it: the window it announced was gone before the
    /// seat saw it. `joinTransfer` is a transfer that begins after all.
    private static func restoredOperation(joinTransfer: Bool = false) async -> Harness {
        let fixture = Harness()
        await fixture.recovery.refreshPreparation()
        fixture.activateTarget()
        fixture.returnUser()
        if joinTransfer { fixture.recovery.beginOperation() }
        return fixture
    }

    @Test("an operation no transfer joined ends once restored, and the next activation asks once")
    func anOperationWithoutATransferEnds() async throws {
        let fixture = await Self.restoredOperation()
        #expect(fixture.requested.count == 1)
        #expect(!fixture.gate.isPaused)

        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        await fixture.recovery.refreshPreparation()
        fixture.activateTarget()
        #expect(fixture.requested.count == 2, "the next panel's activation is the next operation")
        #expect(fixture.reports.last?.outcome == .restoring)
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a second activation of the same operation is refused, before the bound or with a transfer joined",
          arguments: [false, true])
    func aSecondActivationOfTheSameOperationIsRefused(joinTransfer: Bool) async throws {
        let fixture = await Self.restoredOperation(joinTransfer: joinTransfer)
        fixture.time += joinTransfer
            ? UserFocusRecovery.preparationLifetimeNanoseconds + 1
            : UserFocusRecovery.preparationLifetimeNanoseconds / 2
        await fixture.recovery.refreshPreparation()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)
        #expect(fixture.reports.last?.detail
            == "The one automatic request of this episode was already spent")
        #expect(fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a transfer inside a held Turn neither rearms the Turn nor disarms it")
    func operationInsideAHoldChangesNothing() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()

        // The bracket of a window transfer, opened and closed inside the Turn.
        fixture.recovery.beginOperation()
        fixture.recovery.endOperation()

        fixture.activateTarget()
        #expect(fixture.requested == [Self.user], "the Turn's preparation survived the transfer")
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("one request per activation: never twice inside an episode, once again after it")
    func oneRequestPerActivation() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)

        fixture.time += 300_000_000
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.gate.isPaused)

        // Inside the episode nothing asks a second time: a verification that did
        // not agree is not a reason to activate the window again.
        fixture.activateTarget()
        fixture.recovery.verify()
        #expect(fixture.requested.count == 1)
        #expect(fixture.gate.isPaused)

        // The person's window verified twice ends the episode, and the next
        // activation is a new one with its own single request. The hold never
        // ended: this is the second dialog of one run.
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 2, "the second activation of a hold may ask once too")
        #expect(fixture.gate.isPaused)

        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("the latest user application replaces the cached destination")
    func followsUser() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.sensing.frontmostProcessID = Self.other.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.activationChanged(to: Self.other.processID)
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.other])
        fixture.recovery.stop()
    }

    @Test("a user switch during recovery wins, with no second activation request")
    func userWinsDuringRecovery() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.sensing.frontmostProcessID = Self.other.processID
        fixture.sensing.focusedUserWindow = Self.other
        fixture.recovery.activationChanged(to: Self.other.processID)
        fixture.recovery.verify()
        #expect(fixture.reports.last?.outcome == .userTookControl)
        #expect(fixture.requested == [Self.user])
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("stopping invalidates a pending recovery and never reopens its gate")
    func teardown() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.recovery.stop()
        fixture.returnUser()
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .cancelled)
    }

    @Test("an idle target activation is answered rather than ignored, and asks for nothing")
    func idle() {
        let fixture = Harness()
        // The episode opens with nothing prepared and no user window ever
        // observed. It names that and asks for no destination it does not have.
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        fixture.recovery.stop()
    }

    @Test("a shared reading retains every destination and virtual-window guard", arguments: 0..<9)
    func batchedReadings(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        var windows = [Self.user, FakeGeometry.adoptedWindow]
        var physical = [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        switch variant {
        case 1:
            windows.append(FakeGeometry.reference(frame: Self.user.frame, windowNumber: 999))
        case 2:
            windows[0] = Self.reference(
                processID   : 123,
                windowNumber: Self.user.windowNumber,
                frame       : Self.user.frame
            )
        case 3: windows.removeLast()
        case 4: windows[0] = Self.user.replacingFrame(.zero)
        case 5: physical = []
        case 7: windows.removeFirst()
        case 8: fixture.sensing.fenceIsActive = false
        default: break
        }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid: variant != 6,
            virtualBounds: FakeGeometry.virtual,
            physicalBounds: physical,
            windows: windows)
        if variant == 8 {
            await #expect(throws: InputFailure.inputPaused([.fenceInactive])) {
                try await fixture.recovery.prepareBeforeAction()
            }
        } else { try await fixture.recovery.prepareBeforeAction() }
        fixture.activateTarget()
        #expect(fixture.requested.count == (variant == 0 ? 1 : 0))
        #expect(fixture.gate.isPaused)
        if variant != 0 {
            #expect(fixture.reports.last?.timing.requestFinishedNanoseconds == 0)
        }
        fixture.recovery.stop()
    }

    @Test("activation without a prepared action waits instead of scanning windows")
    func missingPreparationWaits() {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 0)
        #expect(fixture.reports.last?.detail
            == "No prepared action was held when this activation arrived")
        fixture.recovery.stop()
    }

    @Test("activation consumes prepared readings without another window enumeration")
    func preparedReadingsLeaveUrgentPath() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.sensing.focusRecoverySnapshot = nil
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.recovery.stop()
    }

    @Test("an expired preparation pauses with no fallback scan or activation")
    func expiration() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 1)
        #expect(fixture.reports.last?.detail
            == "The prepared action expired: 1250.0 ms old, and the limit is 1250.0 ms")
        fixture.recovery.stop()
    }

    /// The lifetime is 1.25 s because the heartbeat that rebuilds a preparation
    /// is 1 s: at 1 s a preparation stamped on one beat was exactly at its
    /// expiry on the next. Both sides of the boundary are pinned here, and so is
    /// the number, because the whole point of the value is that it exceeds 1 s.
    @Test("a preparation is usable at exactly its lifetime and expired one nanosecond later")
    func lifetimeBoundary() async throws {
        #expect(UserFocusRecovery.preparationLifetimeNanoseconds == 1_250_000_000)

        let atTheLimit = Harness()
        atTheLimit.recovery.beginHold()
        try await atTheLimit.recovery.prepareBeforeAction()
        atTheLimit.time += UserFocusRecovery.preparationLifetimeNanoseconds
        atTheLimit.activateTarget()
        #expect(atTheLimit.requested == [Self.user])
        atTheLimit.recovery.stop()

        let pastIt = Harness()
        pastIt.recovery.beginHold()
        try await pastIt.recovery.prepareBeforeAction()
        pastIt.time += UserFocusRecovery.preparationLifetimeNanoseconds + 1
        pastIt.activateTarget()
        #expect(pastIt.requested.isEmpty)
        #expect(pastIt.gate.isPaused)
        #expect(pastIt.reports.last?.detail
            == "The prepared action expired: 1250.0 ms old, and the limit is 1250.0 ms")
        pastIt.recovery.stop()
    }

    @Test("a window adopted after the preparation disarms it, and the refusal names both sets")
    func adoptedSetChanged() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()

        // What an application's own dialog looks like from here: the follower
        // takes it in, so the adopted set is no longer the prepared one.
        let dialog = Self.reference(
            processID   : FakeGeometry.targetPID,
            windowNumber: 902,
            frame       : FakeGeometry.adoptedWindow.frame
        )
        fixture.targets.append(dialog)
        fixture.activateTarget()

        #expect(fixture.requested.isEmpty, "no request goes out on evidence that predates the dialog")
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail
            == "The adopted windows changed after the preparation: prepared "
                + "\(FakeGeometry.adoptedWindow.windowNumber), now "
                + "\(FakeGeometry.adoptedWindow.windowNumber), 902")
        fixture.recovery.stop()
    }

    @Test("a command taken while the target is in front does not disarm the pending recovery")
    func preparationSurvivesACommandTakenWithTheTargetInFront() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()

        // The dialog the previous command opened has already brought the target
        // to the front, and the next command is prepared before the activation
        // notification lands. This preparation cannot be rebuilt: the person's
        // application is not the front one to read a fresh destination from.
        fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
        try await fixture.recovery.prepareBeforeAction()

        fixture.activateTarget()
        #expect(fixture.requested == [Self.user],
                "the preparation made before the dialog still arms this activation")
        #expect(fixture.reports.last?.outcome != .waitingForUser)
        fixture.recovery.stop()
    }

    @Test("a user window notification invalidates a completed preparation")
    func changedWindow() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.recovery.userWindowChanged()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("late preparation cannot survive a changed hold, user, teardown, target set or cancellation",
          arguments: 0..<7)
    func latePreparation(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        var resume: CheckedContinuation<FocusRecoverySnapshot?, Never>?
        let snapshot = fixture.sensing.preparedSnapshot
        fixture.sensing.snapshotPreparation = {
            await withCheckedContinuation { resume = $0 }
        }
        let task = Task { try await fixture.recovery.prepareBeforeAction() }
        while resume == nil { await Task.yield() }
        switch variant {
        case 0: fixture.recovery.endHold(); fixture.recovery.beginHold()
        case 1:
            fixture.sensing.frontmostProcessID = Self.other.processID
            fixture.sensing.focusedUserWindow = Self.other
            fixture.recovery.activationChanged(to: Self.other.processID)
        case 2: fixture.recovery.stop()
        case 3: fixture.recovery.userWindowChanged()
        case 4: fixture.targets.append(Self.other)
        case 5: task.cancel()
        default: fixture.sensing.fenceIsActive = false
        }
        resume?.resume(returning: snapshot)
        let result = await task.result
        if variant == 2 || variant == 5 || variant == 6 {
            if case .success = result { Issue.record("Cancelled preparation must refuse posting") }
        }
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        fixture.recovery.stop()
    }

    @Test("current topology and user intent still veto a prepared request", arguments: 0..<3)
    func liveGuards(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        switch variant {
        case 0: fixture.sensing.physicalTopologyIsUnchanged = false
        case 1: fixture.sensing.virtualDisplayIsOnline = false
        default: fixture.sensing.userMayBeSwitchingApplications = true
        }
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.sensing.snapshotReadCount == 1)
        fixture.recovery.stop()
    }

    @Test("identity reads happen before input; a missing identity leaves recovery unarmed", arguments: [false, true])
    func preparedIdentity(_ missing: Bool) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.identityUnavailable = missing
        try await fixture.recovery.prepareBeforeAction()
        #expect(fixture.preparedDestinations == (missing ? [] : [Self.user]))
        fixture.identityUnavailable = true
        fixture.activateTarget()
        #expect(fixture.requested == (missing ? [] : [Self.user]))
        #expect(fixture.preparedDestinations == (missing ? [] : [Self.user]))
        fixture.recovery.stop()
    }

    @Test("the direct front-process witness decides; a refusal survives verification timeout", arguments: [false, true])
    func directFrontWitness(_ matches: Bool) async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.frontOverride = matches
        // The notification and NSWorkspace cache need not agree yet. The
        // injected WindowServer witness is authoritative for this last guard.
        fixture.recovery.activationChanged(to: FakeGeometry.targetPID)
        #expect(fixture.requested == (matches ? [Self.user] : []))
        if !matches {
            let detail = fixture.reports.last?.detail
            #expect(detail == "The front process no longer matches the activating target")
            fixture.sensing.frontmostProcessID = FakeGeometry.targetPID
            fixture.sensing.focusedUserWindow = nil
            fixture.time += 300_000_000
            fixture.recovery.verify()
            #expect(fixture.reports.last?.detail == detail)
        }
        fixture.recovery.stop()
    }

    @Test("a disabled fence blocks input and resumption, without delaying focus-only restoration")
    func fenceCheckedAtInputBoundaries() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.sensing.fenceIsActive = false
        await #expect(throws: InputFailure.inputPaused([.fenceInactive])) {
            try await fixture.recovery.prepareBeforeAction()
        }
        fixture.sensing.fenceIsActive = true
        try await fixture.recovery.prepareBeforeAction()
        fixture.sensing.fenceIsActive = false
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        fixture.returnUser()
        #expect(fixture.gate.isPaused, "No command may resume with an inactive fence")
        fixture.sensing.fenceIsActive = true
        fixture.returnUser()
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a focused user window may extend beyond a physical screen without entering the virtual display",
          arguments: 0..<6)
    func partiallyVisibleUserWindow(_ variant: Int) async throws {
        let fixture = Harness()
        let physical = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var frame = CGRect(x: 316, y: 58, width: 1571, height: 852)
        var physicalBounds = [physical]
        switch variant {
        case 1: frame.origin.x = -316
        case 2:
            physicalBounds.append(CGRect(x: 1512, y: 0, width: 1512, height: 982))
        case 3: frame.origin.x = 1512
        case 4: frame.origin = CGPoint(x: 1600, y: 58)
        case 5: frame.size.height = 1200
        default: break
        }
        let user = Self.user.replacingFrame(frame)
        let virtual = CGRect(x: 1512, y: 982, width: 2560, height: 1440)
        let target = FakeGeometry.reference(
            frame: CGRect(x: 2192, y: 1288, width: 1200, height: 828)
        )
        fixture.targets = [target]
        fixture.sensing.virtualDisplayBounds = virtual
        fixture.sensing.additionalWindows[user.windowNumber] = user
        fixture.sensing.focusedUserWindow = user
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
            virtualBounds: virtual, physicalBounds: physicalBounds, windows: [user, target])
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        if variant < 3 {
            #expect(fixture.requested == [user])
            fixture.sensing.frontmostProcessID = user.processID
            fixture.sensing.focusedUserWindow = user
            fixture.recovery.verify()
            fixture.recovery.verify()
            #expect(fixture.reports.last?.outcome == .restored)
            #expect(!fixture.gate.isPaused)
        } else {
            #expect(fixture.requested.isEmpty)
            #expect(fixture.gate.isPaused)
        }
        fixture.recovery.stop()
    }

    @Test("an incomplete window list pauses recovery without blaming the displays")
    func incompleteWindowDiagnostic() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid      : true,
            virtualBounds        : FakeGeometry.virtual,
            physicalBounds       : [FakeGeometry.physical],
            windows              : [Self.user, FakeGeometry.adoptedWindow],
            windowsAreComplete   : false,
            firstUnresolvedWindow: 2
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail.contains("window list is incomplete at Window ID 2") == true)
        #expect(fixture.reports.last?.detail.contains("topology") == false)
    }

    @Test("a snapshot scoped to another process cannot authorize restoration")
    func wrongSnapshotScope() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid  : true,
            virtualBounds    : FakeGeometry.virtual,
            physicalBounds   : [FakeGeometry.physical],
            windows          : [Self.user, FakeGeometry.adoptedWindow],
            coveredProcessIDs: [Self.user.processID]
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
    }

    @Test("a physical dialog of another adopted application prevents restoration")
    func otherAdoptedProcessHasPhysicalWindow() async throws {
        let fixture = Harness()
        defer { fixture.recovery.stop() }
        let second = Self.reference(
            processID   : 5555,
            windowNumber: 901,
            frame       : FakeGeometry.adoptedWindow.frame
        )
        let dialog = Self.reference(
            processID   : second.processID,
            windowNumber: 902,
            frame       : Self.user.frame
        )
        fixture.targets.append(second)
        fixture.sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid: true,
            virtualBounds  : FakeGeometry.virtual,
            physicalBounds : [FakeGeometry.physical],
            windows        : [Self.user, FakeGeometry.adoptedWindow, second, dialog]
        )
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.isEmpty)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.last?.detail
            == "A prepared target window is outside the virtual display: Window ID 902 of "
                + "PID \(second.processID) at \(Self.user.frame)",
            "the refusal names the window it refused on")
    }

    @Test("the whole restoration call reaches the report on return and on throw, and stays absent otherwise",
          arguments: 0..<3)
    func fullRestoreCallPropagation(_ variant: Int) async throws {
        let fixture = Harness()
        fixture.request.restoreCallNanoseconds = 0
        fixture.request.restoreCallControlNanoseconds = 7
        if variant == 1 { fixture.restoreFailure = .inputPaused([.destinationNotPrepared]) }
        if variant == 2 { fixture.sensing.userMayBeSwitchingApplications = true }
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        // A granted request emits its next report once focus is verified.
        if variant == 0 { fixture.returnUser() }
        let timing = try #require(fixture.reports.last?.timing)
        if variant == 2 {
            #expect(fixture.requested.isEmpty)
            #expect(timing.restoreCallNanoseconds == nil, "An uninvoked call has no duration")
            #expect(timing.restoreCallControlNanoseconds == nil)
        } else {
            #expect(fixture.requested == [Self.user])
            #expect(timing.restoreCallNanoseconds == 0, "A measured zero is not an absent measurement")
            #expect(timing.restoreCallControlNanoseconds == 7)
        }
        #expect(timing.activationNanoseconds == 0)
        fixture.recovery.stop()
    }

    @Test("a refused request reports no full-call duration from the previous one")
    func fullRestoreCallIsNotReused() async throws {
        let fixture = Harness()
        fixture.request.restoreCallNanoseconds = 1_234
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        fixture.returnUser()
        #expect(fixture.reports.last?.timing.restoreCallNanoseconds == 1_234)
        fixture.sensing.userMayBeSwitchingApplications = true
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested.count == 1)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.reports.last?.timing.restoreCallNanoseconds == nil)
        fixture.recovery.stop()
    }

    @Test("only a request in flight and unverified reads as restoring, and the gate reads neither")
    func restoringIsTheNarrowHalfOfPaused() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.activateTarget()
        #expect(fixture.requested == [Self.user])
        #expect(fixture.recovery.isRestoring, "the request returned 0 and the readings are owed")
        #expect(fixture.gate.isPaused)

        // The 250 ms the verification is given. Past it the episode is open and
        // the seat is waiting for a person who may not be at the keyboard.
        fixture.time += UserFocusRecovery.verificationWindowNanoseconds
        #expect(fixture.recovery.isPaused)
        #expect(!fixture.recovery.isRestoring)
        #expect(fixture.gate.isPaused, "and the input stop does not read the difference")

        fixture.returnUser()
        #expect(!fixture.recovery.isPaused)
        #expect(!fixture.recovery.isRestoring)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a miss, a throw and a refusal are all the seat waiting, never restoring",
          arguments: 0..<3)
    func everyUnaskedOrRefusedRequestIsWaiting(_ variant: Int) async throws {
        let fixture = Harness()
        switch variant {
        case 1: fixture.restoreFailure = .inputPaused([.destinationNotPrepared])
        case 2: fixture.restoreCode = 1
        default: break
        }
        fixture.recovery.beginHold()
        // Variant 0 prepares nothing, so the activation arrives on a miss.
        if variant != 0 { try await fixture.recovery.prepareBeforeAction() }
        fixture.activateTarget()

        #expect(fixture.recovery.isPaused)
        #expect(!fixture.recovery.isRestoring)
        #expect(fixture.reports.last?.outcome == .waitingForUser)
        #expect(fixture.gate.isPaused, "the input stop is closed in this state too")
        fixture.recovery.stop()
    }

    // MARK: An activation the seat causes on purpose (ADR 0013)

    @Test("an expected activation of the target closes nothing, reports nothing and spends nothing")
    func expectedActivationIsNotASteal() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.recovery.expectActivation(of: FakeGeometry.targetPID, until: fixture.time + 1_000_000_000)
        fixture.activateTarget()
        #expect(!fixture.gate.isPaused)
        #expect(!fixture.recovery.isPaused)
        #expect(fixture.reports.isEmpty)
        #expect(fixture.requested.isEmpty)
        #expect(fixture.recovery.restoreRequests == 0)

        // Ended, the same activation is a steal again, with its one request intact.
        fixture.recovery.endExpectedActivation()
        fixture.activateTarget()
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.first?.outcome == .restoring)
        #expect(fixture.requested == [Self.user])
        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        fixture.recovery.stop()
    }

    @Test("an expectation past its deadline explains nothing")
    func expectationEndsAtItsDeadline() async throws {
        let fixture = Harness()
        fixture.recovery.beginHold()
        try await fixture.recovery.prepareBeforeAction()
        fixture.recovery.expectActivation(of: FakeGeometry.targetPID, until: fixture.time + 100)
        fixture.time += 100
        fixture.activateTarget()
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.first?.outcome == .restoring)
        #expect(fixture.requested == [Self.user])
        fixture.recovery.stop()
    }

    @Test("the person switching application during an expectation still becomes the destination")
    func personStillChoosesDuringAnExpectation() {
        let fixture = Harness()
        fixture.recovery.beginHold()
        fixture.recovery.expectActivation(of: FakeGeometry.targetPID, until: fixture.time + 1_000_000_000)
        fixture.activateTarget()
        fixture.bringInFront(Self.other)
        fixture.recovery.activationChanged(to: Self.other.processID)
        fixture.recovery.endExpectedActivation()

        // Nothing read the person's window again: the destination is the one
        // their activation recorded while the expectation stood.
        fixture.activateTarget()
        #expect(fixture.reports.first?.destination == Self.other)
        fixture.recovery.stop()
    }

    @Test("An admitted menu command runs once on the target foreground before handback")
    func aScopedMenuCommandRunsBeforeHandback() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in fixture.bringInFront($0) }
        var commands = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { true },
            atMost: 1_000_000_000,
            performOnce: {
                commands += 1
                #expect(fixture.sensing.frontmostProcessID == FakeGeometry.targetPID)
                #expect(fixture.requested == [FakeGeometry.adoptedWindow])
                return true
            }
        )
        #expect(commands == 1)
        #expect(run.outcome == .ready(afterMilliseconds: 0))
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.sensing.frontmostProcessID == Self.user.processID)
        #expect(fixture.reports.isEmpty)
        fixture.recovery.stop()
    }

    @Test("Readiness losing the adopted identity or foreground cannot dispatch a command",
          arguments: [false, true])
    func aScopedCommandNeedsItsLiveIdentityAndForeground(_ losesForeground: Bool) async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in fixture.bringInFront($0) }
        var commands = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: {
                if losesForeground { fixture.bringInFront(Self.other) }
                else { fixture.targets = [] }
                return true
            },
            atMost: 1_000_000_000,
            performOnce: { commands += 1; return true }
        )
        #expect(commands == 0)
        guard case .notReady = run.outcome else { Issue.record("False readiness: \(run.outcome)"); return }
        #expect(fixture.sensing.frontmostProcessID == (losesForeground ? Self.other.processID : Self.user.processID))
        #expect(fixture.requested.count == (losesForeground ? 1 : 2))
        fixture.recovery.stop()
    }

    @Test("A dispatched command is not replayed or erased by an unverified handback")
    func aScopedCommandSurvivesHandbackFailure() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in
            fixture.bringInFront($0)
            if $0.processID == Self.user.processID { fixture.sensing.focusedUserWindow = nil }
        }
        var commands = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { true },
            atMost: 1_000_000_000,
            performOnce: { commands += 1; return true }
        )
        #expect(commands == 1)
        #expect(run.outcome == .handbackNotVerified)
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.reports.isEmpty)
        fixture.recovery.stop()
    }

    @Test("a brief activation brings the target in front and gives the front back, reporting nothing")
    func briefActivationGivesTheFrontBack() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in fixture.bringInFront($0) }
        var reads = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until : {
                reads += 1
                fixture.time += 20_000_000
                // The workspace notification of the seat's own request lands in the poll.
                if reads == 1 { fixture.recovery.activationChanged(to: FakeGeometry.targetPID) }
                return reads == 2
            },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .ready(afterMilliseconds: 40))
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user], "in front once, back once")
        #expect(!fixture.gate.isPaused)
        #expect(fixture.reports.isEmpty, "nothing was read as the person's focus being taken")

        // Over, the target taking the front is a steal again, and the
        // preparation rebuilt at the end answers it.
        fixture.activateTarget()
        #expect(fixture.gate.isPaused)
        #expect(fixture.requested.last == Self.user)
        fixture.recovery.stop()
    }

    @Test("a brief activation with no window of the person's in front refuses and asks for nothing")
    func briefActivationNeedsAPersonsWindow() async {
        let fixture = Harness()
        fixture.sensing.focusedUserWindow = nil
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until : { true },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .refused(.noUserWindow))
        #expect(fixture.requested.isEmpty)
        #expect(fixture.preparedDestinations.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("the front the person takes during a brief activation stays theirs", arguments: [false, true])
    func personsChoiceDuringABriefActivationStands(readsReady: Bool) async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in fixture.bringInFront($0) }
        var reads = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until : {
                reads += 1
                fixture.bringInFront(Self.other)
                fixture.recovery.activationChanged(to: Self.other.processID)
                return readsReady
            },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .notReady(afterMilliseconds: 0), "A changed foreground invalidates the predicate")
        #expect(reads == 1, "the poll stops once the front is no longer the target's")
        #expect(fixture.requested == [FakeGeometry.adoptedWindow], "nothing is handed back over the person")
        #expect(fixture.reports.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("A server front witness cannot authorize readiness before workspace activation agrees")
    func briefReadinessNeedsWorkspaceAgreement() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.frontOverride = true
        fixture.onRestore = { [unowned fixture] window in
            if window.processID == Self.user.processID {
                fixture.frontOverride = false
                fixture.bringInFront(window)
            }
        }
        var reads = 0
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { reads += 1; return true },
            atMost: 100_000_000
        )
        #expect(run.outcome == .notReady(afterMilliseconds: 0))
        #expect(reads == 0)
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.reports.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("Readiness that finishes after the deadline does not authorize dispatch")
    func aLateReadinessResultIsNotReady() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] in fixture.bringInFront($0) }
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { fixture.time += 1_000_000_001; return true },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .notReady(afterMilliseconds: 1000))
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.reports.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("Brief handback can settle after the ordinary recovery verification window")
    func aDelayedBriefHandbackCanBeVerified() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        var handbackReads = 0
        fixture.onRestore = { [unowned fixture] window in
            fixture.bringInFront(window)
            if window.processID == Self.user.processID {
                fixture.sensing.windowGeometryOverride = { number in
                    guard number == Self.user.windowNumber else { return fixture.sensing.geometry }
                    handbackReads += 1
                    if handbackReads == 1 { fixture.time += 300_000_000 }
                    return Self.user
                }
            }
        }
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { true },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .ready(afterMilliseconds: 0))
        #expect(handbackReads >= 2)
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.reports.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("A handback reading that finishes after its deadline cannot authorize readiness")
    func aLateHandbackReadingIsNotReady() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        var handbackReads = 0
        fixture.onRestore = { [unowned fixture] window in
            fixture.bringInFront(window)
            if window.processID == Self.user.processID {
                fixture.sensing.windowGeometryOverride = { number in
                    guard number == Self.user.windowNumber else { return fixture.sensing.geometry }
                    handbackReads += 1
                    if handbackReads == 2 { fixture.time += UserFocusRecovery.briefHandbackLimitNanoseconds + 1 }
                    return Self.user
                }
            }
        }
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until: { true },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .handbackNotVerified)
        #expect(handbackReads >= 2)
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user])
        #expect(fixture.reports.isEmpty)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @Test("a handback the target keeps goes to the ordinary recovery, never to a silent success")
    func unverifiedHandbackFallsBack() async {
        let fixture = Harness()
        fixture.requiresPausedGate = false
        fixture.onRestore = { [unowned fixture] window in
            // The target keeps the front whatever is asked for.
            if window.processID == FakeGeometry.targetPID { fixture.bringInFront(window) }
        }
        let run = await fixture.recovery.bringBrieflyInFront(
            FakeGeometry.adoptedWindow,
            until : { true },
            atMost: 1_000_000_000
        )
        #expect(run.outcome == .handbackNotVerified)
        #expect(fixture.gate.isPaused)
        #expect(fixture.reports.first?.outcome == .restoring)
        #expect(fixture.reports.first?.timing.activationSource == .briefActivationHandback)
        #expect(fixture.requested == [FakeGeometry.adoptedWindow, Self.user], "the handback was the one request")

        fixture.returnUser()
        #expect(fixture.reports.last?.outcome == .restored)
        #expect(!fixture.gate.isPaused)
        fixture.recovery.stop()
    }

    @MainActor
    private final class Harness {
        let sensing = FakeSensing()
        let gate = InputCommandGate()
        var targets = [FakeGeometry.adoptedWindow]
        var preparedDestinations: [WindowReference] = []
        var frontOverride: Bool?
        var identityUnavailable = false
        var requested: [WindowReference] = []
        var restoreFailure: InputFailure?
        /// What the request answers. Non-zero is the refusal, which is the one
        /// way into the waiting state that neither a miss nor a throw reaches.
        var restoreCode: Int32 = 0
        var request = UserFocusRequestTiming()
        var reports: [UserFocusRecoveryReport] = []
        var time: UInt64 = 1_000_000_000
        /// False for a brief activation, the one request made with the gate open:
        /// the seat is `acting` for it, so no Command is admitted anyway.
        var requiresPausedGate = true
        /// What a request does to the front, which a real request changes.
        var onRestore: ((WindowReference) -> Void)?
        lazy var recovery = UserFocusRecovery(sensing: sensing, gate: gate,
            adopted: { [unowned self] in targets },
            restore: { [unowned self] window in
                if requiresPausedGate {
                    #expect(gate.isPaused, "The restoration call must never precede the input stop")
                }
                requested.append(window)
                onRestore?(window)
                if let restoreFailure { throw restoreFailure }
                return restoreCode
            }, now: { [unowned self] in time },
            requestTiming: { [unowned self] in request },
            prepareDestination: { [unowned self] destination, targets in
                if identityUnavailable { throw InputFailure.inputPaused([.destinationNotPrepared]) }
                #expect(targets == self.targets)
                preparedDestinations.append(destination)
            },
            isFrontmost: { [unowned self] in frontOverride ?? (sensing.frontmostProcessID == $0) },
            changed: { [unowned self] in reports.append($0) })

        init() {
            sensing.additionalWindows = [userWindow.windowNumber: userWindow, otherWindow.windowNumber: otherWindow]
            sensing.focusedUserWindow = userWindow
            sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
                virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
                windows: [userWindow, otherWindow, FakeGeometry.adoptedWindow])
        }
        private var userWindow: WindowReference { UserFocusRecoveryTests.user }
        private var otherWindow: WindowReference { UserFocusRecoveryTests.other }

        func activateTarget() {
            sensing.frontmostProcessID = FakeGeometry.targetPID
            sensing.focusedUserWindow = FakeGeometry.adoptedWindow
            recovery.activationChanged(to: FakeGeometry.targetPID)
        }
        func returnUser() {
            sensing.frontmostProcessID = userWindow.processID
            sensing.focusedUserWindow = userWindow
            recovery.verify()
            recovery.verify()
        }
        /// The front as a request that took effect leaves it, before its
        /// workspace notification arrives.
        func bringInFront(_ window: WindowReference) {
            sensing.frontmostProcessID = window.processID
            sensing.focusedUserWindow = window
        }
    }
}
