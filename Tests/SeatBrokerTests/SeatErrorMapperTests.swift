import ApplicationServices
import CoreGraphics
import CursorGuard
import SeatCore
import SeatInput
import SeatSession
import Testing
import VirtualScreens
@testable import SeatBroker

@Test func preparationFailureNamesCauseProgressCleanupAndRecovery() {
    let failure = InputPreparationFailure(
        progress: InputProgress(
            completedSteps              : [.activation, .keyWindowFirst],
            failedStep                  : .keyWindowSecond,
            failedStepMayHaveTakenEffect: true,
            cleanup                     : .failed(code: -50)
        ),
        cause       : InputFailure.preparationFailed(step: .keyWindowSecond, code: -49),
        cleanupCause: InputFailure.restoreFailed(code: -50)
    )

    let message = SeatErrorMapper.message(for: failure)
    #expect(message.contains("failed at keyWindowSecond with code -49"))
    #expect(message.contains("completed steps activation, keyWindowFirst"))
    #expect(message.contains("failed step keyWindowSecond"))
    #expect(message.contains("failed step may have taken effect: yes"))
    #expect(message.contains("cleanup failed (code -50)"))
    #expect(message.contains("recovery needed: restorePreparation"))
    #expect(message.contains("Cleanup failure:"))
    #expect(message.contains("preparation state could not be restored (code -50)"))
    #expect(!message.contains("events are already out"))
}

@Test func nestedPreparationFailureIsBounded() {
    let progress = InputProgress(
        completedSteps              : [],
        failedStep                  : nil,
        failedStepMayHaveTakenEffect: false,
        cleanup                     : .notAttempted
    )
    let nested = InputPreparationFailure(
        progress    : progress,
        cause       : InputFailure.inputPaused([.windowTransfer]),
        cleanupCause: nil
    )
    let outer = InputPreparationFailure(
        progress    : progress,
        cause       : nested,
        cleanupCause: nested
    )

    let message = SeatErrorMapper.message(for: outer)
    #expect(message.contains("Another input preparation failed: inputPaused"))
    #expect(message.contains("Cleanup failure: Another input preparation failed: inputPaused"))
    #expect(message.count < 1_000)
}

@Test func pauseReasonsAreFoundThroughThePreparationWrapper() {
    let progress = InputProgress(
        completedSteps              : [.activation],
        failedStep                  : nil,
        failedStepMayHaveTakenEffect: false,
        cleanup                     : .succeeded
    )
    let wrapped = InputPreparationFailure(
        progress    : progress,
        cause       : InputFailure.inputPaused([.focusRecovery]),
        cleanupCause: nil
    )

    // The driver only ever sees the wrapper, so reading the reason through it
    // is what separates a stop that ends by itself from one that does not.
    #expect(SeatErrorMapper.pauseReasons(of: wrapped) == [.focusRecovery])
    #expect(SeatErrorMapper.pauseReasons(of: InputFailure.inputPaused([.windowTransfer]))
        == [.windowTransfer])
    #expect(SeatErrorMapper.pauseReasons(of: InputFailure.eventCreationFailed).isEmpty)
    #expect(SeatErrorMapper.pauseReasons(of: SeatBrokerError.sessionClosed).isEmpty)
}

@Test func invalidClickCountNamesTheDriverBound() {
    let message = SeatErrorMapper.message(
        for: InputFailure.invalidClickCount(requested: 33, maximum: 32))
    #expect(message.contains("click count 33"))
    #expect(message.contains("between 1 and 32"))
}

@Test func onlyTheStopsThatLeftTheWorldIntactAreCarriedOn() {
    // The gate refuses before the hop to the main actor, the recovery's own
    // preparation after it, and the seat refuses when an issue took it out of
    // the acting state. Three readings of "nothing went out, look again".
    #expect(SeatErrorMapper.mayDecideAgain([.focusRecovery]))
    #expect(SeatErrorMapper.mayDecideAgain([.activationUnverified]))
    #expect(SeatErrorMapper.mayDecideAgain([.seatNotActing]))
    #expect(SeatErrorMapper.mayDecideAgain([.focusRecovery, .activationUnverified]))

    // Everything else is structural, and so is a mixture that contains one.
    #expect(!SeatErrorMapper.mayDecideAgain([]))
    #expect(!SeatErrorMapper.mayDecideAgain([.windowTransfer]))
    #expect(!SeatErrorMapper.mayDecideAgain([.focusRecoveryStopped]))
    #expect(!SeatErrorMapper.mayDecideAgain([.holdEnded]))
    #expect(!SeatErrorMapper.mayDecideAgain([.fenceInactive]))
    #expect(!SeatErrorMapper.mayDecideAgain([.recoveryReplaced]))
    #expect(!SeatErrorMapper.mayDecideAgain([.turnChanged]))
    #expect(!SeatErrorMapper.mayDecideAgain([.focusRecovery, .focusRecoveryStopped]))
}

