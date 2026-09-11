//
//  VirtualWindowPlacementTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// Synthetic geometry only: no window is read and no input is sent.
@Suite("Virtual window placement")
struct VirtualWindowPlacementTests {

    static let virtual    = CGRect(x: 1823, y: 1048, width: 1920, height: 1080)
    static let movedFrame = CGRect(x: 1823, y: 1048, width: 1298, height: 949)

    static func reference(frame: CGRect, pid: Int32 = 123, number: Int = 456) -> WindowReference {
        WindowReference(
            identity: WindowIdentity(
                process: ProcessIdentity(
                    processID       : pid,
                    serialNumberHigh: 1,
                    serialNumberLow : UInt32(bitPattern: pid)
                ),
                windowNumber     : number,
                ownerConnectionID: pid &+ 1_000
            ),
            frame: frame
        )
    }

    static let original = reference(frame: CGRect(x: 214, y: 33, width: 1298, height: 949))
    static let moved    = reference(frame: movedFrame)
    static let server   = reference(frame: movedFrame)

    static func failures(
        _ current         : WindowReference,
        active            : Bool = false,
        server            : WindowReference? = Self.server,
        bounds            : CGRect = Self.virtual,
        expected          : Int32? = 321,
        user              : Int32? = 321,
        behind            : Bool? = true,
        concurrent        : Bool = false
    ) -> [PlacementFailure] {
        VirtualWindowPlacementCheck.failures(
            original          : original,
            current           : current,
            currentIsActive   : active,
            server            : server,
            displayBounds     : bounds,
            expectedUserPID   : expected,
            currentUserPID    : user,
            targetBehindUser  : behind,
            allowsUserActivity: concurrent
        )
    }

    @Test("the reported frame is correctly on the virtual display")
    func placementAccepted() {
        #expect(Self.failures(Self.moved).isEmpty)
    }

    @Test("a different Window ID is rejected")
    func differentWindowNumber() {
        #expect(!Self.failures(Self.reference(frame: Self.movedFrame, number: 457)).isEmpty)
    }

    @Test("a different observed process is rejected")
    func differentObservedProcess() {
        #expect(!Self.failures(Self.reference(frame: Self.movedFrame, pid: 124)).isEmpty)
    }

