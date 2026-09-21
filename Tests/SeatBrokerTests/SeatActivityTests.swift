//
//  SeatActivityTests.swift
//  AgentLab
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import SeatInput
import SeatSession
import Testing
@testable import SeatBroker

@Test func theBadgeIsTheKitsOwnStateAndNotAPermissionsReport() {
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: []) == .ready)
    #expect(SeatActivity.reading(state: .degraded, recovery: nil, pauses: []) == .ready)
    #expect(SeatActivity.reading(state: nil, recovery: nil, pauses: []) == .noSeat)
    #expect(SeatActivity.reading(state: .unavailable, recovery: nil, pauses: []) == .noSeat)
    #expect(SeatActivity.reading(state: .failed, recovery: nil, pauses: []) == .failed)
}

@Test func aSeatWaitingForThePersonNeverReadsReady() {
    // The reported case: the seat was waiting and the menu said "Seat ready"
    // for the whole of it.
    #expect(SeatActivity.reading(state: .waiting, recovery: nil, pauses: []) == .waitingForUser)
    #expect(SeatActivity.reading(state: .ready, recovery: .waitingForUser, pauses: [.focusRecovery])
            == .waitingForUser)
    // The kit spent the closure transition's whole budget: still the person's.
    #expect(SeatActivity.reading(state: .ready, recovery: .unrecoverable, pauses: []) == .waitingForUser)
}

@Test func aRecoveryInFlightReadsAsRecovering() {
    #expect(SeatActivity.reading(state: .recovering, recovery: nil, pauses: []) == .recovering)
    #expect(SeatActivity.reading(state: .ready, recovery: .restoring, pauses: [.focusRecovery]) == .recovering)
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: [.activationUnverified]) == .recovering)
}

@Test func theBadgeFollowsTheGateAndNotTheSeatStateAlone() {
    // Panic closes the gate and leaves the seat `ready`, which is exactly the
    // reading a badge built from the state alone gets wrong.
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: [.deliberateStop]) == .suspended)
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: [.focusRecoveryStopped]) == .suspended)
    // A stop outranks a recovery still publishing: nothing reopens the gate.
    #expect(SeatActivity.reading(state: .ready, recovery: .restoring, pauses: [.deliberateStop]) == .suspended)
    // Any other cause holding the gate is a held seat, not a ready one.
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: [.windowTransfer]) == .suspended)
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: [.fenceInactive]) == .suspended)
}

@Test func onlyAReadySeatSaysInputIsGoingOut() {
    #expect(!SeatActivity.ready.holdsInput)
    for activity in [SeatActivity.noSeat, .recovering, .waitingForUser, .suspended, .failed] {
        #expect(activity.holdsInput)
        #expect(!activity.title.isEmpty)
        #expect(!activity.symbol.isEmpty)
    }
}

@Test func everyCauseTheGateCanNameHasASentence() {
    for reason in InputPauseReason.allCases {
        #expect(!SeatErrorMapper.sentence(reason).isEmpty)
    }
    #expect(SeatErrorMapper.heldInput([]) == nil)
    #expect(SeatErrorMapper.heldInput([.deliberateStop])?.contains("you stopped the seat") == true)
}

// MARK: The preview is not the application

@Test @MainActor func aPreviewThatFailedIsNeverDescribedAsALostApplication() {
    #expect(SeatDriver.suspensionSentence(.idle) == nil)
    #expect(SeatDriver.suspensionSentence(.live) == nil)
    for availability in [PreviewAvailability.suspended("the stream stopped"),
                         .unavailable("the stream stopped")] {
        let sentence = SeatDriver.suspensionSentence(availability)
        #expect(sentence?.contains("The seat is still holding the window.") == true)
        #expect(sentence?.contains("preview") == true)
    }
    // And it is not part of the seat's own state: a lost picture moves no
    // badge, because the seat is holding the window through all of it.
    #expect(SeatActivity.reading(state: .ready, recovery: nil, pauses: []) == .ready)
}
