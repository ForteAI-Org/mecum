//
//  AssignedApplicationHandbackTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Giving the Assigned Application back, through the three fakes: the handback
/// that ends the assignment and lets the next instance in, every refusal that
/// keeps an application the seat still has a claim on, and the window of another
/// instance a handback must not touch.
///
/// The failure these come from is a consumer that finished with one application
/// and adopted a window of a second one: the seat moved it and then refused
/// every selection with `surfaceIsNotAMember`, because the first assignment was
/// bound to the seat until it failed or was torn down.
@MainActor
@Suite("Giving the assigned application back")
struct AssignedApplicationHandbackTests {

    static let click = InputCommand.click(InputLocation(
        screenPoint       : CGPoint(x: 2700, y: 700),
        windowPointFromTop: CGPoint(x: 100, y: 100)
    ))

    static let otherWindowNumber = 778

    /// A second window of the **assigned** instance, which the seat never
    /// adopted and never moved.
    static let untouchedWindowNumber = 779

    /// A window of a second instance, at its own origin inside the virtual
    /// display: two windows at one frame would hide a check that compared the
    /// wrong record.
    static func otherInstanceWindow(processID: Int32) -> WindowReference {
        FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60),
            processID   : processID,
            windowNumber: otherWindowNumber
        )
    }

    /// A seat holding one window of the default instance, which is the state
    /// every row here starts from.
    static func seatWithOneInstance(
        sensing: FakeSensing = FakeSensing(),
        placing: FakePlacing = FakePlacing(),
        sender : FakeSender  = FakeSender(),
        marker : Int64       = 555
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow) {

        let seat   = makeSeat(sensing: sensing, placing: placing, sender: sender, marker: marker)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        return (seat, window)
    }

    // MARK: The handback itself

    @Test("a handback ends the assignment as an explicit release and leaves nothing owed")
    func handbackEndsTheAssignment() async throws {
        let (seat, window) = try await Self.seatWithOneInstance()
        seat.refreshTargetReadings()
        #expect(seat.coherentState.instance?.processID == FakeGeometry.targetPID)

        _ = await seat.release(window)
        try seat.releaseAssignedApplication()

        #expect(seat.coherentState.instance == nil)
        #expect(seat.assignmentKit.lifecycle.lastEnd == .explicitRelease,
                "The end is the consumer's own, not an exit and not a stop")
        #expect(seat.assignmentKit.lifecycle.isSeatStopped == false,
                "A handback gives one application back and does not stop the seat")
        #expect(seat.coherentState.outstandingReturns.isEmpty,
                "A handback the seat allowed leaves no return obligation behind")
        #expect(seat.coherentState.lastInvalidation == .lifecycleChanged)
    }

    @Test("after a handback a window of another instance is handed over and selected")
    func anotherInstanceIsHandedOver() async throws {
        let sensing = FakeSensing()
        let (seat, first) = try await Self.seatWithOneInstance(sensing: sensing)

        _ = await seat.release(first)
        try seat.releaseAssignedApplication()

        let otherPID  = FakeGeometry.distinctProcessID()
        let reference = Self.otherInstanceWindow(processID: otherPID)
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await seat.adopt(reference, platform: AppKitPlatform())

        #expect(seat.coherentState.instance?.processID == otherPID)
        #expect(seat.assignmentKit.lifecycle.generation == 2,
                "The second assignment is its own generation, never a continuation of the first")

        // The symptom the ticket came from: the window of the second instance is
        // a member now, so the selection answers it instead of refusing it.
        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient.windowNumber == second.id)
    }

    @Test("a handback leaves a window the seat holds of another instance exactly where it is")
    func anotherInstancesWindowIsUndisturbed() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await Self.seatWithOneInstance(sensing: sensing, placing: placing)

        let reference = Self.otherInstanceWindow(processID: FakeGeometry.distinctProcessID())
        sensing.additionalWindows[reference.windowNumber] = reference
        let second = try await seat.adopt(reference, platform: AppKitPlatform())

        _ = await seat.release(first)
        let movesBefore  = placing.moves.count
        let stagesBefore = placing.stages
        let frameBefore  = second.reference.frame

        try seat.releaseAssignedApplication()

        #expect(seat.coherentState.instance == nil)
        #expect(seat.adoptedWindows.map(\.id) == [second.id])
        #expect(seat.currentTarget?.id == second.id)
        #expect(seat.currentTarget?.reference.frame == frameBefore)
        #expect(placing.moves.count == movesBefore, "A handback writes no geometry")
        #expect(placing.stages == stagesBefore, "And stages nothing")
    }

    @Test("a handback is allowed while the instance has a window the seat never touched")
    func anUntouchedWindowOfTheInstanceIsNotHeld() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, window) = try await Self.seatWithOneInstance(
            sensing: sensing,
            placing: placing,
            marker : 561
        )

        // The measured failure: the instance has a second window open on the
        // person's display, which Finder always does, and nothing adopted it.
        let untouched = FakeGeometry.reference(
            frame       : CGRect(x: 100, y: 100, width: 400, height: 300),
            windowNumber: Self.untouchedWindowNumber
        )
        sensing.additionalWindows[untouched.windowNumber] = untouched
        seat.refreshTargetReadings()

        let members = seat.assignmentKit.inventory.members.map(\.windowNumber)
        #expect(members.contains(Self.untouchedWindowNumber))

        _ = await seat.release(window)
        let movesBefore = placing.moves.count
        try seat.releaseAssignedApplication()

        #expect(seat.coherentState.instance == nil)
        #expect(seat.coherentState.outstandingReturns.isEmpty,
                "No return is owed for a window nobody moved")
        #expect(placing.moves.count == movesBefore, "A handback writes no geometry")
    }

    // MARK: What it refuses

    @Test("a handback with nothing assigned refuses, and so does a second one")
    func nothingAssignedRefuses() async throws {
        let bare = makeSeat()
        #expect(throws: SessionFailure.applicationNotAssigned) {
            try bare.releaseAssignedApplication()
        }

        let (seat, window) = try await Self.seatWithOneInstance(marker: 556)
        _ = await seat.release(window)
        try seat.releaseAssignedApplication()

        #expect(throws: SessionFailure.applicationNotAssigned) {
            try seat.releaseAssignedApplication()
        }
    }

    @Test("a handback while the seat holds a window of the instance refuses and names it")
    func heldWindowsRefuse() async throws {
        let (seat, window) = try await Self.seatWithOneInstance(marker: 557)
        seat.refreshTargetReadings()

        #expect(throws: SessionFailure.assignedWindowsStillHeld(windowNumbers: [window.id])) {
            try seat.releaseAssignedApplication()
        }
        #expect(seat.coherentState.instance?.processID == FakeGeometry.targetPID,
                "A refusal is taken before any effect: the application is still assigned")
        #expect(seat.adoptedWindows.map(\.id) == [window.id])
        #expect(seat.coherentState.outstandingReturns.isEmpty)
    }

    @Test("a handback while a Turn is out refuses and names the hold")
    func turnHeldRefuses() async throws {
        let (seat, window) = try await Self.seatWithOneInstance(marker: 558)
        _ = await seat.release(window)
        let turn = try await seat.acquire()

        #expect(throws: SessionFailure.assignmentStillInUse(.turnHeld)) {
            try seat.releaseAssignedApplication()
        }
        #expect(seat.coherentState.instance?.processID == FakeGeometry.targetPID)

        try seat.release(turn)
        try seat.releaseAssignedApplication()
        #expect(seat.coherentState.instance == nil)
    }

    @Test("a handback while a Command is in flight refuses and names the Command")
    func commandInFlightRefuses() async throws {
        let sender = FakeSender()
        let (seat, _) = try await Self.seatWithOneInstance(
            sender: sender,
            marker: 559
        )
        let turn        = try await seat.acquire()
        let observation = try await observedReference(seat)
        let refusal     = Holder<(any Error)?>(nil)

        sender.onSendWait = {
            do { try seat.releaseAssignedApplication() }
            catch { refusal.value = error }
        }
        let receipt = try await seat.send(Self.click, observation: observation, turn: turn)

        #expect(refusal.value as? SessionFailure == .assignmentStillInUse(.commandInFlight),
                "A Command in flight is named before the Turn that is carrying it")
        #expect(seat.coherentState.instance?.processID == FakeGeometry.targetPID)
        #expect(sender.sent.count == 1, "The refusal left the Command alone")

        try seat.confirm(receipt, .observed)
        _ = await seat.concludeObservation()
        try seat.release(turn)
    }

    @Test("a handback refuses while a return owed by an earlier assignment is unfinished")
    func outstandingReturnsRefuse() async throws {
        let sensing = FakeSensing()
        let (seat, window) = try await Self.seatWithOneInstance(sensing: sensing, marker: 560)
        seat.refreshTargetReadings()

        // Planted through the nucleus, which is the only way in: the public
        // handback refuses to create one, and a host failure leaves one behind.
        _ = seat.assignmentKit.release()
        #expect(seat.assignmentKit.restitution.outstanding == [window.id])

        let reference = Self.otherInstanceWindow(processID: FakeGeometry.distinctProcessID())
        sensing.additionalWindows[reference.windowNumber] = reference
        _ = try await seat.adopt(reference, platform: AppKitPlatform())
        #expect(seat.assignmentKit.lifecycle.isAssigned,
                "The next instance was handed over, which is what puts the older debt in the way")

        #expect(throws: SessionFailure.returnsStillOutstanding(windowNumbers: [window.id])) {
            try seat.releaseAssignedApplication()
        }
        #expect(seat.coherentState.outstandingReturns == [window.id])
    }
}
