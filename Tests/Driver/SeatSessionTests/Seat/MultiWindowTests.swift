//
//  MultiWindowTests.swift
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

/// Several adopted windows driven through the three fakes: the current target
/// and how it moves, the stage read back instead of assumed, the two pause
/// causes that overlap, and what happens when the target goes away. No display,
/// no Accessibility grant, no window belonging to a person.
@MainActor
@Suite("Multiple windows")
struct MultiWindowTests {

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    /// The seat's event stream, collected. It is single consumer, so there is
    /// one of these per seat and the test starts it before it acts.
    @MainActor
    final class EventLog {

        private(set) var events: [SeatEvent] = []
        private var reader: Task<Void, Never>?

        init(_ seat: AgentSeat) {
            reader = Task { @MainActor [weak self] in
                for await event in seat.events { self?.events.append(event) }
            }
        }

        /// Lets the reader drain what has already been published. The channel
        /// buffers, so this is a hand off and not a wait on a real event.
        func drain() async {
            for _ in 0..<20 { await Task.yield() }
        }

        /// Waits, without ever turning the event loop, for something the seat
        /// is doing on a task of its own. `EventLoopWait.until` pumps when no
        /// application loop is running, which would hold the main actor the
        /// seat's own recovery needs.
        ///
        /// The window is generous because the recovery budget it waits out is
        /// five seconds of 250 ms sleeps on a main actor this whole tier
        /// shares. It sleeps throughout, so the wait costs nothing but time.
        static func settle(
            until condition: @MainActor () -> Bool,
            within seconds : Double = 60
        ) async -> Bool {
            ProcessKeepAlive.start()
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                await EventLoopWait.sleep(.milliseconds(50))
            }
            return condition()
        }

        func stop() { reader?.cancel(); reader = nil }

        var targetChanges: [(from: Int?, to: Int, reason: SeatTargetChange)] {
            events.compactMap {
                guard case .targetChanged(let from, let to, let reason) = $0 else { return nil }
                return (from, to.windowNumber, reason)
            }
        }

        var refusals: [Int] {
            events.compactMap {
                guard case .targetChangeRefused(let windowNumber, _, _) = $0 else { return nil }
                return windowNumber
            }
        }

