//
//  WindowServerProbeTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import AppKit
import CoreGraphics
import Testing
import VirtualScreens
@testable import WindowPlacement

/// What the window server witness answers about windows that are not there.
/// Those are the readings that matter for correctness: a probe that invented a
/// frame for a dead Window ID would let a placement check confirm a window the
/// seat no longer has.
@Suite("The window server witness")
struct WindowServerProbeTests {

    @Test("Window ID zero is not a window")
    func zeroIsNotAWindow() {
        #expect(WindowServerProbe.geometry(of: 0) == nil)
        #expect(WindowServerProbe.orderIndex(of: 0) == nil)
    }

    @Test("a negative or oversized Window ID answers nothing, it does not trap")
    func outOfRangeWindowNumbers() {
        // `CGWindowID` is a `UInt32`: both of these fail `exactly:` rather than
        // wrapping into somebody else's window.
        #expect(WindowServerProbe.geometry(of: -1) == nil)
        #expect(WindowServerProbe.geometry(of: Int(UInt32.max) + 1) == nil)
    }

    @Test("a Window ID nothing owns answers nothing")
    func absentWindowNumber() {
        // High ids are handed out late; nothing in a fresh test process owns
        // one, and the probe is scoped to the id it was asked about.
        #expect(WindowServerProbe.geometry(of: 0x00FF_FFF0) == nil)
        #expect(WindowServerProbe.isBehindFrontmostWindow(windowNumber: 0x00FF_FFF0, ownedBy: 1) == nil)
    }

    @Test("no window is frontmost on an empty rectangle")
    func nothingIsFrontmostOnNowhere() {
        #expect(WindowServerProbe.frontmostWindow(onDisplayBounds: .zero) == nil)
        #expect(
            WindowServerProbe.frontmostWindow(
                onDisplayBounds: CGRect(x: -1_000_000, y: -1_000_000, width: 100, height: 100)
            ) == nil
        )
    }

    @Test("a process with no window has no front window")
    func processWithoutWindows() {
        // PID 1 is launchd: it is alive and it owns no on-screen window, which
        // is the exact case the identity chain must not resolve.
        #expect(WindowServerProbe.frontWindowNumber(ownedBy: 1) == nil)
    }

    @Test("the main display's own origin converts to itself")
    @MainActor
    func quartzPointOnTheMainScreen() throws {
        let main   = try #require(NSScreen.main)
        let id     = try #require(ScreenRegistration.displayID(of: main))
        let bounds = CGDisplayBounds(id)

        // AppKit's top left corner of the main screen is Quartz's origin of the
        // same display: the y axis flips, the x axis does not.
        let topLeft = CGPoint(x: main.frame.minX, y: main.frame.maxY)
        #expect(
            WindowServerProbe.quartzPoint(fromAppKitPoint: topLeft)
                == CGPoint(x: bounds.minX, y: bounds.minY)
        )
    }

    @Test("a point off every screen still converts, flipped against the first one")
    @MainActor
    func quartzPointOffScreen() throws {
        let first  = try #require(NSScreen.screens.first)
        let nowhere = CGPoint(x: -1_000_000, y: 12)

        #expect(
            WindowServerProbe.quartzPoint(fromAppKitPoint: nowhere)
                == CGPoint(x: -1_000_000, y: first.frame.maxY - 12)
        )
    }
}
