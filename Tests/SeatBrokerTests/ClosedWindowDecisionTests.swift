//
//  ClosedWindowDecisionTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import Testing
@testable import SeatBroker

/// `BrowserOpening.isClosed` says a pressed window is gone from four readings: an application may
/// keep a closed window in the window server off screen, and accessibility says it is gone.
@Suite("When a pressed window counts as closed")
struct ClosedWindowDecisionTests {

    @Test("a window the window server no longer lists is closed")
    func notListedIsClosed() {
        #expect(BrowserOpening.isClosed(listed: false, onScreen: false, elementIsValid: true, inWindows: true))
    }

    @Test("a listed window off screen is closed when its element is invalid")
    func offScreenWithInvalidElementIsClosed() {
        #expect(BrowserOpening.isClosed(listed: true, onScreen: false, elementIsValid: false, inWindows: true))
    }

    @Test("a listed window off screen is closed when AXWindows no longer has it")
    func offScreenAbsentFromWindowsIsClosed() {
        #expect(BrowserOpening.isClosed(listed: true, onScreen: false, elementIsValid: true, inWindows: false))
    }

    @Test("a minimized window is off screen but still in AXWindows, so it is open")
    func minimizedIsNotClosed() {
        #expect(!BrowserOpening.isClosed(listed: true, onScreen: false, elementIsValid: true, inWindows: true))
    }

    @Test("a window on screen is never closed, whatever accessibility says")
    func onScreenIsNotClosed() {
        for valid in [true, false] {
            for inWindows in [true, false] {
                #expect(!BrowserOpening.isClosed(listed: true, onScreen: true, elementIsValid: valid, inWindows: inWindows))
            }
        }
    }
}