@Test func theAdoptionSentenceNamesWhatWasAskedForNextToWhatArrived() {
    // The MarkEdit failure the owner hit: a stage that was never confirmed,
    // which the seat keeps no adoption report for.
    let detail = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 1291, height: 949),
        bounds       : CGRect(x: 2000, y: 1000, width: 1920, height: 1080),
        observed     : CGRect(x: 2347, y: 1478, width: 888, height: 448),
        restoration  : .returned
    )
    #expect(detail.contains("asked for 1291×949 pt"))
    #expect(detail.contains("background display [2000,1000 1920×1080]"))
    #expect(detail.contains("was put back where it was"))
    // The observed frame is already in the failure's own sentence that this
    // one is appended to, so the verdict reads it and nothing repeats it.
    #expect(!detail.contains("last saw"))
    // A delta this far past the tolerance has two possible causes that need
    // opposite fixes, and the sentence names the tolerance instead of picking.
    #expect(detail.contains("arrived 888×448 pt where 1291×949 pt was asked for"))
    #expect(detail.contains("past the 4 pt allowed between"))
    #expect(detail.contains("these numbers do not say which"))
    #expect(detail.contains("had not settled when it was adopted"))
    #expect(!detail.contains("holding it at that size"))
    // The clause this replaced concluded which of the two it was, from numbers
    // that cannot separate them.
    #expect(!detail.contains("so its geometry had not settled"))
}

@Test func theMarkEditOffsetIsNoLongerReadAsAWindowThatHadNotSettled() {
    // The owner's run: 885×448 pt asked for, 888×448 listed by the window
    // server, bit-identical on two launches. 3 pt is inside the kit's 4 pt
    // cross-source tolerance, so it is one window read twice and not two sizes.
    let detail = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 885, height: 448),
        bounds       : CGRect(x: 2000, y: 1000, width: 1920, height: 1080),
        observed     : CGRect(x: 2347, y: 1478, width: 888, height: 448),
        restoration  : .returned
    )
    #expect(detail.contains("arrived at the 885×448 pt that was asked for"))
    #expect(detail.contains("holding it at that size"))
    #expect(!detail.contains("had not settled"))
}

@Test func theHandbackRefusalsNameWhatHoldsTheApplicationAndWhatToDoAboutIt() {
    let inUse = SeatErrorMapper.message(for: SessionFailure.assignmentStillInUse(.turnHeld))
    #expect(inUse.contains("cannot be given back while the seat is still held for an action"))
    #expect(inUse.contains("try again in a moment"))

    // Every use has prose of its own, and none of them says the case name to
    // somebody whose agent has just refused to move on.
    for use in [AssignmentUse.seatTearingDown, .commandInFlight, .turnHeld, .adoptionInFlight,
                .windowTransferInFlight, .focusRecoveryRestoring] {
        let message = SeatErrorMapper.message(for: SessionFailure.assignmentStillInUse(use))
        #expect(message.contains("the next one cannot be adopted yet"))
        #expect(!message.contains(use.rawValue))
    }

    let stillHeld = SeatErrorMapper.message(
        for: SessionFailure.assignedWindowsStillHeld(windowNumbers: [36778]))
    #expect(stillHeld.contains("still holds window 36778 of this application"))
    #expect(stillHeld.contains("lets the next application be adopted"))

    let outstanding = SeatErrorMapper.message(
        for: SessionFailure.returnsStillOutstanding(windowNumbers: [36778, 36386]))
    #expect(outstanding.contains("return of windows 36778, 36386 from an earlier application"))
    #expect(outstanding.contains("nothing else can be adopted"))

    let unassigned = SeatErrorMapper.message(for: SessionFailure.applicationNotAssigned)
    #expect(unassigned.contains("asked to give its application back and has none assigned"))

    // The kit renders a case with a payload as a bare number that names
    // nothing, which is what every sentence here exists to replace.
    for message in [inUse, stillHeld, outstanding, unassigned] {
        #expect(!message.contains("SeatSession."))
    }
}

