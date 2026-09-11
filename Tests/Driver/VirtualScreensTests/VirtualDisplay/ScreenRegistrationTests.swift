//
//  ScreenRegistrationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Testing
@testable import VirtualScreens

/// The AppKit half of a display's life, against the screens this machine
/// actually has. These read `NSScreen` on purpose: the predicates exist to
/// answer questions about it, and a fake screen list would only test the fake.
@MainActor
@Suite("Screen registration on this machine")
struct ScreenRegistrationTests {

    /// An id no screen carries, derived from the ones that exist so it stays
    /// absent however many displays are attached.
    private var absentID: CGDirectDisplayID {
        let known = Set(NSScreen.screens.compactMap { ScreenRegistration.displayID(of: $0) })
        var candidate: CGDirectDisplayID = 1
        while known.contains(candidate) { candidate += 1 }
        return candidate
    }

    @Test func displayIDRoundTrips() throws {
        for screen in NSScreen.screens {
            let id = try #require(ScreenRegistration.displayID(of: screen))
            #expect(ScreenRegistration.screen(for: id) == screen)
        }
    }

    @Test func absentDisplayID() {
        let known = Set(NSScreen.screens.compactMap { ScreenRegistration.displayID(of: $0) })
        #expect(!known.contains(absentID))
    }

    @Test func noScreenForAbsentDisplay() {
        #expect(ScreenRegistration.screen(for: absentID) == nil)
    }

    @Test func screenContainingItsOwnCentre() throws {
        for screen in NSScreen.screens {
            #expect(ScreenRegistration.screen(containing: screen.frame) == screen)
        }
    }

    /// A rectangle on no screen falls back to the main one, because the
    /// question "which display is this window on" always has to answer with a
    /// display a person can look at.
    @Test func screenContainingNothing() {
        let faraway = CGRect(x: -900_000, y: -900_000, width: 10, height: 10)
        #expect(ScreenRegistration.screen(containing: faraway) == NSScreen.main)
    }

    @Test func titleBarReachesAPhysicalDisplay() throws {
        let main = try #require(NSScreen.main)
        let titleBar = CGRect(x: main.frame.midX - 200, y: main.frame.midY, width: 400, height: 24)
        #expect(try ScreenRegistration.frameReachesPhysicalDisplay(titleBar, excluding: nil))
    }

    @Test func offScreenReachesNothing() throws {
        let titleBar = CGRect(x: -900_000, y: -900_000, width: 400, height: 24)
        #expect(try !ScreenRegistration.frameReachesPhysicalDisplay(titleBar, excluding: nil))
    }

    /// Excluding the very display a frame sits on leaves nothing to reach: it
    /// is how a caller asks "is this window anywhere but the virtual display".
    @Test func excludingItsOwnDisplay() throws {
        let main = try #require(NSScreen.main)
        let id = try #require(ScreenRegistration.displayID(of: main))
        let titleBar = CGRect(x: main.frame.midX - 200, y: main.frame.midY, width: 400, height: 24)
        #expect(try ScreenRegistration.frameReachesPhysicalDisplay(titleBar, excluding: nil))
        #expect(try !ScreenRegistration.frameReachesPhysicalDisplay(titleBar, excluding: id))
    }

    /// The wait returns `nil` for a display AppKit will never publish. It is
    /// also the shape of the trap on the type: without an application event
    /// loop it returns `nil` however long the timeout, which is why the
    /// predicate exists separately.
    @Test func waitForAbsentScreen() async {
        let screen = await ScreenRegistration.waitForScreen(displayID: absentID, timeout: 0.1)
        #expect(screen == nil)
    }
}

/// These pin down the difference between the two questions a caller can ask
/// about a window and a display, because answering one with the other is a
/// defect no test caught until a person ran the app: the reach predicate
/// answered `false` for every window, so nothing could be adopted.
struct ScreenRegistrationPointTests {

    private let builtIn = PhysicalDisplay(displayID: 1,   bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let virtual = PhysicalDisplay(displayID: 674, bounds: CGRect(x: 1512, y: 982, width: 2560, height: 1440))

    @Test func aPointOnTheBuiltInDisplayIsFound() {
        let centre = CGPoint(x: 863, y: 508)
        #expect(ScreenRegistration.display(containing: centre, among: [builtIn, virtual]) == 1)
    }

    @Test func theExcludedDisplayIsNeverTheAnswer() {
        let centre = CGPoint(x: 2792, y: 1701)
        #expect(ScreenRegistration.display(containing: centre, among: [builtIn, virtual]) == 674)
        #expect(ScreenRegistration.display(containing: centre, among: [builtIn, virtual], excluding: 674) == nil)
    }

    /// A Stage Manager thumbnail parked left of the screen: this is what a
    /// stashed window looks like, and it really is on no display.
    @Test func aPointOnNoDisplayIsNil() {
        let centre = CGPoint(x: -172, y: 835)
        #expect(ScreenRegistration.display(containing: centre, among: [builtIn, virtual]) == nil)
    }

    /// The trap itself, written down: a one point rectangle can never meet a
    /// minimum overlap of 40 by 12, so the reach predicate is the wrong tool
    /// for a centre point no matter where that point is.
    @Test func aPointSizedRectangleNeverReachesADisplay() {
        let onScreen = CGRect(origin: CGPoint(x: 863, y: 508), size: CGSize(width: 1, height: 1))
        let intersection = onScreen.intersection(builtIn.bounds)
        #expect(intersection.width == 1 && intersection.height == 1)
        #expect(!(intersection.width >= 40 && intersection.height >= 12))
    }
}
