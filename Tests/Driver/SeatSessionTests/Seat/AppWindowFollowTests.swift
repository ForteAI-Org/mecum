//
//  AppWindowFollowTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The watch driven through the seat and the three fakes: a window of the
/// driven application appears on a physical display and is brought in, or it is
/// left alone and the seat says why. No display, no window server, no
/// accessibility grant, no window belonging to a person.
///
/// The tier asserts transitions and outcomes and never counts: how many passes
/// a wake-up costs is a measurement and it belongs in `make bench`.
@MainActor
@Suite("Following the application's windows")
struct AppWindowFollowTests {

    static let secondWindowNumber = 778
    static let thirdWindowNumber  = 779

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    /// Where a window of the driven application sits while it is still the
    /// person's: on the physical display, outside the virtual bounds.
    static let physicalFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    static func surface(
        _ reference: WindowReference,
        level      : Int  = 0,
        isVisible  : Bool = true
    ) -> WindowSurface {
        WindowSurface(reference: reference, level: level, isVisible: isVisible)
    }

    static func reference(
        _ windowNumber: Int,
        frame         : CGRect = physicalFrame,
        lifetime      : UInt32 = 1,
        processID     : Int32  = FakeGeometry.targetPID
    ) -> WindowReference {
        FakeGeometry.reference(
            frame       : frame,
            processID   : processID,
            windowNumber: windowNumber,
            lifetime    : lifetime
        )
    }

    /// A seat holding one window on the virtual display and already following.
    /// The baseline is taken by `enableWindowFollowing`, so everything in
    /// `sensing.surfaces` at this point is the person's and must stay there,
    /// and no pass has to run first for that to be true.
    static func followingSeat(
        sensing : FakeSensing,
        placing : FakePlacing,
        sender  : FakeSender = FakeSender(),
        marker  : Int64      = 7_001,
        baseline: [WindowSurface] = []
    ) async throws -> (seat: AgentSeat, adopted: AdoptedWindow) {

        let seat    = makeSeat(sensing: sensing, placing: placing, sender: sender, marker: marker)
        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())

