//
//  DisplayListTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Testing
@testable import VirtualScreens

/// Whether the machine has a display that is awake right now.
///
/// `CGGetActiveDisplayList` is **empty** on a Mac whose screen has gone to
/// sleep, even though the display is still online, so the handful of tests that
/// read the running machine's own arrangement have nothing to assert about
/// until somebody is at it. They are skipped rather than relaxed: relaxing them
/// would remove the only place the idiom is checked against the platform.
nonisolated func aDisplayIsAwake() -> Bool {
    (try? DisplayList.active())?.isEmpty == false
}

/// The regression fence around a measured defect of CoreGraphics. It is a unit
/// test even though it calls CoreGraphics, because the whole point is that the
/// platform's answer, not a mock's, is the thing that misleads: a fake would
/// only prove that the fake was written to agree with the note in the doc.
///
/// Everything here is read only, needs no permission and no display of its own.
@Suite("The display list, and the idiom it replaces")
struct DisplayListTests {

    /// A display id no display has. Derived rather than hard coded so the test
    /// cannot start passing for the wrong reason on a Mac with many screens.
    static func absentDisplayID() throws -> CGDirectDisplayID {
        let online = Set(try DisplayList.online())
        var candidate: CGDirectDisplayID = 0x0BAD_0001
        while online.contains(candidate) { candidate += 1 }
        return candidate
    }

    @Test("CGDisplayIsOnline answers 0xFFFFFFFF for a display that does not exist")
    func theIdiomIsWrongInBothDirections() throws {
        let absent = try Self.absentDisplayID()

        // This is the measurement, reproduced. The header promises a
        // `boolean_t`, which is an `Int32`; what comes back for a missing id is
        // every bit set, neither 0 nor 1.
        #expect(UInt32(bitPattern: CGDisplayIsOnline(absent)) == 0xFFFF_FFFF)
        #expect(UInt32(bitPattern: CGDisplayIsActive(absent)) == 0xFFFF_FFFF)

        // Hence both spellings of the obvious idiom are wrong, each on exactly
        // the case it was written for. Both shapes have been found in real
        // code: a teardown waiting for the first to become true and never
        // getting it, and a seat guard asking the second and being told a
        // vanished display was online.
        #expect((CGDisplayIsOnline(absent) == 0) == false, "the wait never ends")
        #expect((CGDisplayIsOnline(absent) != 0) == true, "the guard reads online")
    }

    @Test("list membership answers no for a display that does not exist")
    func membershipIsUnambiguous() throws {
        let absent = try Self.absentDisplayID()

        #expect(try DisplayList.isOnline(absent) == false)
        #expect(try DisplayList.online().contains(absent) == false)
        #expect(try DisplayList.active().contains(absent) == false)
    }

    /// Skipped while the machine has no awake display, because then there is
    /// nothing for the assertion to be about.
    ///
    /// `CGGetActiveDisplayList` is empty on a Mac whose screen has gone to
    /// sleep, and the main display is not in an empty list. Measured: this test
    /// and `TopologyBaselineTests.captureVerifies` both failed in a run that
    /// started while nobody was at the machine, and passed in every run with
    /// the screen awake. What is under test is the **idiom**, that membership
    /// answers cleanly where `CGDisplayIsOnline` does not, and the idiom does
    /// not stop holding because a display dimmed.
    @Test("the main display is online, active and listed",
          .enabled(if: aDisplayIsAwake()))
    func theMainDisplayIsListed() throws {
        let main = CGMainDisplayID()

        #expect(try DisplayList.isOnline(main))
        #expect(try DisplayList.active().contains(main))
        // For a display that exists the platform does answer a clean boolean,
        // which is why `== 1` is a safe test and `!= 0` is not.
        #expect(CGDisplayIsOnline(main) == 1)
    }

    @Test("the online list is never empty and contains every active display",
          .enabled(if: aDisplayIsAwake()))
    func onlineContainsActive() throws {
        let online = Set(try DisplayList.online())
        let active = Set(try DisplayList.active())

        #expect(!online.isEmpty)
        #expect(active.isSubset(of: online))
    }
}
