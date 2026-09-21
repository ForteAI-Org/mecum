//
//  AssignmentReleaseTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing
import VirtualScreens

/// Makes the fake window server follow what the seat writes.
///
/// A move names an origin and not a window, so the router is told which window
/// each destination belongs to: the homes of the fixture's windows, and
/// whichever window an adoption is moving onto the display right now.
@MainActor
final class MoveRouter {

    /// One window the router can answer for. The process is part of it because
    /// a reading that came back under another PID is another window, and the
    /// seat refuses it as `identityChanged` rather than moving it.
    struct Window {
        let number   : Int
        let size     : CGSize
        var processID: Int32 = FakeGeometry.targetPID
    }

    private let sensing: FakeSensing

    /// The window the current adoption is moving, which is where an origin that
    /// is nobody's home belongs.
    var adopting: Window?

    /// Where each window goes home to, by the origin the seat writes for it.
    var homes: [CGPoint: Window] = [:]

    init(_ sensing: FakeSensing) { self.sensing = sensing }

    func install(on placing: FakePlacing) {
        placing.onMove = { [weak self] origin in
            MainActor.assumeIsolated { self?.wrote(origin) }
        }
    }

    func wrote(_ origin: CGPoint) {
        guard let window = homes[origin] ?? adopting else { return }
        place(window, at: CGRect(origin: origin, size: window.size))
    }

    func place(_ window: Window, at frame: CGRect) {
        let reference = FakeGeometry.reference(
            frame       : frame,
            processID   : window.processID,
            windowNumber: window.number
        )
        if window.number == FakeGeometry.windowNumber { sensing.geometry = reference }
        else { sensing.additionalWindows[window.number] = reference }
    }
}

/// Releasing one whole Multi-App assignment: every register the seat keeps
/// closed in one operation, the reconciliation that writes nothing, and the
/// leftovers that keep their identity instead of disappearing.
///
/// The failure these come from is a consumer that gave every window it knew of
/// back and was still refused the handback over one surface it was never told
/// about, which left the person unable to move on to a second application.
///
/// The oracles are the placing fake's own write log, the fake window server's
/// frames and the seat's public registers, never the report under test on its
/// own. The Window IDs are the fakes'; the live campaign's numbers are evidence
/// of one machine and are not written into a test.
@MainActor
@Suite("Releasing a whole assignment")
struct AssignmentReleaseTests {

    static let sheetWindowNumber  = 881
    static let helperWindowNumber = 882
    static let secondWindowNumber = 883

    static let sheetSize  = CGSize(width: 400, height: 300)
    static let helperHome = CGRect(x: 950, y: 120, width: 300, height: 200)

    /// Where the helper is once a reading has put it inside the seat, which is
    /// what makes it a held member the consumer cannot reach.
    static let helperInSeat = CGRect(x: 1600, y: 200, width: 300, height: 200)

    static let hostWindow = MoveRouter.Window(
        number: FakeGeometry.windowNumber,
        size  : FakeGeometry.windowSize
    )
    static let sheetWindow  = MoveRouter.Window(number: sheetWindowNumber,  size: sheetSize)
    static let helperWindow = MoveRouter.Window(number: helperWindowNumber, size: helperHome.size)

    struct Fixture {
        let seat   : AgentSeat
        let sensing: FakeSensing
        let placing: FakePlacing
        let reader : ControlledSurfaceReader
        let router : MoveRouter
        let host   : AdoptedWindow
    }

    /// A seat holding one ordinary window of one instance, with the window
    /// server following whatever the seat writes for it.
    static func fixture(marker: Int64, withHelper: Bool = false) async throws -> Fixture {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let router  = MoveRouter(sensing)
        let seat    = makeSeat(
            sensing: sensing,
            placing: placing,
            marker : marker,
            reader : reader
        )
        router.install(on: placing)
        router.homes[FakeGeometry.userSeatWindow.frame.origin] = Self.hostWindow

        // Before the adoption, whose reading is the one whose surfaces are
        // recorded as pre-existing.
        if withHelper { router.place(Self.helperWindow, at: Self.helperHome) }

        router.adopting = Self.hostWindow
        let host = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        router.adopting = nil

        return Fixture(
            seat   : seat,
            sensing: sensing,
            placing: placing,
            reader : reader,
            router : router,
            host   : host
        )
    }

