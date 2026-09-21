//
//  FocusRecoveryWaitTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import SeatSession
import SeatCore
import WindowPlacement
import Testing
@testable import SeatBroker

@Test @MainActor func aRecoveryStillInFlightIsWaitedOnAndNeverRead() {
    // `waitingForUser` is published when the kit's 250 ms verification window
    // passes, and the focus measurably arrives after it.
    #expect(SeatDriver.admission(of: .waitingForUser) == nil)
    #expect(SeatDriver.admission(of: .restoring) == nil)
}

@Test @MainActor func onlyStructuredWindowEvidenceCanProveTheOldSurfaceIsGone() {
    let expected = WindowIdentity(
        process: ProcessIdentity(processID: 100, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber: 200,
        ownerConnectionID: 300
    )
    let replacement = WindowIdentity(
        process: ProcessIdentity(processID: 101, serialNumberHigh: 1, serialNumberLow: 3),
        windowNumber: 200,
        ownerConnectionID: 301
    )
    #expect(SeatDriver.surfacePresence(expected, reading: .present(expected)) == .present)
    #expect(SeatDriver.surfacePresence(expected, reading: .present(replacement)) == .replaced)
    #expect(SeatDriver.surfacePresence(expected, reading: .absent) == .destroyed)
    #expect(SeatDriver.surfacePresence(expected, reading: .unreadable) == .unreadable)
    #expect(SeatDriver.surfacePresence(
        expected, logical: .withdrawn, reading: .present(expected)
    ) == .withdrawn,
    "an AppKit proxy may persist in WindowServer after AX withdrew the logical panel")
    #expect(SeatDriver.surfacePresence(
        expected, logical: .unreadable, reading: .present(expected)
    ) == .present,
    "an unreadable scoped read cannot turn a stale closure proof into success")
}

@Test @MainActor func onlyAFocusThatIsBackAdmitsInputAgain() {
    #expect(SeatDriver.admission(of: .restored) == true)
    #expect(SeatDriver.admission(of: .userTookControl) == true)
}

@Test @MainActor func aTerminalRecoveryIsNotWaitedOut() {
    // Nothing is coming, so waiting burns the caller's budget for a final
    // report. `unrecoverable` is a closure transition that spent its own.
    #expect(SeatDriver.admission(of: .cancelled) == false)
    #expect(SeatDriver.admission(of: .unrecoverable) == false)
}

@Test @MainActor func noSeatNeverPretendsThatInputIsAdmitted() async {
    #expect(SeatDriver.admission(of: nil) == false)

    // And the wait itself answers that without spending the limit: a seat that
    // never recovered anything has nothing to wait for.
    let started = ContinuousClock.now
    let waited = await SeatDriver().waitWhileRecoveringFocus(within: .seconds(5))
    #expect(!waited.admitted)
    // The wait says what it read, so the sentence a run records and the state
    // the person is shown come from the same reading.
    #expect(waited.cause == .noSeat)
    #expect(waited.detail == nil)
    #expect(started.duration(to: .now) < .seconds(1))
}
