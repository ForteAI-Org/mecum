//
//  SeatWindowSessionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The coordination of several windows on its own: the succession of targets,
/// the predecessor a closure falls back to, and what a staging reading is
/// allowed to conclude. No seat, no fakes, no display.
@Suite("Seat window session")
struct SeatWindowSessionTests {

    private static func record(_ windowNumber: Int, size: CGSize = FakeGeometry.windowSize) -> WindowRecord {
        let reference = FakeGeometry.reference(
            frame       : CGRect(origin: FakeGeometry.windowOrigin, size: size),
            windowNumber: windowNumber
        )
        return WindowRecord(
            window  : AdoptedWindow(
                reference    : reference,
                originalFrame: CGRect(origin: CGPoint(x: 100, y: 100), size: size)
            ),
            platform: AppKitPlatform(),
            isStaged: true
        )
    }

    private static func session(_ windowNumbers: [Int]) -> SeatWindowSession {
        var session = SeatWindowSession()
        for windowNumber in windowNumbers { session.adopt(record(windowNumber)) }
        return session
    }

    @Test("a target reached twice keeps one place in the succession, its most recent")
    func targetReachedTwice() {
        var session = Self.session([1, 2])
        #expect(session.currentTargetNumber == 2)

        session.makeCurrent(1)
        #expect(session.targetHistory == [2, 1])
        #expect(session.currentTargetNumber == 1)

        // A to B to A: B is A's predecessor, and A is never its own.
        #expect(session.predecessor(of: 1) == 2)
    }

    @Test("a window released out of order is skipped rather than answered")
    func predecessorSkipsAReleasedWindow() {
        var session = Self.session([1, 2, 3])

        #expect(session.forget(2) == nil, "Releasing a window that is not the target moves no target")
        #expect(session.currentTargetNumber == 3)

        #expect(session.forget(3) == 1)
        #expect(session.currentTargetNumber == 1)
        #expect(session.targetHistory == [1])
    }

    @Test("with nothing left the session says so instead of choosing a stranger")
    func noPredecessorLeft() {
        var session = Self.session([1])

        #expect(session.forget(1) == nil)
        #expect(session.currentTargetNumber == nil)
        #expect(session.currentTarget == nil)
        #expect(session.adoptedWindows.isEmpty)
    }

    @Test("staging is read back from the size, and a thumbnail is the only stash")
    func stagingIsReadBack() {
        var session = Self.session([1, 2])
        let thumbnail = CGSize(width: 90, height: 97)

        session.refreshStaging(besides: 2) { _ in thumbnail }
        #expect(session[1]?.isStaged == false)
        #expect(session[2]?.isStaged == true, "The staged window itself is never re-read here")

        session.refreshStaging(besides: 2) { _ in FakeGeometry.windowSize }
        #expect(session[1]?.isStaged == true, "A window still at full size is still on stage")
    }

    @Test("a window the server cannot read keeps the staging it had")
    func unreadableWindowKeepsItsStaging() {
        var session = Self.session([1, 2])

        session.refreshStaging(besides: 2) { _ in nil }
        #expect(session[1]?.isStaged == true, "Not readable is not evidence of stashed")

        session[1]?.isStaged = false
        session.refreshStaging(besides: 2) { _ in nil }
        #expect(session[1]?.isStaged == false)
    }

    @Test("the processes behind the windows are counted once each")
    func processesAreCountedOnce() {
        let session = Self.session([1, 2, 3])
        #expect(session.processIDs == [FakeGeometry.targetPID])
    }
}