        sensing.surfaces = [surface(FakeGeometry.adoptedWindow)] + baseline
        seat.enableWindowFollowing()
        return (seat, adopted)
    }

    /// Makes a move in the placing fake really move the window in the sensing
    /// fake, which is what lets a transfer be confirmed twice the way the real
    /// one is.
    static func linkMove(
        _ placing   : FakePlacing,
        _ sensing   : FakeSensing,
        windowNumber: Int,
        size        : CGSize
    ) {
        placing.onMove = { origin in
            // The size the window really has now, not the one it had when the
            // row was written: a window the seat shrank arrives at its new size,
            // and the window server reports what it is.
            let current = (placing.bodyFrames[windowNumber] ?? placing.bodyFrame)?.size ?? size
            sensing.additionalWindows[windowNumber] = reference(
                windowNumber,
                frame: CGRect(origin: origin, size: current)
            )
        }
    }

    /// Publishes a candidate: readable by the window server, with an
    /// accessibility body, and on the physical display.
    static func offer(
        _ windowNumber: Int,
        to sensing    : FakeSensing,
        _ placing     : FakePlacing,
        frame         : CGRect = physicalFrame,
        body          : CGRect? = nil,
        level         : Int    = 0,
        isVisible     : Bool   = true,
        lifetime      : UInt32 = 1,
        processID     : Int32  = FakeGeometry.targetPID
    ) -> WindowReference {

        let window = reference(
            windowNumber,
            frame    : frame,
            lifetime : lifetime,
            processID: processID
        )
        sensing.additionalWindows[windowNumber] = window
        placing.bodyFrames[windowNumber]        = body ?? frame
        sensing.surfaces = (sensing.surfaces ?? []) + [surface(window, level: level, isVisible: isVisible)]
        linkMove(placing, sensing, windowNumber: windowNumber, size: (body ?? frame).size)
        return window
    }

    static func settle(
        _ condition   : @MainActor () -> Bool,
        within seconds: Double = 20
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await EventLoopWait.sleep(.milliseconds(30))
        }
        return condition()
    }

    /// Runs the watch's own pass and comes back when it is done.
    ///
    /// Two passes are the default because a candidate is only acted on once two
    /// readings agree on it, so one pass is a sighting and two are a transfer.
    /// Driving the pass instead of scheduling it is what keeps these rows
    /// deterministic: every suite in this tier shares the main actor, and a
    /// wait long enough to survive that contention is long enough to hide a
    /// defect. The wake-ups that schedule a pass have their own rows.
    static func pass(_ seat: AgentSeat, _ times: Int = 2) async {
        for _ in 0..<times { await seat.runWindowFollowPass() }
    }

    /// Lets the seat's own tasks run for a while without waiting for anything
    /// in particular, for a row whose assertion is that nothing happened.
    static func pause(_ seconds: Double = 0.4) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { await EventLoopWait.sleep(.milliseconds(30)) }
    }

    /// The relocator's refusal for a Window ID with no element behind it. It is
    /// this suite's own error because the placement target is not a dependency
    /// of this tier, and what the seat does with it is decided by the throw and
    /// never by the case.
    private enum NoWindowElement: Error { case refused }

    static func refusals(_ log: MultiWindowTests.EventLog) -> [(Int, WindowTransferRefusal)] {
        log.events.compactMap {
            guard case .windowTransferRefused(let windowNumber, _, let reason) = $0 else { return nil }
            return (windowNumber, reason)
        }
    }

    // MARK: A window that arrives

    @Test("a second window of the driven process is found and brought in")
    func newWindowIsTransferred() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(sensing: sensing, placing: placing)
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)

        #expect(seat.adoptedWindows.count == 2)
        #expect(seat.currentTarget?.id == Self.secondWindowNumber)
        #expect(seat.targetHistory == [first.id, Self.secondWindowNumber])
        #expect(sensing.virtualDisplayBounds.contains(
            try #require(seat.currentTarget).reference.frame
        ))

        await log.drain()
        #expect(log.targetChanges.last?.reason == .detected,
                "a window the seat found itself is not a window the consumer asked for")
        #expect(Self.refusals(log).isEmpty)
    }

    @Test("a window opened while the driven application is active is still brought in")
    func activeApplicationDoesNotStandThePassDown() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(sensing: sensing, placing: placing)

        // What a dialog looks like from here: the application opened a window
        // and took the focus doing it. The person did nothing.
        sensing.targetIsActive = true
        sensing.userMayBeSwitchingApplications = false
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)

        #expect(seat.adoptedWindows.count == 2, "the window the application opened is adopted")
        #expect(sensing.virtualDisplayBounds.contains(
            try #require(seat.currentTarget).reference.frame
        ), "and it is brought onto the seat's own display")
    }

    @Test("observation settles an outside popup through the owned transfer path")
    func observationSettlesOutsidePopup() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_002
        )
        let movesBeforePopup = placing.moves.count
        let popup = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        placing.onMove = { origin in
            let moved = Self.reference(
                Self.secondWindowNumber,
                frame: CGRect(origin: origin, size: popup.frame.size)
            )
            sensing.additionalWindows[Self.secondWindowNumber] = moved
            sensing.surfaces = sensing.surfaces?.map { surface in
                surface.reference.windowNumber == Self.secondWindowNumber
                    ? Self.surface(moved)
                    : surface
            }
        }

        // Reproduce the order seen in the Lab: the assignment reader discovers
        // the popup before the asynchronous window follower gets its second
        // agreeing reading. The default assignment effector refuses the direct
        // move, so observation has to join the seat's owned transfer path.
        seat.refreshTargetReadings()
        await Task.yield()
        seat.refreshTargetReadings()

        // A native creation notification may start its own pass precisely when
        // observation yields between the two agreeing reads. Make that burst
        // deterministic: the bridge must join it rather than fold assignment
        // state while its adoption is still awaiting placement confirmation.
        sensing.onSurfaceRead = {
            sensing.onSurfaceRead = nil
            Task { @MainActor in await seat.runWindowFollowPass() }
        }

        let delivery = try await observe(seat)
        #expect(placing.moves.count == movesBeforePopup + 1)
        #expect(seat.adoptedWindows.map(\.id).contains(popup.windowNumber))
        #expect(seat.currentTarget?.id == popup.windowNumber)
        #expect(delivery.reference.recipient.windowNumber == popup.windowNumber)
        #expect(seat.state == .ready)

        let turn = try await seat.acquire()
        #expect(seat.state == .ready)
        let receipt = try await seat.send(
            InputCommand.click(InputLocation(
                screenPoint       : CGPoint(x: 2700, y: 700),
                windowPointFromTop: CGPoint(x: 100, y: 100)
            )),
            observation: delivery.reference,
            turn       : turn
        )
        try seat.confirm(receipt, .observed)
        try seat.release(turn)
        #expect(sender.sent.count == 1,
                "the popup must remain the session target after observation")
    }

    @Test("the boundary of a finished Command is a wake-up, and the Command is not repeated")
    func theCommandBoundaryIsAWakeUp() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_002
        )

        let turn    = try await seat.acquire()
        // The Command is what opens the second window. Publishing it before the
        // observation would correctly close the containment gate: at that point
        // the window already exists and has not yet been transferred.
        sender.onSend = { _ in
            _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        }
        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)

        // No heartbeat is involved: the only wake-up here is the end of the
        // Command, and what it has to produce is a pass this row never drove.
        let scanned = await Self.settle { seat.windowFollowScanCount > 0 }
        #expect(scanned, "the boundary of a finished Command woke nothing")

        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2)
        #expect(sender.sent.count == 1,
                "the Command that opened the window is never posted a second time")
    }

    @Test("a window already on the person's display when the seat started is left alone")
    func aPreexistingWindowIsLeftAlone() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let already = Self.reference(Self.secondWindowNumber)
        let (seat, _) = try await Self.followingSeat(
            sensing : sensing,
            placing : placing,
            marker  : 7_003,
            baseline: [Self.surface(already)]
        )
        sensing.additionalWindows[Self.secondWindowNumber] = already
        placing.bodyFrames[Self.secondWindowNumber]        = already.frame
        let movesBefore = placing.moves.count

        await Self.pass(seat, 4)
        #expect(seat.adoptedWindows.count == 1)
        #expect(placing.moves.count == movesBefore, "a window that was already there is not moved")
    }

    @Test("a window of another application is not transferred")
    func aStrangersWindowIsNotTransferred() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_004
        )

        _ = Self.offer(
            Self.secondWindowNumber,
            to       : sensing,
            placing,
            processID: FakeGeometry.userPID
        )
        await Self.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 1)
    }

    @Test("a PID the system handed out again does not inherit the seat's control")
    func aReusedProcessIDInheritsNothing() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_005
        )

        // The same PID with another process lifetime: a different application
        // that was handed the number the driven one left behind.
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing, lifetime: 9)
        await Self.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 1)
    }

    @Test("a contextual menu of the driven process is recognised and never moved")
    func aContextualMenuIsLeftToItsOwner() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_006
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        _ = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            level: Int(CGWindowLevelForKey(.popUpMenuWindow))
        )
        await Self.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 1)
        await log.drain()
        #expect(Self.refusals(log).isEmpty, "a menu is somebody else's surface, not a refusal")
    }

    // MARK: The explicit outcomes

    @Test("a surface with no accessibility element is reported as not movable")
    func aSurfaceWithNoElement() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_007
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        placing.frameError = NoWindowElement.refused
        let movesBefore = placing.moves.count
        await Self.pass(seat)

        await log.drain()
        #expect(Self.refusals(log).first?.1 == .notMovable)
        #expect(placing.moves.count == movesBefore, "nothing is written for a surface that cannot take it")
        #expect(seat.adoptedWindows.count == 1)
    }

    @Test("a window larger than the virtual display is shrunk to fit and still owes its old size")
    func aWindowTooLargeForTheDisplayIsShrunk() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_008
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // An application that opens its window wider than the seat's display,
        // which is what Resolve does with a project: 2593 points across a 2560
        // point display, measured.
        let bounds = sensing.virtualDisplayBounds
        let huge   = CGRect(x: 0, y: 0, width: bounds.width + 33, height: 760)
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: huge)
        await Self.pass(seat)

        await log.drain()
        #expect(Self.refusals(log).isEmpty, "a window that can be made to fit is not refused")
        #expect(placing.resizes.map(\.size) == [CGSize(width: bounds.width, height: 760)],
                "shrunk in the dimension that did not fit, and only that one")
        #expect(seat.adoptedWindows.count == 2)

        let adopted = try #require(seat.adoptedWindows.first { $0.id == Self.secondWindowNumber })
        #expect(adopted.originalFrame == huge,
                "the person is owed the frame the window had before the seat touched it")
    }

    @Test("a window the seat shrank is given back the size it was found with")
    func aShrunkWindowIsReturnedAtItsOriginalSize() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_019
        )
        let bounds = sensing.virtualDisplayBounds
        let huge   = CGRect(x: 0, y: 0, width: bounds.width + 33, height: 760)
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: huge)
        await Self.pass(seat)
        let adopted = try #require(seat.adoptedWindows.first { $0.id == Self.secondWindowNumber })
        placing.resizes.removeAll()

        _ = await seat.release(adopted, .returnToUserSeat)

        #expect(placing.resizes.map(\.size) == [huge.size],
                "the return writes the size back, once, and it is the size it was found with")
        #expect(placing.moves.last == huge.origin)
    }

    @Test("a window nobody can shrink is refused, and nothing is moved")
    func aWindowThatCannotBeShrunkIsRefused() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_018
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // The write is accepted and the application keeps the size it had,
        // which is the ordinary answer of a window with a minimum size. The
        // reading after the write is what says so.
        let bounds = sensing.virtualDisplayBounds
        let huge   = CGRect(x: 0, y: 0, width: bounds.width + 400, height: 3_000)
        placing.resizeResult = huge.size
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: huge)
        let movesBefore = placing.moves.count
        await Self.pass(seat)

        await log.drain()
        #expect(Self.refusals(log).first?.1 == .tooLarge)
        #expect(placing.moves.count == movesBefore, "a window that does not fit is not moved")
        #expect(seat.adoptedWindows.count == 1)
    }

    @Test("a window that goes away before the move is not adopted and nothing is written")
    func aWindowThatVanishesBeforeTheMove() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_009
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // In the on-screen list the inventory reads, and no longer resolvable
        // when the seat goes to move it: it closed between the two.
        let window = Self.reference(Self.secondWindowNumber)
        sensing.surfaces = [
            Self.surface(FakeGeometry.adoptedWindow),
            Self.surface(window),
        ]
        placing.bodyFrames[Self.secondWindowNumber] = window.frame
        let movesBefore = placing.moves.count

        await Self.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 1)
        #expect(placing.moves.count == movesBefore)
        await log.drain()
        #expect(Self.refusals(log).isEmpty, "a window that is no longer there is not a refusal to report")
    }

    @Test("a stashed window is brought in at its own size and not at its thumbnail's")
    func aStashedWindowKeepsItsRealSize() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_010
        )

        // What Stage Manager publishes to the window server, measured at 90 by
        // 97 points, against the body the window itself still reports.
        let thumbnail = CGRect(x: 40, y: 700, width: 90, height: 97)
        _ = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: thumbnail,
            body : Self.physicalFrame
        )
        await Self.pass(seat)

        #expect(seat.adoptedWindows.count == 2)
        let adopted = try #require(seat.adoptedWindows.first { $0.id == Self.secondWindowNumber })
        #expect(adopted.originalFrame == Self.physicalFrame,
                "the frame to return the window to is its own, never the thumbnail's")
    }

    @Test("an identity that changes during the move adopts nothing and rolls the window back")
    func identityChangeDuringTheMove() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_011
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        let moves = Holder<Int>(0)
        placing.onMove = { origin in
            moves.value += 1
            sensing.additionalWindows[Self.secondWindowNumber] = moves.value == 1
                // The window that answers after the move is not the window that
                // was moved.
                ? Self.reference(
                    Self.secondWindowNumber,
                    frame   : CGRect(origin: origin, size: Self.physicalFrame.size),
                    lifetime: 7
                )
                : Self.reference(Self.secondWindowNumber)
        }
        await Self.pass(seat)

        #expect(seat.lastAdoptionFailure != nil)
        #expect(seat.adoptedWindows.count == 1, "the new identity is never adopted")
        await log.drain()
        #expect(Self.refusals(log).first?.1 == .moveRefused)
    }

    // MARK: Windows the seat already holds

    @Test("a held window that leaves the virtual display is put back")
    func aHeldWindowIsPutBack() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_012
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2)

        // The window the seat is not operating on wandered back onto the
        // physical display, which the person can see.
        _ = try await seat.switchTarget(to: first)
        let home = try #require(sensing.additionalWindows[Self.secondWindowNumber]).frame
        sensing.additionalWindows[Self.secondWindowNumber] = Self.reference(Self.secondWindowNumber)
        sensing.surfaces = [
            Self.surface(FakeGeometry.adoptedWindow),
            Self.surface(Self.reference(Self.secondWindowNumber)),
        ]
        placing.onMove = nil
        let movesBefore = placing.moves.count

        await Self.pass(seat)
        #expect(placing.moves.count > movesBefore)
        #expect(placing.moves.last == home.origin,
                "it goes back to the origin its placement was confirmed at")
    }

    @Test("the operating target that leaves the display goes through the seat's own recovery")
    func theTargetGoesThroughRecovery() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_013
        )

        sensing.geometry = Self.reference(FakeGeometry.windowNumber)
        sensing.surfaces = [Self.surface(Self.reference(FakeGeometry.windowNumber))]
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }
        await Self.pass(seat)

        #expect(seat.state == .recovering,
                "the machinery that answers a window that moved is the one that already exists")

        // The target never spends the watch's transfer budget: the recovery is
        // the seat's safeguard and carries a budget of its own, and a few
        // readings must not be able to switch it off for good.
        await log.drain()
        #expect(Self.refusals(log).isEmpty)
    }

    @Test("an application that keeps putting its window back is given up on")
    func attemptsOnOneWindowAreBounded() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_014
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2)
        _ = try await seat.switchTarget(to: first)

        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // Whatever the seat writes, the application puts the window back.
        sensing.additionalWindows[Self.secondWindowNumber] = Self.reference(Self.secondWindowNumber)
        sensing.surfaces = [
            Self.surface(FakeGeometry.adoptedWindow),
            Self.surface(Self.reference(Self.secondWindowNumber)),
        ]
        placing.onMove = nil
        let movesBefore = placing.moves.count

        await Self.pass(seat, AppWindowInventory.maximumAttempts + 2)
        await log.drain()

        #expect(placing.moves.count - movesBefore <= AppWindowInventory.maximumAttempts,
                "the disagreement ends inside the budget instead of becoming a loop")
        #expect(Self.refusals(log).contains { $0.1 == .attemptsExhausted })
    }

    // MARK: Standing down

    @Test("nothing is read while a Command is in flight")
    func nothingIsReadDuringACommand() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_015
        )
        let turn     = try await seat.acquire()
        let observed = Holder<Int>(-1)

        let observation = try await observedReference(seat)
        let before = seat.windowFollowScanCount
        // Publish the new window only after admission, exactly while the
        // Command that caused it is in flight.
        sender.onSend = { _ in
            _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        }
        sender.onSendWait = {
            await Self.pass(seat, 1)
            observed.value = seat.windowFollowScanCount
        }
        let receipt = try await seat.send(Self.click, observation: observation, turn: turn)

        #expect(observed.value == before, "a pass never reads while a Command is in flight")
        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)
    }

    @Test("nothing is read while the person's own physical intent is recent")
    func nothingIsReadWhileThePersonIsSwitching() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_016
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)

        // The person clicked or used an app-switch shortcut a moment ago. This
        // is the evidence that stands the pass down, and the only one: an
        // application that is merely active is the application's own doing, and
        // it is when it opens the very window this pass exists to find.
        sensing.targetIsActive = true
        sensing.userMayBeSwitchingApplications = true
        let before = sensing.surfaceReadCount
        await Self.pass(seat, 3)
        #expect(sensing.surfaceReadCount == before)
        #expect(seat.adoptedWindows.count == 1)

        // And the person's intent going stale is what lets the watch resume,
        // active application or not.
        sensing.userMayBeSwitchingApplications = false
        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2)
    }

    @Test("a window server that does not answer transfers nothing")
    func aFailedReadingTransfersNothing() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_017
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        sensing.surfaces = nil
        let movesBefore  = placing.moves.count

        await Self.pass(seat, 3)
        #expect(seat.adoptedWindows.count == 1)
        #expect(placing.moves.count == movesBefore)
    }

    // MARK: Giving the control back

    @Test("a teardown leaves no watch reading and no wake-up doing anything")
    func teardownStopsTheWatch() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_018
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)

        _ = await seat.releaseAllWindows(.returnToUserSeat)
        let after = sensing.surfaceReadCount

        // Both halves: a pass driven by hand reads nothing, and a wake-up
        // schedules none at all.
        await Self.pass(seat, 3)
        seat.heartbeat()
        await Self.pause(0.3)
        #expect(sensing.surfaceReadCount == after, "no pass survives the teardown")
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test("a failed seat stops following as well")
    func aFailedSeatStopsFollowing() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_019
        )
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)

        seat.failFromHost([.displayChanged])
        let after = sensing.surfaceReadCount

        await Self.pass(seat, 3)
        seat.heartbeat()
        await Self.pause(0.3)
        #expect(seat.state == .failed)
        #expect(sensing.surfaceReadCount == after)
    }
}
