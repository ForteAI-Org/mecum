//
//  SeatGuardTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The guard performs no system call, so every reading here is synthetic.
@Suite("Seat guard")
struct SeatGuardTests {

    static let virtual    = CGRect(x: 1823, y: 1048, width: 1920, height: 1080)
    static let movedFrame = CGRect(x: 1823, y: 1048, width: 1298, height: 949)
    static let resized    = CGRect(x: movedFrame.minX, y: movedFrame.minY, width: 1000, height: 949)
    static let crossing   = movedFrame.offsetBy(dx: -30, dy: 0)

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

    static let target = reference(frame: movedFrame)
    static let seat   = SeatGuard(target: target, displayID: 99, displayBounds: virtual)

    static func issues(
        server           : WindowReference? = Self.target,
        observed         : WindowReference? = Self.target,
        observedIsActive : Bool = false,
        displayID        : CGDirectDisplayID? = 99,
        bounds           : CGRect = Self.virtual,
        online           : Bool = true,
        fence            : Bool = true,
        active           : Bool? = false,
        user             : Int32? = 321,
        wasActivated     : Bool = false
    ) -> [SeatIssue] {
        seat.issues(
            server              : server,
            observed            : observed,
            observedIsActive    : observedIsActive,
            currentDisplayID    : displayID,
            currentDisplayBounds: bounds,
            displayIsOnline     : online,
            cursorFenceIsActive : fence,
            targetIsActive      : active,
            frontmostProcessID  : user,
            targetWasActivated  : wasActivated
        )
    }

    @Test("a stable Agent Seat is valid")
    func stableSeat() {
        #expect(Self.issues().isEmpty)
    }

    @Test("the person changing application between planning and input is allowed")
    func userApplicationChanged() {
        #expect(Self.issues(user: 322).isEmpty)
    }

    @Test("a transition without a frontmost application does not change the target")
    func noFrontmostApplication() {
        #expect(Self.issues(user: nil).isEmpty)
    }

    @Test("the same user window may come back in front")
    func userWindowReturns() {
        #expect(Self.issues(user: 321).isEmpty)
    }

    @Test("a frontmost target is forbidden")
    func frontmostTargetForbidden() {
        #expect(Self.issues(user: 123) == [.targetActivated])
    }

    @Test("an active target is forbidden even with another process frontmost")
    func activeTargetForbidden() {
        #expect(Self.issues(active: true) == [.targetActivated])
    }

    @Test("a transient activation stays an issue after the person comes back")
    func transientActivationForbidden() {
        #expect(Self.issues(wasActivated: true) == [.targetActivated])
    }

    @Test("a dead process is forbidden")
    func deadProcessForbidden() {
        #expect(Self.issues(active: nil) == [.processUnavailable])
    }

    @Test("a closed window is forbidden")
    func closedWindowForbidden() {
        #expect(Self.issues(server: nil) == [.windowUnavailable])
    }

    @Test("a Window ID reused by another process is forbidden")
    func reusedWindowNumberForbidden() {
        #expect(Self.issues(server: Self.reference(frame: Self.movedFrame, pid: 124))
            .contains(.identityChanged))
    }

    @Test("another Window ID is forbidden")
    func otherWindowNumberForbidden() {
        #expect(Self.issues(server: Self.reference(frame: Self.movedFrame, number: 457))
            .contains(.identityChanged))
    }

    @Test("an observed reading of another process is forbidden")
    func observedOtherProcessForbidden() {
        #expect(Self.issues(observed: Self.reference(frame: Self.movedFrame, pid: 124))
            .contains(.identityChanged))
    }

    @Test("an observed reading of another window is forbidden")
    func observedOtherWindowForbidden() {
        #expect(Self.issues(observed: Self.reference(frame: Self.movedFrame, number: 457))
            .contains(.identityChanged))
    }

    @Test("an observed reading taken while the target was active is forbidden")
    func observedActiveTargetForbidden() {
        #expect(Self.issues(observedIsActive: true) == [.targetActivated])
    }

    @Test("a move inside the same virtual display invalidates the coordinates")
    func moveInsideVirtualDisplay() {
        #expect(Self.issues(server: Self.reference(frame: Self.movedFrame.offsetBy(dx: 20, dy: 0)))
            .contains(.geometryChanged))
    }

    @Test("an observed move the window server has not caught up with is forbidden")
    func observedMoveWithoutServer() {
        #expect(Self.issues(observed: Self.reference(frame: Self.movedFrame.offsetBy(dx: 20, dy: 0)))
            .contains(.snapshotChanged))
    }

    @Test("a resized target is forbidden")
    func resizedTargetForbidden() {
        #expect(Self.issues(server: Self.reference(frame: Self.resized)).contains(.geometryChanged))
    }

    @Test("leaving the virtual display is forbidden")
    func leavingVirtualDisplayForbidden() {
        #expect(Self.issues(server: Self.reference(frame: Self.crossing)).contains(.geometryChanged))
    }

    @Test("a disabled fence interrupts even while the User Seat moves")
    func disabledFenceInterrupts() {
        #expect(Self.issues(fence: false, user: 322) == [.fenceUnavailable])
    }

    @Test("an offline virtual display is forbidden")
    func offlineDisplayForbidden() {
        #expect(Self.issues(online: false) == [.displayChanged])
    }

    @Test("a removed virtual display is forbidden")
    func removedDisplayForbidden() {
        #expect(Self.issues(displayID: nil) == [.displayChanged])
    }

    @Test("a replaced virtual display is forbidden")
    func replacedDisplayForbidden() {
        #expect(Self.issues(displayID: 100) == [.displayChanged])
    }

    @Test("changed virtual geometry is forbidden")
    func changedVirtualGeometryForbidden() {
        #expect(Self.issues(bounds: Self.virtual.offsetBy(dx: 20, dy: 0)).contains(.displayChanged))
    }

    @Test("invalid virtual geometry is forbidden")
    func invalidVirtualGeometryForbidden() {
        #expect(Self.issues(bounds: .infinite).contains(.displayChanged))
    }

    @Test("an invalid window server frame is forbidden")
    func invalidServerFrameForbidden() {
        #expect(Self.issues(server: Self.reference(frame: .null)).contains(.geometryChanged))
    }

    @Test("five hundred User Seat switches between actions keep the target")
    func userSeatSwitchesKeepTheTarget() {
        for user in [Int32?(321), 322, nil, 323, 321] {
            for _ in 0..<100 {
                #expect(Self.issues(user: user).isEmpty, "Stage Manager only changes the User Seat")
            }
        }
    }
}
