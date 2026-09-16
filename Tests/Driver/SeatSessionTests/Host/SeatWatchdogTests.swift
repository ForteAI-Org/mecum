//
//  SeatWatchdogTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import CursorGuard
import SeatCore
@testable import SeatSession
import Testing

/// The eight checks, one test each, plus the two rows that are only true
/// because the watchdog combines the fence's latch with the display's geometry.
@Suite("Seat watchdog")
struct SeatWatchdogTests {

    /// A seat whose every invariant holds: cursor on the physical display, tap
    /// active, display online, topology untouched.
    static func intact(
        cursor: CGPoint = CGPoint(x: 700, y: 500)
    ) -> SeatReadings {
        SeatReadings(
            mainDisplayID              : FakeGeometry.mainDisplayID,
            expectedMainDisplayID      : FakeGeometry.mainDisplayID,
            physicalTopologyIsUnchanged: true,
            virtualDisplayIsOnline     : true,
            virtualDisplayBounds       : FakeGeometry.virtual,
            fenceIsActive              : true,
            cursorLocation             : cursor,
            cursorIsInsidePhysicalRegion: FakeGeometry.physical.contains(cursor)
        )
    }

    static func readings(
        mainDisplayID     : CGDirectDisplayID = FakeGeometry.mainDisplayID,
        topologyUnchanged : Bool = true,
        displayOnline     : Bool = true,
        fenceActive       : Bool = true,
        cursor            : CGPoint? = CGPoint(x: 700, y: 500),
        cursorInsideRegion: Bool? = nil
    ) -> SeatReadings {
        SeatReadings(
            mainDisplayID              : mainDisplayID,
            expectedMainDisplayID      : FakeGeometry.mainDisplayID,
            physicalTopologyIsUnchanged: topologyUnchanged,
            virtualDisplayIsOnline     : displayOnline,
            virtualDisplayBounds       : FakeGeometry.virtual,
            fenceIsActive              : fenceActive,
            cursorLocation             : cursor,
            cursorIsInsidePhysicalRegion: cursorInsideRegion
                ?? (cursor.map(FakeGeometry.physical.contains) ?? false)
        )
    }

    @Test("an intact seat has no violation")
    func intactSeat() {
        #expect(SeatWatchdog.violations(readings: Self.intact(), signals: .quiet).isEmpty)
    }

    @Test("check one: the main display changed")
    func mainDisplay() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(mainDisplayID: 9),
            signals : .quiet
        ) == [.mainDisplayChanged])
    }

    @Test("check two: a physical display moved")
    func physicalGeometry() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(topologyUnchanged: false),
            signals : .quiet
        ) == [.physicalGeometryChanged])
    }

    @Test("check three: the virtual display left the online list")
    func displayOffline() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(displayOnline: false),
            signals : .quiet
        ) == [.virtualDisplayOffline])
    }

    @Test("check four: the tap is not active")
    func tapInactive() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(fenceActive: false),
            signals : .quiet
        ) == [.fenceTapInactive])
    }

    /// The latched half. The fence re-arms itself after a disable, so the live
    /// reading says active and only the latch remembers the interval in which
    /// the person's cursor was not fenced.
    @Test("check five: the tap was disabled since the last drain, even though it is active now")
    func tapWasDisabled() {

        let signals = FenceSignals(
            tapDisabled         : 1,
            lastDisableReason   : .timeout,
            pointerOutOfRegion  : 0,
            lastOutOfRegionPoint: nil
        )

        #expect(SeatWatchdog.violations(readings: Self.intact(), signals: signals)
            == [.fenceTapDisabled])
    }

    /// The check that cannot belong to the fence. The fence knows the person's
    /// displays and deliberately knows nothing about the virtual one, so only
    /// the watchdog can resolve a latched escape against the virtual display's
    /// bounds.
    /// AgentLab change: a latched escape the fence already corrected is not a
    /// violation while the live reading is intact. It stays visible through
    /// `fenceSignals`; only a live cursor outside the region fails closed.
    @Test("a corrected escape into the virtual display is not a violation on an intact live reading")
    func latchedPointInVirtual() {

        let signals = FenceSignals(
            tapDisabled         : 0,
            lastDisableReason   : nil,
            pointerOutOfRegion  : 3,
            lastOutOfRegionPoint: CGPoint(x: 2000, y: 700)
        )

        #expect(SeatWatchdog.violations(readings: Self.intact(), signals: signals).isEmpty)
    }

    @Test("a corrected escape past the physical edge is not a violation on an intact live reading")
    func latchedPointOutsideEverything() {

        let signals = FenceSignals(
            tapDisabled         : 0,
            lastDisableReason   : nil,
            pointerOutOfRegion  : 1,
            lastOutOfRegionPoint: CGPoint(x: -400, y: -400)
        )

        #expect(SeatWatchdog.violations(readings: Self.intact(), signals: signals).isEmpty)
    }

    @Test("check six live: the cursor is in the virtual display right now")
    func cursorInVirtualNow() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(cursor: CGPoint(x: 2500, y: 900), cursorInsideRegion: false),
            signals : .quiet
        ) == [.pointerEnteredVirtualDisplay])
    }

    @Test("check seven live: the cursor is outside the physical region")
    func cursorOutsideRegionNow() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(cursor: CGPoint(x: -10, y: -10)),
            signals : .quiet
        ) == [.pointerLeftPhysicalRegion])
    }

    @Test("check eight: the cursor position is unreadable, which is not a zero")
    func cursorUnreadable() {
        #expect(SeatWatchdog.violations(
            readings: Self.readings(cursor: nil),
            signals : .quiet
        ) == [.pointerPositionUnavailable])
    }

    @Test("a latched escape is not reported twice when the cursor is still out there")
    func noDoubleReport() {

        let signals = FenceSignals(
            tapDisabled         : 0,
            lastDisableReason   : nil,
            pointerOutOfRegion  : 1,
            lastOutOfRegionPoint: CGPoint(x: 2000, y: 700)
        )

        let violations = SeatWatchdog.violations(
            readings: Self.readings(cursor: CGPoint(x: 2100, y: 700), cursorInsideRegion: false),
            signals : signals
        )

        #expect(violations == [.pointerEnteredVirtualDisplay])
    }

    @Test("every violation maps to a host issue, so a violation takes the display down")
    func everyViolationIsHostLevel() {
        for violation in WatchdogViolation.allCases {
            #expect(violation.issue.isCritical)
        }
        #expect(WatchdogViolation.allCases.count == 8)
    }

    @Test("several broken invariants are reported together, not one at a time")
    func batched() {

        let violations = SeatWatchdog.violations(
            readings: Self.readings(
                mainDisplayID    : 9,
                topologyUnchanged: false,
                displayOnline    : false,
                fenceActive      : false,
                cursor           : nil
            ),
            signals : .quiet
        )

        #expect(violations == [
            .mainDisplayChanged, .physicalGeometryChanged,
            .virtualDisplayOffline, .fenceTapInactive, .pointerPositionUnavailable,
        ])
    }

    @Test("the heartbeat is one second, not the twenty milliseconds it replaced")
    func heartbeatPeriod() {
        #expect(SeatWatchdog.heartbeat == .seconds(1))
    }
}