@Test func theSameSizeOnTheDisplayPointsAtTheOtherCauseAndNoFrameAtNeither() {
    let held = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 1291, height: 949),
        bounds       : CGRect(x: 0, y: 0, width: 1920, height: 1080),
        // Half a point between the window's own size and the server's
        // listing is rounding, not a different size.
        observed     : CGRect(x: 10, y: 20, width: 1291.5, height: 948.6),
        restoration  : .refused
    )
    #expect(held.contains("arrived at the 1291×949 pt that was asked for"))
    #expect(held.contains("holding it at that size"))
    #expect(held.contains("could not be put back"))
    #expect(!held.contains("had not settled"))

    let blind = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 800, height: 600),
        bounds       : CGRect(x: 0, y: 0, width: 1920, height: 1080),
        observed     : nil,
        restoration  : .returned
    )
    #expect(blind.contains("asked for 800×600 pt"))
    #expect(blind.contains("was put back where it was"))
    #expect(blind.contains("nothing here says which of the two it was"))
}

@Test func aFailureBeforeAnyMoveDoesNotSayTheWindowWasNeverGivenBack() {
    // The run where `seat.adopt` refused a failed seat with `seatNotReady`:
    // nothing was moved, so nothing was owed back.
    let refused = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 1200, height: 828),
        bounds       : CGRect(x: 2000, y: 1000, width: 1920, height: 1080),
        observed     : nil,
        restoration  : nil
    )
    #expect(refused.contains("asked for 1200×828 pt"))
    #expect(refused.contains("background display [2000,1000 1920×1080]"))
    #expect(refused.contains("stopped before it moved any window, so there was nothing to give back"))
    #expect(!refused.contains("never given back"))
    #expect(!refused.contains("which of the two"))

    // A frame that came back is a move that happened, and there the old
    // wording still holds.
    let moved = SeatErrorMapper.detail(
        requestedSize: CGSize(width: 1200, height: 828),
        bounds       : CGRect(x: 2000, y: 1000, width: 1920, height: 1080),
        observed     : CGRect(x: 2360, y: 1126, width: 1200, height: 828),
        restoration  : nil
    )
    #expect(moved.contains("was never given back"))
}

@Test func theFrameTheWindowServerLastSawIsReadOutOfTheUnconfirmedMoves() {
    let stage = DisplayFailure.stageNotConfirmed(
        windowNumber: 36386,
        lastFrame   : CGRect(x: 2347, y: 1478, width: 888, height: 448)
    )
    #expect(SeatErrorMapper.lastObservedFrame(of: stage)
        == CGRect(x: 2347, y: 1478, width: 888, height: 448))
    #expect(SeatErrorMapper.lastObservedFrame(
        of: DisplayFailure.placementNotConfirmed(windowNumber: 7, lastFrame: nil)) == nil)
    // Every other failure carries no frame, and inventing one reads worse
    // than the sentence that says nothing came back.
    #expect(SeatErrorMapper.lastObservedFrame(of: DisplayFailure.displayCreationFailed) == nil)
    #expect(SeatErrorMapper.lastObservedFrame(of: SeatBrokerError.sessionClosed) == nil)
}

// MARK: Why the seat will not act