    @Test("a different window server process is rejected")
    func differentServerProcess() {
        #expect(!Self.failures(
            Self.moved, server: Self.reference(frame: Self.movedFrame, pid: 124)
        ).isEmpty)
    }

    @Test("a different window server Window ID is rejected")
    func differentServerWindowNumber() {
        #expect(!Self.failures(
            Self.moved, server: Self.reference(frame: Self.movedFrame, number: 457)
        ).isEmpty)
    }

    @Test("a missing window server reading is rejected")
    func missingServerReading() {
        #expect(Self.failures(Self.moved, server: nil) == [.windowServerReadingMissing])
    }

    @Test("the old physical frame is rejected")
    func oldPhysicalFrame() {
        #expect(!Self.failures(Self.original).isEmpty)
    }

    @Test("a centre on the virtual display is not enough when the window overflows it")
    func windowCrossingTheEdge() {
        let crossing = Self.movedFrame.offsetBy(dx: -30, dy: 0)
        #expect(Self.virtual.contains(CGPoint(x: crossing.midX, y: crossing.midY)))
        #expect(!Self.failures(
            Self.reference(frame: crossing), server: Self.reference(frame: crossing)
        ).isEmpty)
    }

    @Test("a resize is rejected")
    func resizeRejected() {
        let resized = CGRect(x: Self.movedFrame.minX, y: Self.movedFrame.minY, width: 1000, height: 949)
        #expect(!Self.failures(
            Self.reference(frame: resized), server: Self.reference(frame: resized)
        ).isEmpty)
    }

    @Test("readings that disagree are rejected")
    func readingsDisagree() {
        #expect(Self.failures(
            Self.moved, server: Self.reference(frame: Self.movedFrame.offsetBy(dx: 20, dy: 0))
        ).contains(.readingsDisagree))
    }

    @Test("geometric rounding is accepted")
    func roundingAccepted() {
        #expect(Self.failures(
            Self.moved, server: Self.reference(frame: Self.movedFrame.offsetBy(dx: 1, dy: 1))
        ).isEmpty)
    }

    @Test("an active target is rejected")
    func activeTargetRejected() {
        #expect(Self.failures(Self.moved, active: true).contains(.targetActivated))
    }

    @Test("a changed user application is rejected")
    func userApplicationChanged() {
        #expect(!Self.failures(Self.moved, user: 322).isEmpty)
    }

    @Test("an unavailable user application is rejected")
    func userApplicationUnavailable() {
        #expect(!Self.failures(Self.moved, user: nil).isEmpty)
    }

    @Test("a missing user application baseline is rejected")
    func userApplicationBaselineMissing() {
        #expect(!Self.failures(Self.moved, expected: nil, user: nil).isEmpty)
    }

    @Test("the target can never be the User Seat")
    func targetCannotBeTheUserSeat() {
        #expect(Self.failures(Self.moved, expected: 123, user: 123).contains(.targetFrontmost))
    }

    @Test("a target in front is rejected")
    func targetInFrontRejected() {
        #expect(!Self.failures(Self.moved, behind: false).isEmpty)
    }

    @Test("an unknown window order is rejected")
    func unknownWindowOrder() {
        #expect(!Self.failures(Self.moved, behind: nil).isEmpty)
    }

    @Test("a missing display is rejected")
    func missingDisplay() {
        #expect(!Self.failures(Self.moved, bounds: .zero).isEmpty)
    }

    @Test("infinite geometry is rejected")
    func infiniteGeometry() {
        #expect(!Self.failures(Self.reference(frame: .infinite)).isEmpty)
    }

    @Test("NaN geometry is rejected")
    func nanGeometry() {
        #expect(!Self.failures(
            Self.reference(frame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100))
        ).isEmpty)
    }

    @Test("two readings of the same frame are stable")
    func stableReadings() {
        #expect(VirtualWindowPlacementCheck.framesMatch(Self.movedFrame, Self.movedFrame))
    }

    @Test("readings taken while the window moves are not stable")
    func movingReadings() {
        #expect(!VirtualWindowPlacementCheck.framesMatch(
            Self.movedFrame, Self.movedFrame.offsetBy(dx: 20, dy: 0)
        ))
    }

    @Test("the person's Stage Manager is allowed while the loop places a window")
    func concurrentStageManager() {
        #expect(Self.failures(Self.moved, user: 322, behind: nil, concurrent: true).isEmpty)
    }

    @Test("the global window order across displays does not block the loop")
    func concurrentWindowOrder() {
        #expect(Self.failures(Self.moved, user: 322, behind: false, concurrent: true).isEmpty)
    }

    @Test("a Stage Manager transition without a frontmost app is allowed with an inactive target")
    func concurrentWithoutFrontmost() {
        #expect(Self.failures(Self.moved, user: nil, behind: nil, concurrent: true).isEmpty)
    }

    @Test("a frontmost target is rejected even in the concurrent loop")
    func concurrentFrontmostTarget() {
        #expect(!Self.failures(Self.moved, user: 123, concurrent: true).isEmpty)
    }

    @Test("an active target is rejected even in the concurrent loop")
    func concurrentActiveTarget() {
        #expect(!Self.failures(
            Self.moved, active: true, user: 322, concurrent: true
        ).isEmpty)
    }

    @Test("a move onto a physical display is rejected even while the User Seat changes")
    func concurrentMoveToPhysicalDisplay() {
        #expect(!Self.failures(
            Self.original, user: 322, behind: nil, concurrent: true
        ).isEmpty)
    }
}
