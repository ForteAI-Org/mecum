//
//  AgentSeatTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The whole seat driven through the three fakes: adopt, hold, send, confirm,
/// release, and every refusal in between. No display, no tap, no Accessibility
/// grant, so this runs on any machine and in parallel with everything else.
@MainActor
@Suite("Agent seat")
struct AgentSeatTests {

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    /// A seat with a window already adopted, which is the starting point of
    /// everything about acting. Adoption itself is tested separately.
    static func adopted(
        sensing: FakeSensing = FakeSensing(),
        placing: FakePlacing = FakePlacing(),
        sender : FakeSender  = FakeSender()
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow) {

        let seat   = makeSeat(sensing: sensing, placing: placing, sender: sender)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        return (seat, window)
    }

    // MARK: Adoption

    @Test("a sequence paused after posting preserves its receipts and cannot be silently replayed")
    func partialSequenceRequiresConfirmation() async throws {
        let sender = FakeSender()
        let completed = try await sender.send(
            Self.click,
            to           : FakeGeometry.adoptedWindow,
            correlationID: 555,
            platform     : AppKitPlatform()
        ).replacingCleanup(.failed(code: -17))
        let progress = InputProgress(
            completedSteps              : [.activation, .keyWindowFirst, .keyWindowSecond],
            failedStep                  : nil,
            failedStepMayHaveTakenEffect: false,
            cleanup                     : .failed(code: -17)
        )
        sender.error = InputSequenceFailure(
            completedReceipts: [completed],
            cause            : InputFailure.inputPaused,
            progress         : progress,
            cleanupCause     : InputFailure.restoreFailed(code: -17)
        )
        let (seat, window) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()
        do {
            _ = try await seat.sendSequence([Self.click, Self.click], to: window, turn: turn)
            Issue.record("The paused sequence must report its partial delivery")
        } catch let failure as InputSequenceFailure {
            #expect(failure.completedReceipts.count == 1)
            #expect(failure.completedReceipts.first?.cleanup == .failed(code: -17))
            #expect(failure.progress == progress)
            #expect(failure.cause as? InputFailure == .inputPaused)
            #expect(failure.cleanupCause as? InputFailure == .restoreFailed(code: -17))
            #expect(seat.unconfirmedCommandCount == 1)
            #expect(seat.state == .degraded)
            #expect(throws: SessionFailure.unconfirmedCommands(count: 1)) { try seat.release(turn) }
            try seat.confirm(try #require(failure.completedReceipts.first), .unknown)
            try seat.release(turn)
        }
    }

    @Test("a focus interruption delivered during send survives its completion")
    func completionPreservesWaiting() async throws {
        let sender = FakeSender()
        let (seat, window) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()
        sender.onSend = { _ in seat.report([.targetActivated]) }
        let receipt = try await seat.send(Self.click, to: window, turn: turn)
        #expect(seat.state == .waiting)
        await #expect(throws: SessionFailure.seatNotReady(.waiting)) {
            try await seat.send(Self.click, to: window, turn: turn)
        }
        #expect(sender.sent.count == 1)
        try seat.confirm(receipt, .unknown)
        try seat.release(turn)
    }

    @Test("a failed preparation cleanup degrades without inventing a posted command")
    func failedPreparationCleanupDegrades() async throws {
        let sender = FakeSender()
        sender.error = InputPreparationFailure(
            progress: InputProgress(
                completedSteps              : [.activation],
                failedStep                  : .keyWindowFirst,
                failedStepMayHaveTakenEffect: true,
                cleanup                     : .failed(code: -17)
            ),
            cause       : InputFailure.preparationFailed(step: .keyWindowFirst, code: -9),
            cleanupCause: InputFailure.restoreFailed(code: -17)
        )
        let (seat, window) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()

        await #expect(throws: InputPreparationFailure.self) {
            try await seat.send(Self.click, to: window, turn: turn)
        }

