//
//  SeatAdmissionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import AutomationRuntime
import SeatCore
import SeatSession
import Testing

/// The one decision a worker's act and deliver meet before a Command goes to the seat, read
/// from the state and the focus recovery the kit publishes. It lives in AutomationRuntime and is
/// tested here because this bundle already links it together with the seat's own vocabulary.
@Suite("Seat admission")
struct SeatAdmissionTests {

    /// Every outcome the kit publishes, and none: `Outcome` is not `CaseIterable`.
    let outcomes: [UserFocusRecoveryReport.Outcome?] = [
        nil, .restoring, .restored, .waitingForUser, .userTookControl, .cancelled, .unrecoverable
    ]

    @Test func aReadyOrDegradedSeatIsAdmittedWhateverTheLastRecoverySaid() {
        for state in [SeatState.ready, .degraded] {
            for outcome in outcomes {
                #expect(SeatAdmission.reading(
                    state      : state,
                    recovery   : outcome,
                    application: "Google Chrome"
                ) == .admit)
            }
        }
    }

    @Test func aRecoveringSeatIsWaitedOn() {
        for outcome in outcomes {
            #expect(SeatAdmission.reading(
                state      : .recovering,
                recovery   : outcome,
                application: "Google Chrome"
            ) == .wait)
        }
    }

    @Test func aWaitingSeatIsWaitedOnOnlyWhileItsFocusRecoveryIsStillComing() {
        for outcome in [UserFocusRecoveryReport.Outcome.restoring, .waitingForUser] {
            #expect(SeatAdmission.reading(
                state      : .waiting,
                recovery   : outcome,
                application: "Google Chrome"
            ) == .wait)
        }
        // Nothing running: the answer is the person's, and it is given at once.
        for outcome in [nil, UserFocusRecoveryReport.Outcome.restored, .userTookControl, .cancelled,
                        .unrecoverable] {
            #expect(SeatAdmission.reading(
                state      : .waiting,
                recovery   : outcome,
                application: "Google Chrome"
            ) == SeatAdmission.refuse(SeatAdmission.refusal(for: .waiting, application: "Google Chrome")))
        }
    }

    @Test func aWaitingSeatSaysWhoTookTheFocusAndNeverToCloseTheSession() {
        let sentence = SeatAdmission.refusal(for: .waiting, application: "Google Chrome")
        #expect(sentence.contains("Google Chrome took the focus in the person's own seat"))
        #expect(sentence.contains("waiting for the person to go back to their own window"))
        #expect(sentence.contains("Do not close the session"))
        #expect(sentence.contains("throw Google Chrome away"))
        #expect(sentence.contains("Tell the person, then observe and try again."))
        #expect(!sentence.contains("reopen"))
    }

    @Test func everyOtherStateHasASentenceOfItsOwn() {
        let recovering = SeatAdmission.refusal(for: .recovering, application: "MarkEdit")
        #expect(recovering.contains("putting the window of MarkEdit back where it can act on it"))
        #expect(recovering.hasSuffix("Observe and try again."))

        let failed = SeatAdmission.refusal(for: .failed, application: "MarkEdit")
        #expect(failed.contains("stopped for good"))
        #expect(failed.contains("Close the session and open MarkEdit again."))

        for state in [SeatState.unavailable, .starting, .acting] {
            let sentence = SeatAdmission.refusal(for: state, application: "MarkEdit")
            #expect(SeatAdmission.reading(state: state, recovery: nil, application: "MarkEdit")
                == .refuse(sentence))
            #expect(sentence == "The seat is not ready for input yet. Observe and try again.")
        }
        // None of them repeats the advice that threw an application away.
        for state in SeatState.allCases where !state.acceptsCommands {
            #expect(!SeatAdmission.refusal(for: state, application: "MarkEdit").contains("reopen"))
        }
    }

    @Test func aStoppedSeatSaysWhyAndThatOpenSessionReplacesIt() {
        let screen = SeatAdmission.stopReason(issues: [.displayChanged], causes: [.watchdog(.physicalDisplayAdded)])
        let sentence = SeatAdmission.refusal(for: .failed, application: "DaVinci Resolve", stoppedBecause: screen)
        #expect(sentence.hasPrefix("The seat stopped for good: a screen was connected while the seat was running"))
        #expect(sentence.contains("including the new screen"))
        #expect(sentence.contains("Open DaVinci Resolve again with open_session"))
        #expect(!sentence.contains("Close the session"))
        #expect(SeatAdmission.reading(state: .failed, recovery: nil, application: "DaVinci Resolve",
                                      stoppedBecause: screen) == .refuse(sentence))

        // A window neither taken in nor put back is named, with the same open_session advice.
        let untaken = SeatAdmission.refusal(
            for           : .failed,
            application   : "DaVinci Resolve",
            stoppedBecause: SeatAdmission.untakenWindow(13_252)
        )
        #expect(untaken.hasPrefix("The seat stopped for good: a window the application opened could not be "
            + "handled: window 13252 could not be taken into the seat or put back where it was."))
        #expect(untaken.contains("Open DaVinci Resolve again with open_session"))

        // Without a cause the Issue's own words, one per Issue.
        let generic = SeatAdmission.stopReason(issues: [.displayChanged, .fenceUnavailable], causes: [])
        #expect(generic == "the background display or the physical arrangement is no longer trustworthy; "
            + "the cursor fence is not active")
    }

    @Test func aFailedSeatIsAnsweredAtOnceEvenWithARecoveryInFlight() {
        #expect(SeatAdmission.reading(
            state      : .failed,
            recovery   : .restoring,
            application: "MarkEdit"
        ) == .refuse(SeatAdmission.refusal(for: .failed, application: "MarkEdit")))
    }
}