    /// Adds a sheet drawn inside the host and adopts it, so the seat holds a
    /// surface that owes no return.
    ///
    /// The modal block is attested before the adoption because that is when the
    /// obligation is decided, and the record never recomputes it.
    @discardableResult
    static func adoptSheet(_ fixture: Fixture) async throws -> AdoptedWindow {

        let inbound = FakeGeometry.reference(
            frame       : CGRect(origin: CGPoint(x: 1700, y: 400), size: Self.sheetSize),
            windowNumber: Self.sheetWindowNumber
        )
        fixture.sensing.additionalWindows[Self.sheetWindowNumber] = inbound
        fixture.reader.roles[Self.sheetWindowNumber]  = .dialog
        fixture.reader.modals[Self.sheetWindowNumber] =
            .window(try #require(fixture.host.reference.identity))
        fixture.seat.refreshTargetReadings()
        fixture.seat.refreshTargetReadings()

        fixture.router.adopting = Self.sheetWindow
        defer { fixture.router.adopting = nil }
        return try await fixture.seat.adopt(inbound, platform: AppKitPlatform())
    }

    /// Moves the helper's reading inside the seat, which is what turns a member
    /// nobody adopted into one the seat owes a return for.
    static func containHelper(_ fixture: Fixture) {
        fixture.router.homes[Self.helperHome.origin] = Self.helperWindow
        fixture.router.place(Self.helperWindow, at: Self.helperInSeat)
        fixture.seat.refreshTargetReadings()
    }

    static func heldMemberNumbers(_ fixture: Fixture) -> [Int] {
        fixture.seat.assignmentKit.inventory.heldMembers.map(\.windowNumber)
    }

    /// A window of a second instance, which a release of the first must leave
    /// exactly where it is.
    static func otherInstanceWindow(processID: Int32) -> WindowReference {
        FakeGeometry.reference(
            frame       : CGRect(x: 2000, y: 900, width: 500, height: 400),
            processID   : processID,
            windowNumber: Self.secondWindowNumber
        )
    }

    // MARK: The whole set

    @Test("one release closes the adopted window, the sheet, the held member and the observation")
    func everyObligationIsClosed() async throws {

        let fixture = try await Self.fixture(marker: 2_101, withHelper: true)
        let sheet   = try await Self.adoptSheet(fixture)
        Self.containHelper(fixture)
        try await observe(fixture.seat)

        #expect(sheet.owesNoReturn)
        #expect(Self.heldMemberNumbers(fixture).contains(Self.helperWindowNumber),
                "the member the consumer cannot reach is what the handback used to refuse over")
        #expect(fixture.seat.observationIssuer.outstanding != nil)

        let writesBefore = fixture.placing.moves.count
        let report       = await fixture.seat.releaseAssignment()

        #expect(report.outcome == .released)
        #expect(report.isComplete)
        #expect(report.obligations.isEmpty)
        #expect(report.windows[fixture.host.id] == .returned)
        #expect(report.windows[sheet.id] == .returned)
        #expect(report.windows[Self.helperWindowNumber] == .returned)

        // The oracles: where the windows actually are, and what was written.
        #expect(fixture.sensing.geometry?.frame == FakeGeometry.userSeatWindow.frame)
        #expect(fixture.sensing.additionalWindows[Self.helperWindowNumber]?.frame
                == Self.helperHome)
        #expect(fixture.placing.moves.dropFirst(writesBefore).sorted(by: { $0.x < $1.x })
                == [FakeGeometry.userSeatWindow.frame.origin, Self.helperHome.origin],
                "two windows go home and the sheet is never moved on its own")

        #expect(fixture.seat.adoptedWindows.isEmpty)
        #expect(!fixture.seat.hasPendingWindowRestorations)
        #expect(fixture.seat.coherentState.instance == nil)
        #expect(fixture.seat.observationIssuer.outstanding == nil,
                "the observation half is closed with the assignment")
        #expect(fixture.seat.coherentState.lastInvalidation == .lifecycleChanged)
    }

    @Test("after the release the same seat takes a second application")
    func theSeatTakesASecondApplication() async throws {

        let fixture = try await Self.fixture(marker: 2_102, withHelper: true)
        try await Self.adoptSheet(fixture)
        Self.containHelper(fixture)

        let report = await fixture.seat.releaseAssignment()
        #expect(report.outcome == .released)

        let otherPID  = FakeGeometry.distinctProcessID()
        let reference = Self.otherInstanceWindow(processID: otherPID)
        fixture.sensing.additionalWindows[Self.secondWindowNumber] = reference
        fixture.router.adopting = MoveRouter.Window(
            number   : Self.secondWindowNumber,
            size     : reference.frame.size,
            processID: otherPID
        )
        let second = try await fixture.seat.adopt(reference, platform: AppKitPlatform())
        fixture.router.adopting = nil

        #expect(fixture.seat.coherentState.instance?.processID == otherPID)
        #expect(fixture.seat.assignmentKit.lifecycle.generation == 2,
                "the second assignment is its own generation and not a continuation")
        #expect(fixture.seat.adoptedWindows.map(\.id) == [second.id])

        // The host was never taken down and put back up: the same seat, the
        // same display bounds, and no second seat was made.
        #expect(fixture.seat.seatGuard?.displayBounds == FakeGeometry.virtual)
    }

    @Test("a release never touches a window of another assignment")
    func anotherAssignmentsWindowIsUntouched() async throws {

        let fixture = try await Self.fixture(marker: 2_103)

        let otherPID  = FakeGeometry.distinctProcessID()
        let reference = Self.otherInstanceWindow(processID: otherPID)
        fixture.sensing.additionalWindows[Self.secondWindowNumber] = reference
        fixture.router.adopting = MoveRouter.Window(
            number   : Self.secondWindowNumber,
            size     : reference.frame.size,
            processID: otherPID
        )
        let second = try await fixture.seat.adopt(reference, platform: AppKitPlatform())
        fixture.router.adopting = nil

        let standingAt   = second.reference.frame
        let writesBefore = fixture.placing.moves.count
        let report       = await fixture.seat.releaseAssignment()

        #expect(report.outcome == .released)
        #expect(report.windows[second.id] == nil, "it is not this assignment's to answer for")
        #expect(fixture.seat.adoptedWindows.map(\.id) == [second.id])
        #expect(fixture.sensing.additionalWindows[Self.secondWindowNumber]?.frame == standingAt)
        #expect(fixture.placing.moves.dropFirst(writesBefore)
                == [FakeGeometry.userSeatWindow.frame.origin],
                "one window went home and the other was left standing")
    }

    // MARK: The reconciliation

    @Test("a closed id and a window already home are reconciled without a write")
    func closedAndAlreadyHomeAreReconciledFirst() async throws {

        let fixture = try await Self.fixture(marker: 2_104)

        // A second adopted window the window server has since been asked for by
        // identity and answered no row at all.
        let extra = FakeGeometry.reference(
            frame       : CGRect(x: 1800, y: 900, width: 300, height: 250),
            windowNumber: Self.secondWindowNumber
        )
        fixture.sensing.additionalWindows[Self.secondWindowNumber] = extra
        fixture.router.adopting = MoveRouter.Window(
            number: Self.secondWindowNumber,
            size  : extra.frame.size
        )
        let closed = try await fixture.seat.adopt(extra, platform: AppKitPlatform())
        fixture.router.adopting = nil

        fixture.sensing.additionalWindows[Self.secondWindowNumber] = nil
        fixture.reader.destroyed = [try #require(closed.reference.identity)]

        // And the first one is already standing at the frame it is owed, which
        // is the state the consumer's own earlier return leaves behind.
        fixture.router.place(Self.hostWindow, at: FakeGeometry.userSeatWindow.frame)

        let writesBefore = fixture.placing.moves.count
        let report       = await fixture.seat.releaseAssignment()

        #expect(report.outcome == .released)
        #expect(report.reconciled == [fixture.host.id, closed.id].sorted())
        #expect(report.windows[fixture.host.id] == .returned)
        #expect(report.windows[closed.id] == .vanished)
        #expect(report.obligations.isEmpty)
        #expect(fixture.placing.moves.count == writesBefore,
                "the reconciliation writes no geometry at all")
        #expect(fixture.seat.adoptedWindows.isEmpty)
        #expect(fixture.seat.coherentState.instance == nil)
    }

    // MARK: What is still owed

    @Test("a window that would not go back stays an obligation with its identity")
    func aRealLeftoverKeepsItsIdentity() async throws {

        let fixture = try await Self.fixture(marker: 2_105)

        // Nothing the seat writes lands: the window stays on the display and
        // the readings never agree with the frame it is owed.
        fixture.placing.onMove = { _ in }
        fixture.placing.moveError = DisplayFailure.attributeNotSettable("AXPosition")

        let report = await fixture.seat.releaseAssignment()

        #expect(report.outcome == .released, "a leftover does not keep the application bound")
        #expect(!report.isComplete)
        #expect(report.windows[fixture.host.id] == .refused)

        let obligation = try #require(report.obligations.first)
        #expect(report.obligations.count == 1)
        #expect(obligation.identity == fixture.host.reference.identity)
        #expect(obligation.owedFrame == FakeGeometry.userSeatWindow.frame)
        #expect(obligation.reason == .returnRefused)

        // And the seat is free for the next application, which is the whole
        // point: one leftover used to stop the person moving on.
        #expect(fixture.seat.coherentState.instance == nil)
    }

    @Test("a second release answers nothing assigned and repeats what is still owed")
    func doubleReleaseIsIdempotent() async throws {

        let fixture = try await Self.fixture(marker: 2_106, withHelper: true)
        Self.containHelper(fixture)

        let first = await fixture.seat.releaseAssignment()
        #expect(first.outcome == .released)

        let writesBefore = fixture.placing.moves.count
        let second       = await fixture.seat.releaseAssignment()

        #expect(second.outcome == .nothingAssigned)
        #expect(second.windows.isEmpty)
        #expect(second.obligations == first.obligations,
                "the second call describes the same state and invents nothing")
        #expect(fixture.placing.moves.count == writesBefore,
                "a second release writes nothing")
        #expect(fixture.seat.adoptedWindows.isEmpty)
    }

    @Test("a teardown after a release still reports the windows the release closed")
    func theFinalReportCarriesThePerWindowAnswers() async throws {

        let fixture = try await Self.fixture(marker: 2_107, withHelper: true)
        let sheet   = try await Self.adoptSheet(fixture)
        Self.containHelper(fixture)

        let release = await fixture.seat.releaseAssignment()
        #expect(release.outcome == .released)

        let teardown = await fixture.seat.releaseAllWindows(.returnToUserSeat)

        // The audit's two lines that disagreed: a per-window warning, and then
        // a final report that listed no window at all.
        for (number, outcome) in release.windows {
            #expect(teardown[number] == outcome,
                    "window \(number) is answered the same way by both reports")
        }
        #expect(teardown[fixture.host.id] == .returned)
        #expect(teardown[sheet.id] == .returned)
        #expect(teardown[Self.helperWindowNumber] == .returned)
    }

    // MARK: The deadline

    @Test("an expired deadline and a cancellation both leave the assignment standing")
    func anExpiredDeadlineResumes() async throws {

        let fixture      = try await Self.fixture(marker: 2_108)
        let writesBefore = fixture.placing.moves.count

        // A deadline already spent when the first surface is reached, which is
        // the case a longer one reaches after the windows before it.
        let expired = await fixture.seat.releaseAssignment(within: .zero)

        #expect(expired.outcome == .cancelled)
        #expect(expired.windows.isEmpty)
        #expect(fixture.placing.moves.count == writesBefore, "nothing was written")
        #expect(fixture.seat.coherentState.instance?.processID == FakeGeometry.targetPID,
                "the assignment is what entrusts the return of what is still held")

        let obligation = try #require(expired.obligations.first)
        #expect(obligation.identity == fixture.host.reference.identity)
        #expect(obligation.owedFrame == FakeGeometry.userSeatWindow.frame)
        #expect(obligation.reason == .notAttempted)
        #expect(fixture.seat.adoptedWindows.map(\.id) == [fixture.host.id],
                "nothing was lost: the window is still held and can be asked for again")

        // The same stop from a cancelled task, with the deadline wide open.
        let task = Task { await fixture.seat.releaseAssignment() }
        task.cancel()
        let cancelled = await task.value

        #expect(cancelled.outcome == .cancelled)
        #expect(fixture.placing.moves.count == writesBefore)
        #expect(fixture.seat.adoptedWindows.map(\.id) == [fixture.host.id])

        // And asking again, uncancelled, finishes it.
        let again = await fixture.seat.releaseAssignment()
        #expect(again.outcome == .released)
        #expect(again.windows[fixture.host.id] == .returned)
        #expect(again.obligations.isEmpty)
        #expect(fixture.sensing.geometry?.frame == FakeGeometry.userSeatWindow.frame)
    }

    @Test("a negative release budget is expired, never converted to an unbounded unsigned wait")
    func negativeDeadlineLeavesTheAssignmentHeld() async throws {
        let fixture = try await Self.fixture(marker: 2_111)
        let report = await fixture.seat.releaseAssignment(within: .seconds(-1))

        #expect(report.outcome == .cancelled)
        #expect(report.windows.isEmpty)
        #expect(report.obligations.first?.reason == .notAttempted)
        #expect(fixture.seat.adoptedWindows.map(\.id) == [fixture.host.id])
    }

    // MARK: The half-failed adoption

    @Test("a sheet whose adoption is rolled back is not written back to its birth frame")
    func aRolledBackSheetIsNotRepositioned() async throws {

        let fixture = try await Self.fixture(marker: 2_109)

        let inbound = FakeGeometry.reference(
            frame       : CGRect(origin: CGPoint(x: 1700, y: 400), size: Self.sheetSize),
            windowNumber: Self.sheetWindowNumber
        )
        fixture.sensing.additionalWindows[Self.sheetWindowNumber] = inbound
        fixture.reader.roles[Self.sheetWindowNumber]  = .dialog
        fixture.reader.modals[Self.sheetWindowNumber] =
            .window(try #require(fixture.host.reference.identity))
        fixture.seat.refreshTargetReadings()
        fixture.seat.refreshTargetReadings()

        // The move lands and the write after it fails, so the surface is
        // somewhere new and the seat has to decide what it owes for it.
        fixture.router.adopting = Self.sheetWindow
        fixture.placing.afterMoveError =
            DisplayFailure.attributeWriteFailed(attribute: "AXPosition", code: .cannotComplete)

        let writesBefore = fixture.placing.moves.count
        await #expect(throws: DisplayFailure.self) {
            try await fixture.seat.adopt(inbound, platform: AppKitPlatform())
        }
        fixture.router.adopting        = nil
        fixture.placing.afterMoveError = nil

        #expect(fixture.placing.moves.count == writesBefore + 1,
                "the adoption's own move, and no second write back to a frame nobody placed")
        #expect(fixture.seat.lastAdoptionFailure?.restoration == .returned)
        #expect(!fixture.seat.hasPendingWindowRestorations)

        // And the window that was really held is still held and still goes home.
        let report = await fixture.seat.releaseAssignment()
        #expect(report.outcome == .released)
        #expect(report.windows[fixture.host.id] == .returned)
        #expect(fixture.sensing.geometry?.frame == FakeGeometry.userSeatWindow.frame)
    }

    @Test("an adoption whose rollback is owed loses no window and stays an obligation")
    func anOwedRollbackIsNotLost() async throws {

        let fixture = try await Self.fixture(marker: 2_110)

        // Asked for at its User Seat frame while the window server already shows
        // it on the display, so the rollback has a real distance to write.
        let inbound = FakeGeometry.reference(
            frame       : CGRect(x: 300, y: 400, width: 320, height: 240),
            windowNumber: Self.secondWindowNumber
        )
        fixture.sensing.additionalWindows[Self.secondWindowNumber] = FakeGeometry.reference(
            frame       : CGRect(x: 1900, y: 600, width: 320, height: 240),
            windowNumber: Self.secondWindowNumber
        )
        fixture.placing.moveError = DisplayFailure.attributeNotSettable("AXPosition")

        await #expect(throws: DisplayFailure.self) {
            try await fixture.seat.adopt(inbound, platform: AppKitPlatform())
        }
        #expect(fixture.seat.hasPendingWindowRestorations)
        #expect(fixture.seat.lastAdoptionFailure?.restoration == .refused)

        let report = await fixture.seat.releaseAssignment()

        #expect(report.outcome == .released)
        #expect(report.windows[Self.secondWindowNumber] == .refused)
        let owed = try #require(
            report.obligations.first { $0.windowNumber == Self.secondWindowNumber }
        )
        #expect(owed.identity == inbound.identity)
        #expect(owed.owedFrame == inbound.frame)
        #expect(owed.reason == .restorationOwed)
        #expect(fixture.seat.hasPendingWindowRestorations,
                "the rollback stays owed rather than being dropped with the assignment")
    }
}