        #expect(seat.state == .degraded)
        #expect(seat.unconfirmedCommandCount == 0)
        try seat.release(turn)
    }

    @Test("adopt moves the window, confirms it twice and leaves the seat ready")
    func adoptConfirms() async throws {

        let placing = FakePlacing()
        let (seat, window) = try await Self.adopted(placing: placing)

        #expect(placing.moves.count == 1)
        #expect(seat.state == .ready)
        #expect(window.originalFrame == FakeGeometry.userSeatWindow.frame)
        #expect(seat.seatGuard?.target.hasSameIdentity(as: FakeGeometry.adoptedWindow) == true)
        #expect(seat.adoptedWindows.count == 1)
        #expect(seat.isStaged(window))
    }

    @Test("adopt refuses when the window server never confirms the placement")
    func adoptNeverConfirmed() async throws {

        let sensing = FakeSensing()
        sensing.geometry = nil

        let seat = makeSeat(sensing: sensing)

        await #expect(throws: (any Error).self) {
            try await seat.adopt(FakeGeometry.userSeatWindow)
        }
        #expect(seat.state == .failed)
        #expect(seat.hasPendingWindowRestorations)
    }

    // MARK: The hold

    @Test("a command without a turn is refused before anything goes out")
    func turnRequired() async throws {

        let sender = FakeSender()
        let (seat, window) = try await Self.adopted(sender: sender)

        await #expect(throws: SessionFailure.turnRequired) {
            try await seat.send(Self.click, to: window, turn: Turn(
                generation              : 1,
                seatChangedSinceLastHold: false,
                correlationID           : 1
            ))
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("a command on a seat that is not ready is refused, with the state as the answer")
    func seatNotReady() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, window) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()

        // The person went into the application: the seat waits, with no
        // deadline, and refuses rather than queueing.
        sensing.targetIsActive = true
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        await #expect(throws: SessionFailure.seatNotReady(.waiting)) {
            try await seat.send(Self.click, to: window, turn: turn)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("the turn's marker is the one every event is stamped with")
    func markerTravels() async throws {

        let sender = FakeSender()
        let (seat, window) = try await Self.adopted(sender: sender)

        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        #expect(sender.sent.count == 1)
        #expect(sender.sent[0].correlationID == turn.correlationID)
        #expect(receipt.eventCount == 2)
        #expect(seat.state == .ready)
    }

    @Test("the receipt comes back with an observation, which a driver alone leaves nil")
    func receiptCarriesAnObservation() async throws {

        let (seat, window) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        #expect(receipt.observation != nil)
    }

    // MARK: Confirmation and the anti replay invariant

    @Test("releasing the hold is refused while a command is unconfirmed")
    func releaseRefusedWithAnUnknown() async throws {

        let (seat, window) = try await Self.adopted()
        let turn = try await seat.acquire()
        _ = try await seat.send(Self.click, to: window, turn: turn)

        #expect(seat.unconfirmedCommandCount == 1)
        #expect(throws: SessionFailure.unconfirmedCommands(count: 1)) {
            try seat.release(turn)
        }
        #expect(seat.currentTurn == turn)
    }

    @Test("an explicit unknown still releases: the caller answered, and the answer is remembered")
    func explicitUnknownReleases() async throws {

        let (seat, window) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        try seat.confirm(receipt, .unknown)
        try seat.release(turn)

        #expect(seat.currentTurn == nil)
    }

    @Test("confirming closes the command and lets the hold go")
    func confirmThenRelease() async throws {

        let (seat, window) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        try seat.confirm(receipt, .observed)
        #expect(seat.unconfirmedCommandCount == 0)

        try seat.release(turn)
        #expect(!seat.unconfirmedCommandCount.isMultiple(of: 2) == false)
    }

    @Test("a confirmation out of order is refused instead of matched by guesswork")
    func confirmOutOfOrder() async throws {

        let (seat, window) = try await Self.adopted()
        let turn = try await seat.acquire()

        let receipts = try await seat.sendSequence(
            [Self.click, Self.click],
            to  : window,
            turn: turn
        )

        #expect(receipts.count == 2)
        #expect(throws: SessionFailure.receiptOutOfOrder) {
            try seat.confirm(receipts[1], .observed)
        }

        try seat.confirm(receipts[0], .observed)
        try seat.confirm(receipts[1], .observed)
        try seat.release(turn)
    }

    @Test("confirming with nothing pending is refused")
    func nothingToConfirm() async throws {

        let (seat, window) = try await Self.adopted()
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        try seat.confirm(receipt, .observed)
        #expect(throws: SessionFailure.nothingToConfirm) {
            try seat.confirm(receipt, .observed)
        }
    }

    @Test("a sequence is one preparation and one marker for every command in it")
    func sequenceSharesOnePreparation() async throws {

        let sender = FakeSender()
        let (seat, window) = try await Self.adopted(sender: sender)

        let turn = try await seat.acquire()
        _ = try await seat.sendSequence([Self.click, Self.click, Self.click], to: window, turn: turn)

        #expect(sender.sent.count == 3)
        #expect(Set(sender.sent.map(\.correlationID)) == [turn.correlationID])
    }

    // MARK: The issues, and who owns them

    @Test("a critical seat issue fails the seat and throws the waiters out")
    func criticalIssueFailsTheSeat() async throws {

        let (seat, _) = try await Self.adopted()
        let turn = try await seat.acquire()

        let waiting = Task { @MainActor in try await seat.acquire() }
        await Task.yield()

        seat.report([.identityChanged])
        #expect(seat.state == .failed)

        await #expect(throws: SeatInterruption.self) { try await waiting.value }
        _ = turn
    }

    @Test("a host issue fails the seat, and the seat does not decide it for itself")
    func hostIssueFailsTheSeat() async throws {

        let (seat, _) = try await Self.adopted()
        seat.failFromHost([.displayChanged])

        #expect(seat.state == .failed)
        await #expect(throws: SessionFailure.seatNotReady(.failed)) { _ = try await seat.acquire() }
    }

    @Test("a window issue leaves the seat usable: the stage failed, not the seat")
    func windowIssueLeavesTheSeatUsable() async throws {

        let (seat, _) = try await Self.adopted()
        seat.report([.windowStashed])

        #expect(seat.state == .ready)
    }

    @Test("a preparation the target refused to give back degrades the seat and keeps it acting")
    func unrestoredPreparationDegrades() async throws {

        let sender = FakeSender()
        sender.reportsUnrestoredPreparation = true

        let (seat, window) = try await Self.adopted(sender: sender)
        let turn    = try await seat.acquire()
        let receipt = try await seat.send(Self.click, to: window, turn: turn)

        #expect(receipt.hasUnrestoredPreparation)
        #expect(seat.state == .degraded)

        // Degraded still acts: what degraded it is not what the Command needs.
        _ = try await seat.send(Self.click, to: window, turn: turn)
        #expect(sender.sent.count == 2)
    }

    @Test("the guard runs immediately before the events, and refuses on a reused window id")
    func preflightCatchesIdentity() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, window) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()

        // The window died and the id was handed to somebody else between the
        // adoption and the send, which is the case a check taken a second
        // earlier cannot see.
        sensing.geometry = FakeGeometry.reference(
            frame    : FakeGeometry.adoptedWindow.frame,
            processID: 1
        )

        await #expect(throws: SeatInterruption.self) {
            try await seat.send(Self.click, to: window, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .failed)
    }

    @Test("a target that became active refuses the command and waits")
    func preflightCatchesActivation() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, window) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()
        sensing.targetIsActive = true

        await #expect(throws: SeatInterruption.self) {
            try await seat.send(Self.click, to: window, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .waiting)
    }

    @Test("a dead fence refuses the command: no seat invariant survives it")
    func preflightCatchesTheFence() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, window) = try await Self.adopted(sensing: sensing, sender: sender)

        let turn = try await seat.acquire()
        sensing.fenceIsActive = false

        await #expect(throws: SeatInterruption.self) {
            try await seat.send(Self.click, to: window, turn: turn)
        }
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .failed)
    }

    @Test("waiting leaves only when the person leaves the application, on a heartbeat")
    func waitingLeavesOnTheHeartbeat() async throws {

        let sensing = FakeSensing()
        let (seat, _) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = true
        seat.report([.targetActivated])
        #expect(seat.state == .waiting)

        // Beats while the person is still in the application change nothing:
        // there is no timeout that gives up on them.
        for _ in 0..<5 {
            seat.heartbeat()
            #expect(seat.state == .waiting)
        }

        sensing.targetIsActive = false
        seat.heartbeat()
        #expect(seat.state == .ready)
    }

    @Test("a process that died while the seat waited is critical")
    func waitingOnADeadProcess() async throws {

        let sensing = FakeSensing()
        let (seat, _) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = true
        seat.report([.targetActivated])

        sensing.targetIsActive = nil
        seat.heartbeat()

        #expect(seat.state == .failed)
    }

    // MARK: Release

    @Test("releasing a window puts it back at its original frame")
    func releaseReturnsTheWindow() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        placing.onMove = { origin in
            sensing.geometry = FakeGeometry.userSeatWindow.replacingFrame(
                CGRect(origin: origin, size: FakeGeometry.windowSize)
            )
        }

        let (seat, window) = try await Self.adopted(sensing: sensing, placing: placing)
        let outcome = await seat.release(window, .returnToUserSeat)

        #expect(outcome == .returned)
        #expect(placing.moves.last == FakeGeometry.userSeatWindow.frame.origin)
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test("leaving a window on the virtual display writes nothing")
    func releaseLeavesTheWindow() async throws {

        let placing = FakePlacing()
        let (seat, window) = try await Self.adopted(placing: placing)

        let before  = placing.moves.count
        let outcome = await seat.release(window, .leaveOnVirtualDisplay)

        #expect(outcome == .leftOnVirtualDisplay)
        #expect(placing.moves.count == before)
    }

    @Test("releasing a window whose process is gone is reported, not an error")
    func releaseAVanishedWindow() async throws {

        let sensing = FakeSensing()
        let (seat, window) = try await Self.adopted(sensing: sensing)

        sensing.targetIsActive = nil
        let outcome = await seat.release(window)

        #expect(outcome == .vanished)
    }

    @Test("a command to a window the seat does not hold is refused")
    func sendToAForeignWindow() async throws {

        let sender = FakeSender()
        let (seat, _) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()

        let foreign = AdoptedWindow(
            reference    : FakeGeometry.reference(frame: .zero, processID: 1, windowNumber: 1),
            originalFrame: .zero
        )

        await #expect(throws: SessionFailure.windowNotAdopted(windowNumber: 1)) {
            try await seat.send(Self.click, to: foreign, turn: turn)
        }
        #expect(sender.sent.isEmpty)
    }

    @Test("a driver refusal leaves no unconfirmed command behind: nothing was posted")
    func aRefusedSendLeavesNothingPending() async throws {

        let sender = FakeSender()
        sender.error = InputFailure.preparationFailed(step: .activation, code: -1)

        let (seat, window) = try await Self.adopted(sender: sender)
        let turn = try await seat.acquire()

        await #expect(throws: InputFailure.self) {
            try await seat.send(Self.click, to: window, turn: turn)
        }

        #expect(seat.unconfirmedCommandCount == 0)
        try seat.release(turn)
    }
}
