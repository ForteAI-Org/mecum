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
            platform  : AppKitPlatform(),
            isStaged  : true,
            operationalSize: size
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

    @Test("with no window excluded every held record is read back")
    func stagingIsReadBackForEveryRecord() {
        var session = Self.session([1, 2])
        let thumbnail = CGSize(width: 90, height: 97)

        session.refreshStaging { _ in thumbnail }
        #expect(session[1]?.isStaged == false)
        #expect(session[2]?.isStaged == false, "the window nobody excluded is read like the rest")
    }

    @Test("a window shrunk to fit the display is not a stashed window")
    func aShrunkWindowIsNotAStash() {
        var session = SeatWindowSession()
        let shrunk  = CGSize(width: 400, height: 300)

        // What it is owed on its return is the frame it had before the seat
        // shrank it, and comparing a reading with that would stash it forever.
        var record = Self.record(1, size: shrunk)
        record = WindowRecord(
            window    : AdoptedWindow(
                reference    : record.window.reference,
                originalFrame: CGRect(origin: CGPoint(x: 100, y: 100), size: FakeGeometry.windowSize)
            ),
            platform  : AppKitPlatform(),
            isStaged  : true,
            operationalSize: shrunk
        )
        session.adopt(record)

        session.refreshStaging { _ in shrunk }
        #expect(session[1]?.isStaged == true)
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

    /// The oracle is the resize itself and not the predicate: 800 by 600 read
    /// back at 780 by 580 and at 900 by 700 is a window somebody resized, and
    /// neither reading is evidence of a stash.
    @Test("a resize of 20 to 100 points is not staging evidence either way")
    func aResizeIsNotStagingEvidence() {
        var session = Self.session([1, 2])

        for size in [CGSize(width: 780, height: 580), CGSize(width: 900, height: 700)] {
            session[1]?.isStaged = true
            session.refreshStaging(besides: 2) { _ in size }
            #expect(session[1]?.isStaged == true, "a resized window on stage stays on stage")

            session[1]?.isStaged = false
            session.refreshStaging(besides: 2) { _ in size }
            #expect(session[1]?.isStaged == false, "and a stashed one is not staged by a reading")
        }
    }

    /// The two thumbnails measured live, against the window they were measured
    /// on: a 1291 by 949 pt window published as 164 by 180, and the 90 by 97
    /// reading of a window of the fixture's size.
    @Test("a real thumbnail is still the positive evidence of a stash")
    func aThumbnailIsStillAStash() {
        var session = Self.session([1])
        session.refreshStaging { _ in CGSize(width: 90, height: 97) }
        #expect(session[1]?.isStaged == false)

        var wide = SeatWindowSession()
        let full = CGSize(width: 1_291, height: 949)
        wide.adopt(Self.record(1, size: full))
        wide.refreshStaging { _ in CGSize(width: 164, height: 180) }
        #expect(wide[1]?.isStaged == false)
    }

    @Test("an accepted geometry becomes the operational size and keeps the obligations")
    func acceptedGeometryKeepsObligations() {
        var session = SeatWindowSession()
        let owed    = CGRect(origin: CGPoint(x: 100, y: 100), size: FakeGeometry.windowSize)
        let sheet   = AdoptedWindow(
            reference    : Self.record(1).window.reference,
            originalFrame: owed,
            title        : "a sheet",
            owesNoReturn : true
        )
        session.adopt(WindowRecord(
            window         : sheet,
            platform       : AppKitPlatform(),
            isStaged       : false,
            operationalSize: FakeGeometry.windowSize
        ))

        let resized = FakeGeometry.reference(
            frame       : CGRect(origin: FakeGeometry.windowOrigin,
                                 size  : CGSize(width: 880, height: 640)),
            windowNumber: 1
        )
        session.acceptGeometry(resized)

        #expect(session[1]?.operationalSize == CGSize(width: 880, height: 640))
        #expect(session[1]?.isStaged == true)
        #expect(session[1]?.window.owesNoReturn == true)
        #expect(session[1]?.window.originalFrame == owed, "what it is owed does not move")
        #expect(session[1]?.window.title == "a sheet")

        // And the record now reads as on stage at the size it is standing at,
        // which is the whole point of the two moving together.
        session.refreshStaging { _ in CGSize(width: 880, height: 640) }
        #expect(session[1]?.isStaged == true)
    }

    @Test("a reading of another lifetime of the window id accepts nothing")
    func acceptedGeometryNeedsTheSameIdentity() {
        var session = Self.session([1])
        let other   = FakeGeometry.reference(
            frame       : CGRect(origin: FakeGeometry.windowOrigin,
                                 size  : CGSize(width: 880, height: 640)),
            windowNumber: 1,
            lifetime    : 2
        )
        session.acceptGeometry(other)
        #expect(session[1]?.operationalSize == FakeGeometry.windowSize)
    }

    @Test("the processes behind the windows are counted once each")
    func processesAreCountedOnce() {
        let session = Self.session([1, 2, 3])
        #expect(session.processIDs == [FakeGeometry.targetPID])
    }
}
