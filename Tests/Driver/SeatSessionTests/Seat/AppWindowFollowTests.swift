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
        baseline: [WindowSurface] = [],
        reader  : ControlledSurfaceReader? = nil
    ) async throws -> (seat: AgentSeat, adopted: AdoptedWindow) {

        let seat = makeSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : marker,
            reader : reader
        )
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
        ProcessKeepAlive.start()
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
        ProcessKeepAlive.start()
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

    /// The windows the seat adopted without taking the target, each with the
    /// target it left where it was.
    static func heldWithoutTarget(_ log: MultiWindowTests.EventLog) -> [(Int, Int?)] {
        log.events.compactMap {
            guard case .windowAdoptedNotTargeted(let window, let target) = $0 else { return nil }
            return (window.windowNumber, target)
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
        #expect(seat.targetHistory == [first.id])
        let brought = try #require(
            seat.adoptedWindows.first { $0.id == Self.secondWindowNumber }
        )
        #expect(sensing.virtualDisplayBounds.contains(brought.reference.frame))

        // The seat's own default is Chromium and the window it already holds
        // was adopted as AppKit, so this says which of the two was read.
        #expect(seat.session[Self.secondWindowNumber]?.platform is AppKitPlatform,
                "a transferred window is driven as the application it belongs to, not as the default")

        await log.drain()
        #expect(Self.heldWithoutTarget(log).map(\.0) == [Self.secondWindowNumber],
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
        let brought = try #require(
            seat.adoptedWindows.first { $0.id == Self.secondWindowNumber }
        )
        #expect(sensing.virtualDisplayBounds.contains(brought.reference.frame),
                "and it is brought onto the seat's own display")
    }

    @Test("a window born on the virtual display is adopted where it stands and can be given back")
    func aWindowBornInsideTheSeatIsAdoptedWithoutAMove() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(sensing: sensing, placing: placing)
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // macOS opens a new window where the application's active one is, and
        // that one is the window the agent is working in, inside the seat.
        let born = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: CGRect(
                x     : FakeGeometry.virtual.minX + 300,
                y     : FakeGeometry.virtual.minY + 200,
                width : 700,
                height: 500
            )
        )
        let movesBefore = placing.moves.count
        await Self.pass(seat)

        #expect(placing.moves.count == movesBefore,
                "a window already in the seat needs no move and must not be given one")
        #expect(seat.adoptedWindows.map(\.id).contains(born.windowNumber),
                "and it is an Adopted Window, which is what a consumer's release loop iterates")
        #expect(seat.session[born.windowNumber]?.platform is AppKitPlatform,
                "and it is driven as its own application, the same as the window it was opened from")

        await log.drain()
        #expect(Self.refusals(log).isEmpty)

        let adopted = try #require(seat.adoptedWindows.first { $0.id == born.windowNumber })
        let outcome = await seat.release(adopted)
        #expect(outcome == .returned)
        #expect(!seat.adoptedWindows.map(\.id).contains(born.windowNumber))

        // And a released window is not taken again by the next pass: the
        // inventory still agrees with the frame it is standing at.
        await Self.pass(seat)
        #expect(!seat.adoptedWindows.map(\.id).contains(born.windowNumber),
                "an owner that gave a window back must not take it straight back")
    }

    @Test("a born-in-seat modal can settle at a new AX-attested size without a resize request")
    func resizedBornModalIsTakenAtItsSettledSize() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(sensing: sensing, placing: placing)
        let initial = CGRect(x: FakeGeometry.virtual.minX + 300, y: FakeGeometry.virtual.minY + 200,
                             width: 552, height: 300)
        let settled = CGRect(origin: initial.origin, size: CGSize(width: 260, height: 276))
        let born = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: initial)
        let movesBefore = placing.moves.count
        let stagesBefore = placing.stages
        placing.stageError = NoWindowElement.refused
        placing.resizeError = NoWindowElement.refused
        sensing.windowGeometryOverride = { number in
            if number == born.windowNumber, seat.state == .starting {
                placing.bodyFrames[number] = settled
                sensing.additionalWindows[number] = born.replacingFrame(settled)
                return sensing.additionalWindows[number]
            }
            return number == FakeGeometry.windowNumber ? sensing.geometry : sensing.additionalWindows[number]
        }
        defer { sensing.windowGeometryOverride = nil }

        await Self.pass(seat)

        let adopted = try #require(seat.adoptedWindows.first { $0.id == born.windowNumber })
        #expect(adopted.reference.frame == settled)
        #expect(seat.session[born.windowNumber]?.operationalSize == settled.size)
        #expect(seat.isStaged(adopted))
        #expect(seat.state == .ready)
        #expect(placing.moves.count == movesBefore && placing.stages == stagesBefore)
        #expect(placing.resizes.isEmpty)
        #expect(sensing.windowGeometry(of: born.windowNumber)?.frame == settled)
        #expect(adopted.originalFrame == settled,
                "the seat wrote no size and must retain the window's settled body")
        let returned = await seat.release(adopted)
        #expect(returned == .returned)
        #expect(placing.moves.count == movesBefore && placing.resizes.isEmpty)
    }

    @Test("a small born-in-seat server frame without matching AX body remains a thumbnail")
    func bornThumbnailStillNeedsItsFullBody() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _) = try await Self.followingSeat(sensing: sensing, placing: placing)
        let initial = CGRect(x: FakeGeometry.virtual.minX + 300, y: FakeGeometry.virtual.minY + 200,
                             width: 700, height: 500)
        let thumbnail = CGRect(origin: initial.origin, size: CGSize(width: 140, height: 100))
        let born = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: initial)
        var restoredFullBody = false
        placing.onStage = { restoredFullBody = true }
        sensing.windowGeometryOverride = { number in
            if number == born.windowNumber, seat.state == .starting, !restoredFullBody {
                return born.replacingFrame(thumbnail)
            }
            return number == FakeGeometry.windowNumber ? sensing.geometry : sensing.additionalWindows[number]
        }
        defer { sensing.windowGeometryOverride = nil }

        await Self.pass(seat)

        let adopted = try #require(seat.adoptedWindows.first { $0.id == born.windowNumber })
        #expect(restoredFullBody)
        #expect(adopted.reference.frame == initial)
        #expect(seat.session[born.windowNumber]?.operationalSize == initial.size)
        #expect(seat.isStaged(adopted))
        #expect(seat.state == .ready)
    }

    @Test("a stable thumbnail after staging does not confirm adoption")
    func aThumbnailAfterStagingRemainsUnconfirmed() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(sensing: sensing, placing: placing)
        let initial = CGRect(x: FakeGeometry.virtual.minX + 300, y: FakeGeometry.virtual.minY + 200,
                             width: 700, height: 500)
        let thumbnail = CGRect(origin: initial.origin, size: CGSize(width: 140, height: 100))
        let born = Self.offer(Self.secondWindowNumber, to: sensing, placing, frame: initial)
        let stagesBefore = placing.stages
        sensing.windowGeometryOverride = { number in
            if number == born.windowNumber, seat.state == .starting {
                return born.replacingFrame(thumbnail)
            }
            return number == FakeGeometry.windowNumber ? sensing.geometry : sensing.additionalWindows[number]
        }
        defer { sensing.windowGeometryOverride = nil }

        await Self.pass(seat)

        #expect(placing.stages == stagesBefore + 1)
        #expect(seat.adoptedWindows.map(\.id) == [first.id])
        #expect(seat.session[born.windowNumber] == nil)
        #expect(seat.currentTarget?.id == first.id)
    }

    @Test("observation settles an outside popup through the owned transfer path")
    func observationSettlesOutsidePopup() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, first) = try await Self.followingSeat(
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
        #expect(seat.currentTarget?.id == first.id,
                "the popup is settled and held, and the target stays where it was")
        #expect(delivery.reference.recipient.windowNumber == first.id)
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

    // MARK: A window the application already had open

    /// Where the assigned application's second window stands on the person's
    /// display when the seat takes the application over. The size is the New
    /// Project dialog DaVinci Resolve left open after a crash, measured live,
    /// and it is away from the frame the first window was found at.
    static let leftOpenFrame = CGRect(x: 300, y: 200, width: 520, height: 197)

    /// A seat handed an application that already had a second window open
    /// outside the virtual display, with `beside` standing next to it.
    ///
    /// Every one of them is readable before the first adoption, so the handover
    /// reading carries them: the assignment nucleus records the application's
    /// own window as a pre-existing member, and a following seat has all of
    /// them in its baseline. That second fact is why the follower, which only
    /// takes windows that appear later, is not the one that can take it in.
    static func seatWithWindowLeftOpen(
        sensing  : FakeSensing,
        placing  : FakePlacing,
        following: Bool,
        marker   : Int64,
        beside   : [WindowReference] = []
    ) async throws -> (seat: AgentSeat, adopted: AdoptedWindow, leftOpen: WindowReference) {

        let leftOpen = reference(secondWindowNumber, frame: leftOpenFrame)
        for window in [leftOpen] + beside {
            sensing.additionalWindows[window.windowNumber] = window
            placing.bodyFrames[window.windowNumber]        = window.frame
        }

        let seat   : AgentSeat
        let adopted: AdoptedWindow
        if following {
            (seat, adopted) = try await followingSeat(
                sensing : sensing,
                placing : placing,
                marker  : marker,
                baseline: ([leftOpen] + beside).map { surface($0) }
            )
        } else {
            seat    = makeSeat(sensing: sensing, placing: placing, marker: marker)
            adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        }

        // Linked only now, so the first adoption's own move leaves it alone.
        // The body moves with the window, which is what the return reads first.
        placing.onMove = { origin in
            let moved = reference(
                secondWindowNumber,
                frame: CGRect(origin: origin, size: leftOpenFrame.size)
            )
            sensing.additionalWindows[secondWindowNumber] = moved
            placing.bodyFrames[secondWindowNumber]        = moved.frame
            sensing.surfaces = sensing.surfaces?.map { current in
                current.reference.windowNumber == secondWindowNumber ? surface(moved) : current
            }
        }
        return (seat, adopted, leftOpen)
    }

    @Test(
        "a window the application already had open outside the seat is taken in at the first observation",
        arguments: [true, false]
    )
    func aWindowLeftOpenIsTakenInAtTheFirstObservation(following: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first, leftOpen) = try await Self.seatWithWindowLeftOpen(
            sensing  : sensing,
            placing  : placing,
            following: following,
            marker   : following ? 7_040 : 7_041
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        let member = try #require(seat.assignmentKit.inventory.surfaces[leftOpen.windowNumber])
        #expect(member.origin == .preexisting,
                "the handover reading makes it a window the seat was entrusted with")
        let movesBefore = placing.moves.count

        let delivery = try await observe(seat)

        #expect(delivery.reference.recipient.windowNumber == first.id)
        #expect(seat.currentTarget?.id == first.id,
                "the window taken in is held, and the target stays where it was")
        let taken = try #require(seat.adoptedWindows.first { $0.id == leftOpen.windowNumber })
        #expect(sensing.virtualDisplayBounds.contains(taken.reference.frame))
        #expect(placing.moves.count == movesBefore + 1, "one move, the one that took it in")
        #expect(taken.originalFrame == leftOpen.frame, "and it still owes the frame it was found at")

        await log.drain()
        #expect(Self.refusals(log).isEmpty)
        #expect(Self.heldWithoutTarget(log).map(\.0) == [leftOpen.windowNumber])

        let outcome = await seat.release(taken)
        #expect(outcome == .returned)
        #expect(sensing.additionalWindows[leftOpen.windowNumber]?.frame == leftOpen.frame,
                "a window the person already had open goes back where it was")
    }

    @Test("a front-order change caused by taking in a preexisting window does not replace the requested target")
    func containingAPreexistingWindowDoesNotRedirectTheFirstObservation() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let leftOpen = Self.reference(Self.secondWindowNumber, frame: Self.leftOpenFrame)
        sensing.additionalWindows[leftOpen.windowNumber] = leftOpen
        placing.bodyFrames[leftOpen.windowNumber] = leftOpen.frame
        let (seat, first) = try await Self.followingSeat(
            sensing : sensing,
            placing : placing,
            marker  : 7_049,
            baseline: [Self.surface(leftOpen)],
            reader  : reader
        )
        defer { seat.stopWindowFollowing() }
        let identity = try #require(leftOpen.identity)
        placing.onMove = { origin in
            let moved = leftOpen.replacingFrame(CGRect(origin: origin, size: leftOpen.frame.size))
            sensing.additionalWindows[leftOpen.windowNumber] = moved
            placing.bodyFrames[leftOpen.windowNumber] = moved.frame
            reader.recencyReadings = [[RecencyClaim(
                surface              : identity,
                signal               : .returnedToFront,
                provenance           : .qualifiedFrontOrderAttestation,
                origin               : .application(provenance: .qualifiedRaiseAttribution),
                observedAtNanoseconds: 100
            )], []]
        }

        let opening = try await observe(seat)
        #expect(opening.reference.recipient == first.reference.identity)
        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.adoptedWindows.contains { $0.reference.identity == identity })
        #expect(placing.stagedWindows.last == first.id,
                "Containment must not leave another held window above the selected window's hit test")

        // A later application raise of the same window is still a real selection change.
        reader.recency = [RecencyClaim(
            surface              : identity,
            signal               : .returnedToFront,
            provenance           : .qualifiedFrontOrderAttestation,
            origin               : .application(provenance: .qualifiedRaiseAttribution),
            observedAtNanoseconds: 200
        )]
        let later = try await observe(seat)
        #expect(later.reference.recipient == identity)
        #expect(seat.currentTarget?.id == leftOpen.windowNumber)
    }

    @Test("a failed staging after containing another window returns no observation")
    func containmentCannotPublishBeforeTheSelectedWindowIsRestaged() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let leftOpen = Self.reference(Self.secondWindowNumber, frame: Self.leftOpenFrame)
        sensing.additionalWindows[leftOpen.windowNumber] = leftOpen
        placing.bodyFrames[leftOpen.windowNumber] = leftOpen.frame
        let (seat, first) = try await Self.followingSeat(
            sensing : sensing,
            placing : placing,
            marker  : 7_050,
            baseline: [Self.surface(leftOpen)],
            reader  : reader
        )
        defer { seat.stopWindowFollowing() }
        placing.onMove = { origin in
            let moved = leftOpen.replacingFrame(CGRect(origin: origin, size: leftOpen.frame.size))
            sensing.additionalWindows[leftOpen.windowNumber] = moved
            placing.bodyFrames[leftOpen.windowNumber] = moved.frame
        }
        placing.stageError = CancellationError()

        let opening = await seat.observe()
        guard case .failure(.captureFailed(let reason)) = opening else {
            Issue.record("A failed restoration of the selected window must refuse its observation")
            return
        }
        #expect(reason.contains("after containment"))
        #expect(placing.stagedWindows.last == first.id)
        #expect(!seat.coherentState.hasCurrentObservation)
    }

    @Test("a window of another process left open beside it is still left alone")
    func aStrangersWindowLeftOpenIsLeftAlone() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()

        // Another process behind the driven PID, and another application.
        let reused = Self.reference(
            Self.thirdWindowNumber,
            frame   : CGRect(x: 40, y: 500, width: 400, height: 300),
            lifetime: 9
        )
        let stranger = Self.reference(
            780,
            frame    : CGRect(x: 600, y: 420, width: 400, height: 300),
            processID: FakeGeometry.userPID
        )
        let (seat, first, leftOpen) = try await Self.seatWithWindowLeftOpen(
            sensing  : sensing,
            placing  : placing,
            following: true,
            marker   : 7_042,
            beside   : [reused, stranger]
        )
        let movesBefore = placing.moves.count

        _ = try await observe(seat)

        #expect(seat.assignmentKit.inventory.surfaces[reused.windowNumber] == nil)
        #expect(seat.assignmentKit.inventory.surfaces[stranger.windowNumber] == nil)
        #expect(seat.adoptedWindows.map(\.id).sorted() == [first.id, leftOpen.windowNumber])
        #expect(placing.moves.count == movesBefore + 1, "only the application's own window is moved")
        #expect(sensing.additionalWindows[reused.windowNumber] == reused)
        #expect(sensing.additionalWindows[stranger.windowNumber] == stranger)
    }

    @Test("a window left open that cannot be moved is refused, and the seat stays suspended")
    func aWindowLeftOpenThatCannotBeMovedIsRefused() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _, leftOpen) = try await Self.seatWithWindowLeftOpen(
            sensing  : sensing,
            placing  : placing,
            following: true,
            marker   : 7_043
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        placing.frameError = NoWindowElement.refused
        let movesBefore = placing.moves.count
        seat.refreshTargetReadings()
        let outcome = await seat.observe()

        guard case .failure(.suspended) = outcome else {
            Issue.record("the observation was not refused: \(outcome)")
            return
        }
        #expect(placing.moves.count == movesBefore, "nothing is written for a surface that cannot take it")
        #expect(!seat.adoptedWindows.map(\.id).contains(leftOpen.windowNumber))
        await log.drain()
        #expect(Self.refusals(log).map(\.0) == [leftOpen.windowNumber])
        #expect(Self.refusals(log).first?.1 == .notMovable)
    }

    @Test("a window left open is not moved while the person's own physical intent is recent")
    func aWindowLeftOpenWaitsForThePerson() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, _, leftOpen) = try await Self.seatWithWindowLeftOpen(
            sensing  : sensing,
            placing  : placing,
            following: true,
            marker   : 7_044
        )

        sensing.userMayBeSwitchingApplications = true
        let movesBefore = placing.moves.count
        seat.refreshTargetReadings()
        let outcome = await seat.observe()

        guard case .failure(.suspended) = outcome else {
            Issue.record("the observation was not refused: \(outcome)")
            return
        }
        #expect(placing.moves.count == movesBefore, "the follower's own stand-down holds this path too")
        #expect(!seat.adoptedWindows.map(\.id).contains(leftOpen.windowNumber))

        sensing.userMayBeSwitchingApplications = false
        _ = try await observe(seat)
        #expect(seat.adoptedWindows.map(\.id).contains(leftOpen.windowNumber),
                "and it is taken in once the person's intent is no longer recent")
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

        // What Stage Manager publishes to the window server, one of the sizes it
        // was measured at (90 by 97, and 120 by 121 elsewhere), against the body
        // the window itself still reports.
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

    /// Measured with DaVinci Resolve: "Create" in its New Project dialog hides
    /// the Project Manager, the target, and opens the project's window. The
    /// hidden window left every list the seat reads, and the seat answered it
    /// as unreadable, which failed the seat on the click it had just posted.
    @Test("an operating target its application ordered out starts no recovery, and one destroyed still does")
    func anOrderedOutTargetStartsNoRecovery() async throws {
        for isOrderedOut in [true, false] {
            let sensing = FakeSensing()
            let placing = FakePlacing()
            let (seat, _) = try await Self.followingSeat(
                sensing: sensing,
                placing: placing,
                marker : isOrderedOut ? 7_041 : 7_042
            )

            sensing.geometry   = nil
            sensing.surfaces   = []
            sensing.orderedOut = isOrderedOut ? [FakeGeometry.windowNumber] : []
            await Self.pass(seat)

            if isOrderedOut {
                #expect(seat.state == .ready, "a hidden window is the selection's to answer, not the recovery's")
            } else {
                #expect(seat.state == .recovering)
            }
        }
    }

    /// The rest of the same sequence: the application withdraws the hidden
    /// Project Manager, and the project's window, adopted beside it, is what
    /// the seat works in from then on.
    @Test("a hidden target the application withdrew hands the target and its guard to the window left open")
    func aWithdrawnTargetHandsOverToTheHeldWindow() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_043,
            reader : reader
        )
        let project = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)
        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.adoptedWindows.map(\.id).contains(project.windowNumber))

        sensing.geometry   = nil
        sensing.surfaces   = sensing.surfaces?.filter { $0.reference.windowNumber != first.id }
        sensing.orderedOut = [first.id]
        reader.withdrawn   = [try #require(first.reference.identity)]
        await Self.pass(seat)
        seat.refreshTargetReadings()

        #expect(seat.state == .ready)
        #expect(seat.currentTarget?.id == project.windowNumber)
        #expect(seat.seatGuard?.target.windowNumber == project.windowNumber)
        let turn        = try await seat.acquire()
        let observation = try await observedReference(seat)
        let frame       = try #require(sensing.additionalWindows[project.windowNumber]).frame
        let click       = InputCommand.click(InputLocation(
            screenPoint       : CGPoint(x: frame.midX, y: frame.midY),
            windowPointFromTop: CGPoint(x: frame.width / 2, y: frame.height / 2)
        ))
        let receipt     = try await seat.send(click, observation: observation, turn: turn)
        #expect(sender.sent.count == 1)
        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)
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

    // MARK: The two suspensions of a focus recovery

    /// The person's window, on the physical display and outside the virtual
    /// bounds, which is what makes it a destination a recovery may restore to.
    static let userWindow = FakeGeometry.reference(
        frame       : CGRect(x: 100, y: 100, width: 600, height: 500),
        processID   : FakeGeometry.userPID,
        windowNumber: 801
    )

    /// A real recovery paused on a request that went out and came back with
    /// code 0, reading a clock the row moves by hand: the only way to sit in the
    /// state where something is genuinely in flight, and to leave it 250 ms
    /// later without a row that waits 250 ms and flakes under contention.
    static func restoringRecovery(
        _ sensing: FakeSensing,
        _ gate   : InputCommandGate,
        now      : @escaping () -> UInt64
    ) async throws -> UserFocusRecovery {

        sensing.additionalWindows[userWindow.windowNumber] = userWindow
        sensing.focusedUserWindow     = userWindow
        sensing.frontmostProcessID    = FakeGeometry.userPID
        sensing.focusRecoverySnapshot = FocusRecoverySnapshot(
            topologyIsValid: true,
            virtualBounds  : FakeGeometry.virtual,
            physicalBounds : [FakeGeometry.physical],
            windows        : [userWindow, FakeGeometry.adoptedWindow]
        )
        let recovery = UserFocusRecovery(
            sensing: sensing,
            gate   : gate,
            adopted: { [FakeGeometry.adoptedWindow] },
            restore: { _ in 0 },
            now    : now,
            changed: { _ in }
        )
        recovery.beginHold()
        try await recovery.prepareBeforeAction()
        sensing.frontmostProcessID = FakeGeometry.targetPID
        recovery.activationChanged(to: FakeGeometry.targetPID)
        return recovery
    }

    @Test("a request in flight freezes the follower, and the 250 ms that ends it unfreezes it")
    func onlyAnUnverifiedRequestFreezesTheFollower() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_020
        )
        var clock: UInt64 = 1_000_000_000
        let recovery = try await Self.restoringRecovery(sensing, sender.gate, now: { clock })
        defer { recovery.stop() }
        seat.focusRecovery = recovery
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)

        // The request went out and the two agreeing readings are still owed:
        // nothing may read or move a window underneath it, by either path.
        #expect(recovery.isRestoring)
        let scansBefore = seat.windowFollowScanCount
        await Self.pass(seat, 3)
        seat.heartbeat()
        await Self.pause(0.3)
        #expect(seat.windowFollowScanCount == scansBefore,
                "neither the pass nor the heartbeat reads while a request is unverified")
        #expect(seat.adoptedWindows.count == 1)
        #expect(sender.gate.isPaused)

        // The 250 ms passed with no verification. Nothing is in flight, the
        // episode is still open, and the person may not be at the keyboard.
        clock += UserFocusRecovery.verificationWindowNanoseconds
        #expect(recovery.isPaused, "the gate's own reading is unchanged")
        #expect(!recovery.isRestoring)
        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2,
                "the window the application opened is brought in while the seat waits")

        // The input stop is the same stop it was, throughout both states.
        #expect(sender.gate.isPaused)
        #expect(sender.gate.pauseCauses == [.focusRecovery])
    }

    @Test("a recovery that asked for nothing leaves the follower running, heartbeat included")
    func waitingForTheUserLeavesTheFollowerRunning() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_021
        )
        let recovery = UserFocusRecovery(
            sensing: sensing,
            gate   : sender.gate,
            adopted: { [FakeGeometry.adoptedWindow] },
            restore: { _ in 0 },
            changed: { _ in }
        )
        defer { recovery.stop() }
        seat.focusRecovery = recovery

        // The dialog the application raised between Turns: the activation
        // reaches a recovery with nothing prepared, so no request is made.
        sensing.frontmostProcessID = FakeGeometry.targetPID
        recovery.activationChanged(to: FakeGeometry.targetPID)
        #expect(recovery.isPaused)
        #expect(!recovery.isRestoring, "no request was made, so none is in flight")
        #expect(sender.gate.isPaused, "and the input stop is closed all the same")

        // The wake-up path on its own, with no pass driven by hand: the beat
        // used to return before it and freeze the follower independently.
        _ = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        let scansBefore = seat.windowFollowScanCount
        seat.heartbeat()
        #expect(await Self.settle { seat.windowFollowScanCount > scansBefore },
                "the beat used to return before the follow and freeze it independently")

        // The transfer itself is driven, the way every row in this suite drives
        // it: a scheduled burst is a wake-up and never a deterministic outcome.
        await Self.pass(seat)
        #expect(seat.adoptedWindows.count == 2)
        #expect(sender.gate.pauseCauses == [.focusRecovery],
                "moving a window never reopened input, and still does not")
    }

    // MARK: A detection is a hold, and the nucleus decides the target

    /// The auxiliary surface of the live failure, measured at 33 by 10 points,
    /// born inside the seat while the agent was working in the real window.
    static let auxiliaryFrame = CGRect(
        x     : FakeGeometry.virtual.minX + 300,
        y     : FakeGeometry.virtual.minY + 200,
        width : 33,
        height: 10
    )

    @Test("a detected surface the nucleus refuses is held, and the target keeps its observation")
    func aRefusedDetectedSurfaceIsHeldAndNotTargeted() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_030,
            reader : reader
        )
        let reference = try await observedReference(seat)
        let log       = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // What the driven application opened inside the seat: a surface nobody
        // operates, which the selection nucleus refuses as a target.
        reader.roles[Self.secondWindowNumber] = .tooltip
        let auxiliary = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: Self.auxiliaryFrame
        )
        await Self.pass(seat)

        #expect(seat.adoptedWindows.map(\.id).contains(auxiliary.windowNumber),
                "the surface is held, so the release loop and the handback still own it")
        #expect(seat.currentTarget?.id == first.id,
                "and the operating target stays where the consumer left it")

        await log.drain()
        #expect(!log.targetChanges.contains { $0.to == auxiliary.windowNumber })

        let admitted = try seat.admitOrdinary(reference)
        #expect(admitted.id == first.id,
                "the observation the agent is holding outlives a detection it never asked for")
    }

    @Test("a detected surface with no role at all is held, and the target keeps its observation")
    func aSurfaceWithoutARoleIsHeldAndNotTargeted() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_033,
            reader : reader
        )
        let reference = try await observedReference(seat)
        let log       = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // The live failure, in the form the reader now answers it with: Finder's
        // empty 66 by 20 AXDialog produces no role claim at all.
        reader.rolesNotRead.insert(Self.secondWindowNumber)
        let auxiliary = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: Self.auxiliaryFrame
        )
        await Self.pass(seat)

        #expect(seat.adoptedWindows.map(\.id).contains(auxiliary.windowNumber),
                "a surface with no role is still held, like one whose role is refused")
        #expect(seat.currentTarget?.id == first.id,
                "and the operating target stays where the consumer left it")

        await log.drain()
        #expect(!log.targetChanges.contains { $0.to == auxiliary.windowNumber })

        let admitted = try seat.admitOrdinary(reference)
        #expect(admitted.id == first.id,
                "the observation taken before the detection outlives it")
    }

    @Test("a detected window the nucleus would select is held, and the target still does not move")
    func anEligibleDetectedWindowDoesNotTakeTheTarget() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_031,
            reader : ControlledSurfaceReader(sensing: sensing)
        )
        let observation = try await observedReference(seat)
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        // The traffic light overlay's situation exactly: a surface the reader
        // answers a selectable role for, born while the agent is working.
        let window = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)

        #expect(seat.adoptedWindows.map(\.id).contains(window.windowNumber),
                "it is held, so the release loop and the handback still own it")
        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.targetHistory == [first.id])

        await log.drain()
        #expect(!log.targetChanges.contains { $0.to == window.windowNumber },
                "the seat never moves the target by itself")

        // And the consumer hears about the window anyway, or multi window
        // support would be useless rather than safe.
        let held = Self.heldWithoutTarget(log)
        #expect(held.count == 1)
        #expect(held.first?.0 == window.windowNumber)
        #expect(held.first?.1 == first.id)

        let admitted = try seat.admitOrdinary(observation)
        #expect(admitted.id == first.id,
                "the observation the agent is holding outlives a detection it never asked for")
    }

    @Test("a held surface that becomes a candidate later still does not take the target")
    func aHeldSurfaceDoesNotTakeTheTargetWhenItQualifies() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_032,
            reader : reader
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        reader.roles[Self.secondWindowNumber] = .tooltip
        let auxiliary = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: Self.auxiliaryFrame
        )
        await Self.pass(seat)
        #expect(seat.currentTarget?.id == first.id)

        // The back door: a qualified recency drops the standing choice inside
        // the nucleus, and the fold that follows it would move the target.
        reader.roles[Self.secondWindowNumber] = .dialog
        reader.recency = [RecencyClaim(
            surface              : try #require(auxiliary.identity),
            signal               : .returnedToFront,
            provenance           : .qualifiedFrontOrderAttestation,
            origin               : .application(provenance: .qualifiedRaiseAttribution),
            observedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )]
        seat.refreshTargetReadings()

        #expect(seat.currentTarget?.id == first.id,
                "the window the consumer is working in is still the one the seat operates")
        #expect(seat.seatGuard?.target.hasSameIdentity(as: first.reference) == true)
        await log.drain()
        #expect(!log.targetChanges.contains { $0.to == auxiliary.windowNumber })
    }

    @Test("the seat follows the nucleus only where its own target stopped qualifying")
    func theSeatFollowsTheNucleusWhenItsTargetIsGone() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_037,
            reader : reader
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        let window = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)
        #expect(seat.currentTarget?.id == first.id)

        // The one move the seat still makes on its own: the window it was
        // operating is minimised, so the nucleus would not select it any more.
        reader.visibilities[first.id] = .minimisedEstablished
        seat.refreshTargetReadings()

        #expect(seat.currentTarget?.id == window.windowNumber)
        await log.drain()
        let change = try #require(log.targetChanges.last)
        #expect(change.to == window.windowNumber)
        #expect(change.from == first.id)
        #expect(change.reason == .detected)
    }

    @Test("the consumer moves the target onto a held detected window with switchTarget")
    func switchTargetMovesOntoADetectedWindow() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_038,
            reader : ControlledSurfaceReader(sensing: sensing)
        )
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }

        let window = Self.offer(Self.secondWindowNumber, to: sensing, placing)
        await Self.pass(seat)
        #expect(seat.currentTarget?.id == first.id)

        let held = try #require(seat.adoptedWindows.first { $0.id == window.windowNumber })
        _ = try await seat.switchTarget(to: held)

        #expect(seat.currentTarget?.id == window.windowNumber)
        await log.drain()
        let change = try #require(log.targetChanges.last)
        #expect(change.to == window.windowNumber)
        #expect(change.from == first.id)
        #expect(change.reason == .requested,
                "the consumer asked for it, which is the whole difference")
    }

    // MARK: A surface that goes away, and whose observation goes with it

    /// Takes a window off the fake window server the way a destruction does:
    /// no row for its Window ID anywhere, and the positive proof of closure a
    /// pass reports for an identity it named in its own request.
    static func destroy(
        _ identity: WindowIdentity,
        in sensing: FakeSensing,
        _ reader  : ControlledSurfaceReader
    ) {
        sensing.additionalWindows[identity.windowNumber] = nil
        sensing.surfaces = sensing.surfaces?.filter {
            $0.reference.windowNumber != identity.windowNumber
        }
        reader.destroyed = [identity]
    }

    @Test("a held surface destroyed under the agent leaves the target's observation alone")
    func aDestroyedHeldSurfaceKeepsTheTargetsObservation() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            marker : 7_034,
            reader : reader
        )

        // The live failure's surface: Finder publishes it whenever a window of
        // its is raised, no role is read for it, and it is gone under a second.
        reader.rolesNotRead.insert(Self.secondWindowNumber)
        let auxiliary = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: Self.auxiliaryFrame
        )
        await Self.pass(seat)
        #expect(seat.currentTarget?.id == first.id)

        let observation = try await observedReference(seat)
        Self.destroy(try #require(auxiliary.identity), in: sensing, reader)
        seat.refreshTargetReadings()

        #expect(seat.coherentState.hasCurrentObservation,
                "another window's destruction is not this window's target change")

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, observation: observation, turn: turn)
        #expect(sender.sent.count == 1,
                "the agent's Command on the window it is working in is admitted")
        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)
    }

    @Test("the observed window going away does end its observation")
    func theObservedWindowGoingAwayEndsItsObservation() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_035,
            reader : reader
        )
        _ = try await observedReference(seat)
        #expect(seat.coherentState.hasCurrentObservation)

        // The application stops scoping the very window the observation is of,
        // which is the closure the scoping must never stop ending.
        reader.withdrawn = [try #require(first.reference.identity)]
        seat.refreshTargetReadings()

        #expect(!seat.coherentState.hasCurrentObservation)
        #expect(seat.coherentState.lastInvalidation == .targetChanged)
    }

    @Test("releasing a window nobody is observing leaves the target's observation alone")
    func releasingAnUnobservedWindowKeepsTheObservation() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader  = ControlledSurfaceReader(sensing: sensing)
        let (seat, first) = try await Self.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_036,
            reader : reader
        )
        reader.roles[Self.secondWindowNumber] = .tooltip
        let auxiliary = Self.offer(
            Self.secondWindowNumber,
            to   : sensing,
            placing,
            frame: Self.auxiliaryFrame
        )
        await Self.pass(seat)

        let observation = try await observedReference(seat)
        let held = try #require(seat.adoptedWindows.first { $0.id == auxiliary.windowNumber })
        let outcome = await seat.release(held)
        #expect(outcome == .returned)

        let admitted = try seat.admitOrdinary(observation)
        #expect(admitted.id == first.id,
                "a consumer giving back a window it never observed keeps the agent's observation")
    }
}
