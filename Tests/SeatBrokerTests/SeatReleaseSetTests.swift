//
//  SeatReleaseSetTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import SeatSession
import Testing
@testable import SeatBroker

@Test @MainActor func aWindowIsOnlyOffTheSeatWhenItWentHomeOrIsGone() {
    #expect(SeatDriver.isHome(.returned))
    #expect(SeatDriver.isHome(.vanished))
    #expect(!SeatDriver.isHome(.refused))
    #expect(!SeatDriver.isHome(.leftOnVirtualDisplay))
}

@Test @MainActor func aReleasedSetIsHomeOnlyWhenEveryWindowInItIs() {
    // Nothing released yet is not evidence that anything is out there: the
    // seat's own pending restorations answer that, separately.
    #expect(!SeatDriver.leavesWindowUnrestored([]))
    #expect(!SeatDriver.leavesWindowUnrestored([.returned, .returned, .vanished]))

    // The application this decides about is the one with several windows, so
    // the windows that did make it home must not speak for the one that did
    // not: terminating its owner is what the whole order exists to prevent.
    #expect(SeatDriver.leavesWindowUnrestored([.returned, .refused, .returned]))
    #expect(SeatDriver.leavesWindowUnrestored([.returned, .leftOnVirtualDisplay]))
    #expect(SeatDriver.leavesWindowUnrestored([.refused]))
}