private func surface(_ number: Int, pid: Int32 = 42) -> WindowIdentity {
    WindowIdentity(
        process: ProcessIdentity(processID: pid, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber: number,
        ownerConnectionID: 3
    )
}

/// Every case of `SeatSuspensionCause`, written out because the enum carries
/// payloads and cannot be `CaseIterable`. A case added upstream fails the
/// exhaustive switch in the mapper, which is where this list is kept honest.
private let everySuspensionCause: [SeatSuspensionCause] = [
    .notAssigned,
    .noEligibleTarget,
    .explicitSelectionRequired(candidates: [surface(1), surface(2)]),
    .modalBlock(modal: surface(45_152), blocked: surface(45_100)),
    .modalRelationInDoubt(detail: "two readings disagreed"),
    .visibilityUncertain(surface(1)),
    .selectedSurfaceAbsent(surface(1)),
    .selectedSurfaceNotVerified(surface(1)),
    .containmentNotVerified(blocks: ["one window is off the display"]),
    .observationMissing,
    .observationSuperseded(observed: 3, current: 4),
    .observationIdentityMismatch(observed: surface(1), selected: surface(2)),
    .observationGeometryStale(surface(1)),
    .monitorSharedFault,
]

@Test func everySuspensionCauseHasASentenceOfItsOwn() {
    let sentences = everySuspensionCause.map(SeatErrorMapper.sentence)
    #expect(sentences.count == Set(sentences).count)
    for sentence in sentences {
        #expect(!sentence.isEmpty)
        // What `String(describing:)` used to leak into the person's line: the
        // case name and the payload struct, in place of the situation.
        #expect(!sentence.contains("WindowIdentity"))
        #expect(!sentence.contains("processID"))
    }
}

@Test func aModalBlockSaysADialogIsInFrontOfTheWindow() {
    let sentence = SeatErrorMapper.sentence(
        .modalBlock(modal: surface(45_152), blocked: surface(45_100)))
    #expect(sentence.contains("a dialog is in front of the window"))
    #expect(sentence.contains("window 45152"))
    #expect(sentence.contains("window 45100"))
}

@Test func aSuspendedObservationRendersItsCausesAsSentences() {
    let message = SeatErrorMapper.message(for: ObservationUnavailable.suspended(
        [.observationMissing, .modalBlock(modal: surface(9), blocked: surface(8))]))
    #expect(message.contains("The seat cannot observe while suspended"))
    #expect(message.contains("a dialog is in front of the window"))
    #expect(!message.contains("modalBlock"))
}

@Test func anUnresolvedHostNamesBothWindowsAndNotTheRawCase() {
    let message = SeatErrorMapper.message(for: ObservationUnavailable.hostedSurfaceUnresolved(
        surface: surface(45_152), namedHost: surface(45_100)))
    #expect(message.contains("Window 45152"))
    #expect(message.contains("window 45100"))
    #expect(message.contains("no picture of its own"))
    #expect(!message.contains("hostedSurfaceUnresolved"))
}

// MARK: The event channel

@Test func theSixEventsARecordMayNameAreSurfacedAndTheRestAreLoggedOnly() {
    let window = WindowReference(processID: 42, windowNumber: 45_170, frame: .zero)
    let surfaced: [SeatEvent] = [
        .targetChanged(from: 45_100, to: window, reason: .adopted),
        .windowAdoptedNotTargeted(window: window, target: 45_100),
        .issueDetected(.targetActivated, cause: nil),
        .windowReleased(windowNumber: 45_100, outcome: .refused),
        .teardownFinished(TeardownReport(displayRemoved: true, fenceReleased: true,
                                         mainDisplayRestored: true, topologyRestoration: nil,
                                         windows: [:], removalNanoseconds: 0)),
    ]
    let loggedOnly: [SeatEvent] = [
        .hostStateChanged(from: .off, to: .ready, reason: .requested),
        .seatStateChanged(from: .ready, to: .acting, reason: .requested),
        .fenceSignals(.quiet),
        .recoveryProgressed(episode: 1, step: .observe),
        .targetChangeRefused(windowNumber: 45_100, state: .ready, issues: [.targetActivated]),
        .windowTransferRefused(windowNumber: 45_100, processID: 42, reason: .tooLarge),
    ]
    for event in surfaced { #expect(SeatErrorMapper.note(for: event) != nil) }
    // Logged, never silent: a line exists for every event on the channel.
    for event in loggedOnly {
        #expect(SeatErrorMapper.note(for: event) == nil)
        #expect(!SeatErrorMapper.line(for: event).isEmpty)
    }
}

@Test func aScreenConnectedWhileTheSeatRanSaysSoAndWhenItComesBack() {
    let line = SeatErrorMapper.line(
        for: .issueDetected(.displayChanged, cause: .watchdog(.physicalDisplayAdded)))
    #expect(line.contains("a screen was connected while the seat was running"))
    #expect(line.contains("including the new screen, the next time an application is opened"))
    #expect(!line.contains("no longer trustworthy"))

    // Every other cause of the same Issue keeps the generic sentence.
    let moved = SeatErrorMapper.line(
        for: .issueDetected(.displayChanged, cause: .watchdog(.physicalGeometryChanged)))
    #expect(moved.contains("no longer trustworthy"))
    #expect(!moved.contains("a screen was connected"))
}

@Test func anExtraWindowTheSeatTookNamesItAndTheWindowTheLabStaysIn() {
    let window = WindowReference(processID: 42, windowNumber: 45_170,
                                 frame: CGRect(x: 0, y: 0, width: 933, height: 490))
    let line = SeatErrorMapper.line(
        for: .windowAdoptedNotTargeted(window: window, target: 45_100))
    #expect(line.contains("45170"))
    #expect(line.contains("933×490"))
    #expect(line.contains("45100"))
}

@Test func aTeardownOnlySpeaksWhenAWindowDidNotGoHome() {
    let quiet = TeardownReport(displayRemoved: true, fenceReleased: true, mainDisplayRestored: true,
                               topologyRestoration: nil,
                               windows: [45_100: .returned, 45_170: .vanished],
                               removalNanoseconds: 1)
    #expect(SeatErrorMapper.teardown(quiet) == nil)

    let stranded = TeardownReport(displayRemoved: true, fenceReleased: true, mainDisplayRestored: true,
                                  topologyRestoration: nil,
                                  windows: [45_100: .refused, 45_170: .returned],
                                  removalNanoseconds: 1)
    let sentence = SeatErrorMapper.teardown(stranded)
    #expect(sentence?.contains("window 45100 did not go back to your display") == true)
    #expect(sentence?.contains("45170") == false)
}

@Test func anObligationSaysWhichWindowAndHowToFinishItByHand() {
    #expect(SeatErrorMapper.obligations([]) == nil)

    let identity = WindowIdentity(
        process         : ProcessIdentity(processID: 4_242, serialNumberHigh: 1, serialNumberLow: 7),
        windowNumber    : 45_100,
        ownerConnectionID: 5_242
    )
    let refused = AssignmentObligation(
        identity : identity,
        owedFrame: CGRect(x: 100, y: 120, width: 800, height: 600),
        reason   : .returnRefused
    )
    let sentence = SeatErrorMapper.obligations([refused])
    #expect(sentence?.contains("window 45100") == true)
    #expect(sentence?.contains("100,120 800×600") == true)
    #expect(sentence?.contains("move it back yourself") == true)

    // A surface with no place of its own says so instead of naming a frame.
    let born = AssignmentObligation(identity: identity, owedFrame: nil,
                                    reason: .noDestinationInUserSeat)
    #expect(SeatErrorMapper.obligations([born])?.contains("choose a display for it") == true)
}

@Test func aFullScreenWindowTheSeatCannotTakeSaysWhyAndWhatToTellThePerson() {
    // The person is looking at the Space: taking it would animate their display.
    let watched = SeatErrorMapper.message(for: DisplayFailure.fullScreenSpaceStillOnScreen(windowNumber: 812))
    #expect(watched.contains("Window 812 is in native fullscreen on the Space the person is looking at"))
    #expect(watched.contains("taking it would animate their display, so it was left where it is"))
    #expect(watched.contains("Tell the person to go to their desktop or to another Space, then open it again."))
    #expect(!watched.contains("deferred"))

    let readOnly = SeatErrorMapper.message(for: DisplayFailure.fullScreenNotSettable(windowNumber: 812))
    #expect(readOnly.contains("Window 812 is in native fullscreen and does not let the seat take it out"))
    #expect(readOnly.contains("so it was left where it is"))
    #expect(readOnly.contains("Tell the person to take that window out of fullscreen, then open it again."))

    let unreadable = SeatErrorMapper.message(for: DisplayFailure.fullScreenStateUnreadable(
        windowNumber: 812,
        code        : .attributeUnsupported
    ))
    #expect(unreadable.contains("Window 812 did not answer whether it is in native fullscreen (code -25205)"))
    #expect(unreadable.contains("so the seat could not take it out and left it where it is"))
    #expect(unreadable.contains("Tell the person to take that window out of fullscreen, then open it again."))
}