        var refusalIssues: [[SeatIssue]] {
            events.compactMap {
                guard case .targetChangeRefused(_, _, let issues) = $0 else { return nil }
                return issues
            }
        }
    }

    static let secondWindowNumber = 778
    static let thirdWindowNumber  = 779

    /// Each extra window sits at its own origin inside the virtual display, so
    /// a test that alternates between them alternates geometry as well as
    /// identity: two windows at one frame would hide a guard that compared the
    /// wrong record.
    static func reference(_ windowNumber: Int) -> WindowReference {
        Self.reference(windowNumber, processID: FakeGeometry.targetPID)
    }

    static func reference(_ windowNumber: Int, processID: Int32) -> WindowReference {
        let offset = CGFloat(windowNumber - FakeGeometry.windowNumber) * 60
        return FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: offset, dy: offset),
            processID   : processID,
            windowNumber: windowNumber
        )
    }

    /// A seat holding the requested extra windows on top of the first one, each
    /// readable at full size, in adoption order.
    /// `processID` is how a row that touches `KeyHold` gets a process nobody
    /// else is pressing keys on. The default keeps every other row exactly as
    /// it was.
    static func seat(
        sensing  : FakeSensing = FakeSensing(),
        placing  : FakePlacing = FakePlacing(),
        sender   : FakeSender  = FakeSender(),
        marker   : Int64       = 555,
        also     : [Int]       = [],
        processID: Int32       = FakeGeometry.targetPID
    ) async throws -> (seat: AgentSeat, windows: [AdoptedWindow]) {

        sensing.targetPID = processID
        sensing.geometry  = FakeGeometry.reference(
            frame    : FakeGeometry.adoptedWindow.frame,
            processID: processID
        )
        let seat  = makeSeat(sensing: sensing, placing: placing, sender: sender, marker: marker)
        var built = [try await seat.adopt(
            FakeGeometry.reference(
                frame    : FakeGeometry.userSeatWindow.frame,
                processID: processID
            ),
            platform: AppKitPlatform()
        )]
        for windowNumber in also {
            let reference = Self.reference(windowNumber, processID: processID)
            sensing.additionalWindows[windowNumber] = reference
            built.append(try await seat.adopt(reference, platform: AppKitPlatform()))
        }
        return (seat, built)
    }

    // MARK: The current target

    @Test("adopting a window makes it the target and says so")
    func adoptionMovesTheTarget() async throws {
        let sensing = FakeSensing()
        let seat    = makeSeat(sensing: sensing)
        let log     = EventLog(seat)
        defer { log.stop() }

        let first = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        #expect(seat.currentTarget?.id == first.id)

        let reference = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await seat.adopt(reference, platform: AppKitPlatform())

        #expect(seat.currentTarget?.id == second.id)
        #expect(seat.targetHistory == [first.id, second.id])

        await log.drain()
        #expect(log.targetChanges.map(\.reason) == [.adopted, .adopted])
        #expect(log.targetChanges.map(\.from) == [nil, first.id])
    }

    @Test("A to B to A stages each window and leaves B as A's predecessor")
    func targetGoesThereAndBack() async throws {
        let placing = FakePlacing()
        let (seat, windows) = try await Self.seat(placing: placing, also: [Self.secondWindowNumber])
        let (first, second) = (windows[0], windows[1])
        let log = EventLog(seat)
        defer { log.stop() }

        await log.drain()
        let changesFromAdoption = log.targetChanges.count
        let stagesBefore        = placing.stages
        _ = try await seat.switchTarget(to: first)

        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.targetHistory == [second.id, first.id])
        #expect(placing.stages == stagesBefore + 1, "The new target is brought forward, once")
        #expect(seat.isStaged(first))
        #expect(seat.isStaged(second), "Both windows still read at full size, so both are on stage")
        #expect(first.reference.frame != second.reference.frame,
                "The two windows must differ in geometry as well as identity")
        #expect(seat.seatGuard?.target.hasSameIdentity(as: first.reference) == true)

        await log.drain()
        #expect(log.targetChanges.count == changesFromAdoption + 1)
        #expect(log.targetChanges.last?.to == first.id)
        #expect(log.targetChanges.last?.from == second.id)
        #expect(log.targetChanges.last?.reason == .requested)
    }

    @Test("a window the seat does not hold is refused and the target does not move")
    func switchToAForeignWindow() async throws {
        let (seat, windows) = try await Self.seat()
        let log = EventLog(seat)
        defer { log.stop() }

        let stranger = AdoptedWindow(
            reference    : Self.reference(Self.thirdWindowNumber),
            originalFrame: FakeGeometry.userSeatWindow.frame
        )
        await #expect(throws: SessionFailure.windowNotAdopted(windowNumber: stranger.id)) {
            try await seat.switchTarget(to: stranger)
        }
        #expect(seat.currentTarget?.id == windows[0].id)

        await log.drain()
        #expect(log.refusals == [stranger.id])
    }

    @Test("a Command of the previous target is refused and never redirected to the new one")
    func aCommandIsNeverRedirected() async throws {
        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            sensing: sensing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        _ = try await seat.switchTarget(to: windows[0])
        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)
        #expect(observation.recipient == windows[0].reference.identity)

        // The target moves while the consumer was deciding. The Command it
        // decided is refused: the recipient is the reference's and is never
        // recomputed from whatever is current now.
        _ = try await seat.switchTarget(to: windows[1])

        await #expect(throws: ObservationAdmissionRefusal.noCurrentObservation(.targetChanged)) {
            try await seat.send(Self.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.currentTarget?.id == windows[1].id)
        try seat.release(turn)
    }

    // MARK: The stage

    @Test("staging one window does not invent a stash for the others")
    func stagingReadsTheOthersBack() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await Self.seat(sensing: sensing, also: [Self.secondWindowNumber])

        // The first window still reads at full size, so it is still on stage.
        _ = try await seat.stage(windows[1])
        #expect(seat.isStaged(windows[0]))

        // A thumbnail is the one reading that proves a stash.
        sensing.geometry = FakeGeometry.reference(
            frame: CGRect(origin: FakeGeometry.windowOrigin, size: CGSize(width: 90, height: 97))
        )
        _ = try await seat.stage(windows[1])
        #expect(!seat.isStaged(windows[0]))
    }

    @Test("a window the server cannot read keeps the staging it had")
    func stagingLeavesAnUnreadableWindowAlone() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await Self.seat(sensing: sensing, also: [Self.secondWindowNumber])

        sensing.geometry = nil
        _ = try await seat.stage(windows[1])
        #expect(seat.isStaged(windows[0]), "Not readable is not evidence of stashed")
    }

    @Test("a fold reads every held window's staging back, with no staging of its own")
    func aFoldReadsTheStagingBack() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await Self.seat(sensing: sensing, placing: placing)
        #expect(seat.isStaged(windows[0]))
        let stagesBefore = placing.stages

        // Stage Manager stashes a window whenever another window of the same
        // application is raised, and nobody tells the seat.
        sensing.geometry = FakeGeometry.reference(
            frame: CGRect(origin: FakeGeometry.windowOrigin, size: CGSize(width: 90, height: 97))
        )
        seat.refreshTargetReadings()
        #expect(!seat.isStaged(windows[0]), "staging is read at every fold and never remembered")
        #expect(placing.stages == stagesBefore, "reading a stash is not answering it")

        sensing.geometry = nil
        seat.refreshTargetReadings()
        #expect(!seat.isStaged(windows[0]), "an unreadable window keeps the value it had")
    }

    // MARK: The pause

    @Test("a transfer holds input closed and resolves only its own cause")
    func transferHoldsOnlyItsOwnCause() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )

        // A focus recovery is already holding the gate when the transfer starts.
        sender.gate.pause(.focusRecovery)
        placing.onStageWait = {
            #expect(sender.gate.pauseCauses == [.focusRecovery, .windowTransfer])
        }

        _ = try await seat.switchTarget(to: windows[0])

        #expect(sender.gate.pauseCauses == [.focusRecovery],
                "A finished transfer must not reopen input the focus recovery is still holding")
        #expect(sender.gate.isPaused)

        sender.gate.resume(.focusRecovery)
        #expect(!sender.gate.isPaused)
    }

    @Test("a transfer outside a Turn is the focus episode, and the episode ends with it")
    func transferIsTheFocusEpisodeOutsideATurn() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            sensing: sensing,
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        let recovery = UserFocusRecovery(
            sensing: sensing,
            gate   : sender.gate,
            adopted: { [] },
            restore: { _ in 0 },
            changed: { _ in }
        )
        seat.focusRecovery = recovery

        // No Turn is held, so the transfer is the only thing that can arm it.
        await #expect(throws: InputFailure.inputPaused([.holdEnded])) {
            try await recovery.prepareBeforeAction()
        }
        placing.onStageWait = {
            await #expect(throws: Never.self, "the operation armed the recovery") {
                try await recovery.prepareBeforeAction()
            }
        }

        _ = try await seat.switchTarget(to: windows[0])

        await #expect(throws: InputFailure.inputPaused([.holdEnded]),
                      "and the operation ended its episode with it") {
            try await recovery.prepareBeforeAction()
        }
    }

    @Test("a refused transfer leaves the gate exactly as it found it")
    func refusedTransferDoesNotReopenTheGate() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        sender.gate.pause(.focusRecovery)
        let log = EventLog(seat)
        defer { log.stop() }
        await log.drain()
        let changesFromAdoption = log.targetChanges.count
        placing.stageError = SessionFailure.windowNotAdopted(windowNumber: windows[0].id)

        await #expect(throws: (any Error).self) { try await seat.switchTarget(to: windows[0]) }

        #expect(seat.currentTarget?.id == windows[1].id, "A failed stage is not a target change")
        #expect(sender.gate.pauseCauses == [.focusRecovery])

        // The refusal is on the stream, and it names the window Issue that
        // decided it: an empty list would say the seat's state was the reason.
        await log.drain()
        #expect(log.refusals == [windows[0].id])
        #expect(log.refusalIssues == [[.windowStashed]])
        #expect(log.targetChanges.count == changesFromAdoption, "A refused transfer publishes no change")
    }

    @Test("a target change with a key still down is refused instead of stranding the press")
    func transferRefusedWhileKeysAreHeld() async throws {
        let placing = FakePlacing()
        let (seat, windows) = try await Self.seat(
            placing  : placing,
            marker   : 9_101,
            also     : [Self.secondWindowNumber],
            processID: FakeGeometry.distinctProcessID()
        )
        _ = try await seat.switchTarget(to: windows[0])

        let turn      = try await seat.acquire()
        let processID = windows[0].reference.processID
        defer { _ = KeyHold.shared.releaseAll(owner: turn.correlationID, processID: processID) }

        KeyHold.shared.press(
            KeyHold.HeldKey(virtualKey: 56),
            owner    : turn.correlationID,
            processID: processID
        )
        let stagesBefore = placing.stages

        await #expect(throws: SessionFailure.keysStillHeld(count: 1)) {
            try await seat.switchTarget(to: windows[1])
        }
        #expect(seat.currentTarget?.id == windows[0].id)
        #expect(placing.stages == stagesBefore, "Nothing is moved for a refused transfer")
    }

    @Test("a target change asked for during a command waits for the boundary")
    func transferWaitsForTheCommandBoundary() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        _ = try await seat.switchTarget(to: windows[0])
        let turn = try await seat.acquire()

        let stagesBefore = placing.stages
        let started      = Holder<Task<AdoptedWindow, any Error>?>(nil)
        let observed     = Holder<Int>(-1)

        sender.onSendWait = {
            started.value = Task { @MainActor in try await seat.switchTarget(to: windows[1]) }
            // One turn of the loop is enough for the transfer to reach its wait.
            await Task.yield()
            observed.value = placing.stages
        }

        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        #expect(observed.value == stagesBefore, "A Command in flight is never cut in half")
        #expect(sender.sent.count == 1, "And it is never posted twice")

        try seat.confirm(receipt, .observed)
        let moved = try await started.value?.value
        #expect(moved?.id == windows[1].id)
        #expect(seat.currentTarget?.id == windows[1].id)
        _ = await seat.concludeObservation()
        try seat.release(turn)
    }

    @Test("a window released while its transfer is staging does not come back as the target")
    func releaseDuringATransfer() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        _ = try await seat.switchTarget(to: windows[0])
        sender.gate.pause(.focusRecovery)

        placing.onStageWait = { [weak placing] in
            placing?.onStageWait = nil
            _ = await seat.release(windows[1])
        }

        await #expect(throws: (any Error).self) { try await seat.switchTarget(to: windows[1]) }

        #expect(seat.currentTarget?.id == windows[0].id)
        #expect(seat.adoptedWindows.map(\.id) == [windows[0].id], "A released record is not written back")
        #expect(sender.gate.pauseCauses == [.focusRecovery])
    }

    @Test("a cancelled transfer leaves the target where it was and reopens nothing")
    func cancelledTransfer() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        _ = try await seat.switchTarget(to: windows[0])
        sender.gate.pause(.focusRecovery)

        let resume = Holder<CheckedContinuation<Void, Never>?>(nil)
        placing.onStageWait = { await withCheckedContinuation { resume.value = $0 } }

        let transfer = Task { @MainActor in try await seat.switchTarget(to: windows[1]) }
        while resume.value == nil { await Task.yield() }
        transfer.cancel()
        resume.value?.resume()

        await #expect(throws: (any Error).self) { try await transfer.value }
        #expect(seat.currentTarget?.id == windows[0].id)
        #expect(sender.gate.pauseCauses == [.focusRecovery])
    }

    // MARK: The target that goes away

    @Test("releasing the target falls back to the window before it")
    func releaseFallsBackToThePredecessor() async throws {
        let (seat, windows) = try await Self.seat(
            also: [Self.secondWindowNumber, Self.thirdWindowNumber]
        )
        let log = EventLog(seat)
        defer { log.stop() }

        #expect(seat.currentTarget?.id == windows[2].id)
        _ = await seat.release(windows[2])

        #expect(seat.currentTarget?.id == windows[1].id)
        await log.drain()
        #expect(log.targetChanges.last?.reason == .predecessor)
        #expect(log.targetChanges.last?.to == windows[1].id)
    }

    @Test("a window released out of order is not chosen when the target goes")
    func releaseOutOfOrder() async throws {
        let (seat, windows) = try await Self.seat(
            also: [Self.secondWindowNumber, Self.thirdWindowNumber]
        )
        // A to B to C, with B released before C.
        _ = await seat.release(windows[1])
        #expect(seat.currentTarget?.id == windows[2].id, "Releasing a window that is not the target moves nothing")

        _ = await seat.release(windows[2])
        #expect(seat.currentTarget?.id == windows[0].id)
        #expect(seat.adoptedWindows.map(\.id) == [windows[0].id])
    }

    /// Measured with DaVinci Resolve: a Command on its Import panel moved the
    /// guard onto the panel while the main window stayed the target, and the
    /// panel closing took the guard with it. Every later Command read no guard
    /// as `windowUnavailable`, and the recovery that followed could not end.
    @Test("a window the guard followed a Command onto gives the guard back to the target when it goes")
    func guardReturnsToTheTarget() async throws {
        let sender = FakeSender()
        let (seat, windows) = try await Self.seat(sender: sender, also: [Self.secondWindowNumber])
        _ = try await seat.switchTarget(to: windows[0])
        let baseline = try #require(seat.seatGuard)
        seat.seatGuard = SeatGuard(
            target       : windows[1].reference,
            displayID    : baseline.displayID,
            displayBounds: baseline.displayBounds
        )

        _ = await seat.release(windows[1])

        #expect(seat.currentTarget?.id == windows[0].id)
        #expect(seat.seatGuard?.target.windowNumber == windows[0].id)
        let turn = try await seat.acquire()
        let observation = try await observedReference(seat)
        let receipt = try await seat.send(Self.click, observation: observation, turn: turn)
        #expect(sender.sent.count == 1)
        try seat.confirm(receipt, .observed)
        try seat.release(turn)
    }

    @Test("with the last window gone the seat says it has no target")
    func releaseOfTheLastWindow() async throws {
        let (seat, windows) = try await Self.seat()

        _ = await seat.release(windows[0])
        #expect(seat.currentTarget == nil)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(seat.targetHistory.isEmpty)
    }

    @Test("a teardown chooses no predecessor and leaves nothing on stage")
    func teardownChoosesNothing() async throws {
        let placing = FakePlacing()
        let sender  = FakeSender()
        let (seat, _) = try await Self.seat(
            placing: placing,
            sender : sender,
            also   : [Self.secondWindowNumber]
        )
        let stagesBefore = placing.stages

        let outcomes = await seat.releaseAllWindows(.returnToUserSeat)

        #expect(outcomes.count == 2)
        #expect(seat.currentTarget == nil)
        #expect(placing.stages == stagesBefore, "A window on its way out is not brought forward")
        #expect(!sender.gate.isPaused, "A teardown leaves no window transfer holding input")
    }

    @Test("a destroyed target hands over to its predecessor once the budget is spent")
    func destroyedTargetHandsOver() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await Self.seat(sensing: sensing, also: [Self.secondWindowNumber])
        let log = EventLog(seat)
        defer { log.stop() }

        // The second window stops being readable. One missing reading is not a
        // proof: the recovery budget has to run out on it first.
        sensing.additionalWindows[Self.secondWindowNumber] = nil
        seat.report([.windowUnavailable])
        #expect(seat.state == .recovering)
        #expect(seat.currentTarget?.id == windows[1].id, "A recovery in flight is not a destruction")

        // The budget is five measured seconds of an unreadable window, so a
        // wait that ends without the handover has to say what it measured.
        let handedOver = await RecoveryWait.settle(seat) {
            seat.currentTarget?.id == windows[0].id
        }
        #expect(handedOver.satisfied, "\(handedOver)")
        #expect(seat.state == .ready)
        #expect(seat.adoptedWindows.map(\.id) == [windows[0].id])

        await log.drain()
        #expect(log.targetChanges.last?.reason == .predecessor)
    }

    @Test("a destroyed target with nothing behind it fails the seat instead of choosing a stranger")
    func destroyedTargetWithNoPredecessor() async throws {
        let sensing = FakeSensing()
        let (seat, _) = try await Self.seat(sensing: sensing)

        sensing.geometry = nil
        seat.report([.windowUnavailable])

        let failed = await RecoveryWait.settle(seat) { seat.state == .failed }
        #expect(failed.satisfied, "\(failed)")
        #expect(seat.currentTarget != nil, "Nothing was handed over, so nothing was forgotten either")
    }

    // MARK: The detected window entry MW-02 uses

    @Test("a detected window waits for the command boundary instead of being dropped")
    func detectedWindowWaitsForTheBoundary() async throws {
        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, windows) = try await Self.seat(sensing: sensing, sender: sender)
        let turn = try await seat.acquire()

        let reference = Self.reference(Self.secondWindowNumber)
        sensing.additionalWindows[reference.windowNumber] = reference
        let started = Holder<Task<AdoptedWindow, any Error>?>(nil)
        let seen    = Holder<Int>(-1)

        sender.onSendWait = {
            started.value = Task { @MainActor in
                try await seat.integrateDetectedWindow(reference, platform: AppKitPlatform())
            }
            await Task.yield()
            seen.value = seat.adoptedWindows.count
        }

        let receipt = try await seat.send(
            Self.click,
            observation: try await observedReference(seat),
            turn       : turn
        )
        #expect(seen.value == 1, "Nothing is adopted while a Command is in flight")

        let adopted = try await started.value?.value
        #expect(adopted?.id == reference.windowNumber)
        #expect(seat.currentTarget?.id == windows[0].id,
                "The window is held at the boundary, and the target is not moved onto it")
        #expect(sender.sent.count == 1, "The Command that opened the window is never repeated")

        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)
    }

    @Test("a detected window without an attested identity is refused before anything moves")
    func detectedWindowWithoutIdentity() async throws {
        let placing = FakePlacing()
        let (seat, _) = try await Self.seat(placing: placing)
        let stagesBefore = placing.moves.count

        let unattested = WindowReference(
            processID   : FakeGeometry.targetPID,
            windowNumber: Self.thirdWindowNumber,
            frame       : FakeGeometry.userSeatWindow.frame
        )
        await #expect(throws: (any Error).self) {
            try await seat.integrateDetectedWindow(unattested, platform: AppKitPlatform())
        }
        #expect(placing.moves.count == stagesBefore)
    }
}

/// A box for a value a test hook writes and the test body reads. The hooks are
/// plain escaping closures on the fakes, and everything here runs on the main
/// actor, so this is about the compiler's view of a captured `var` and nothing
/// else.
@MainActor
final class Holder<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
