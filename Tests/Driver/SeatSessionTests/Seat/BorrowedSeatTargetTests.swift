//
//  BorrowedSeatTargetTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import SeatCore
import SeatDriving
@testable import SeatSession
import Testing

/// A `SeatTarget` borrowing a seat another owner holds, on the controlled seat this bundle composes:
/// the assignment, selection, issuer and admission `SeatHost` composes, with evidence supplied in
/// place of a display.
///
/// It lives in this bundle because the controlled seat does: its fakes are this bundle's and
/// nothing else can reach them. It proves the borrow's contract with the seat and nothing about
/// macOS. The host is never started here, so what `stop` does not do to a live host is read from
/// the code and left to the live spike in `SeatBrokerTests`.
@MainActor
@Suite("Borrowed seat target")
struct BorrowedSeatTargetTests {

    /// A seat with one window its owner adopted and observed once, which gives the surface the
    /// second agreeing reading it needs, and a target borrowing that seat with an unstarted host.
    static func borrowed(
        sender: FakeSender = FakeSender()
    ) async throws -> (seat: AgentSeat, window: AdoptedWindow, host: SeatHost, target: SeatTarget) {
        let context = try await ObservationAdmissionTests.composed(sender: sender, marker: 950)
        _ = try await observe(context.seat)
        let host = SeatHost()
        return (context.seat, context.window, host, SeatTarget(borrowing: host, seat: context.seat))
    }

    @Test("a borrowed target refuses to start the host it borrowed and keeps the seat it was given")
    func aBorrowedTargetRefusesToStart() async throws {

        let context = try await Self.borrowed()

        await #expect(throws: SeatDrivingFailure.borrowedLifecycle) { try await context.target.start() }
        #expect(context.host.state == .off)
        #expect(context.host.displayID == nil)
        #expect(try context.target.agentSeat() === context.seat)
    }

    @Test("a borrowed target keeps the observation it took, and a spent one is replaced by a new look")
    func aBorrowedTargetKeepsItsObservation() async throws {

        let context = try await Self.borrowed()

        let delivery = try await context.target.observe()
        #expect(context.target.lastWindowGeometry == delivery.geometry)
        #expect(context.target.lastCapturedWindow?.id == context.window.id)
        #expect(try await context.target.currentObservation().reference == delivery.reference)

        context.target.spendObservation()
        #expect(try await context.target.currentObservation().reference != delivery.reference)
    }

    @Test("an observation either holder takes supersedes the other's, and the refused Command posts nothing")
    func eitherHoldersObservationSupersedesTheOther() async throws {

        let sender   = FakeSender()
        let context  = try await Self.borrowed(sender: sender)
        let actuator = SeatActuator(target: context.target)
        let pid      = context.window.reference.processID

        // The engine perceives through the borrow, then the owner observes before the gesture goes.
        let perceived = try await context.target.observe()
        let owners    = try await observe(context.seat)
        let frame     = perceived.geometry.window.frame
        await #expect(throws: ObservationAdmissionRefusal.referenceSuperseded) {
            try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)), in: pid)
        }
        #expect(sender.sent.isEmpty)
        // The engine confirms a failed delivery too, and that is what gives the Turn back.
        await actuator.confirm(.unknown, in: pid)
        #expect(context.seat.currentTurn == nil)

        // The refusal cost the owner nothing: its observation still admits its Command.
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            ObservationAdmissionTests.click,
            observation: owners.reference,
            turn       : turn
        )
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
        #expect(sender.sent.count == 1)

        // The reverse: a look through the borrow leaves the owner's kept reference stale.
        let ownersNext = try await observe(context.seat)
        _ = try await context.target.observe()
        let second = try await context.seat.acquire()
        await #expect(throws: ObservationAdmissionRefusal.referenceSuperseded) {
            try await context.seat.send(
                ObservationAdmissionTests.click,
                observation: ownersNext.reference,
                turn       : second
            )
        }
        try context.seat.release(second)
        #expect(sender.sent.count == 1)
    }

    @Test("stopping a borrowed target ends the borrow and leaves the seat and its window with the owner")
    func stoppingABorrowedTargetLeavesTheSeatWithItsOwner() async throws {

        let sender  = FakeSender()
        let context = try await Self.borrowed(sender: sender)
        _ = try await context.target.observe()

        await context.target.stop()

        #expect(context.target.lastWindowGeometry == nil)
        #expect(context.target.lastCapturedWindow == nil)
        #expect(throws: SeatDrivingFailure.notAdopted) { try context.target.agentSeat() }
        #expect(context.seat.adoptedWindows.map(\.id) == [context.window.id])
        #expect(context.host.state == .off)

        let owners  = try await observe(context.seat)
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            ObservationAdmissionTests.click,
            observation: owners.reference,
            turn       : turn
        )
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
        #expect(sender.sent.count == 1)
    }

    @Test("a revoked borrow refuses to observe or act, and posts nothing, while the owner keeps its seat")
    func aRevokedBorrowRefuses() async throws {

        let sender   = FakeSender()
        let context  = try await Self.borrowed(sender: sender)
        let actuator = SeatActuator(target: context.target)
        let perceived = try await context.target.observe()

        // `stop` is what the broker's driver calls on every borrow it lent, before it adopts again.
        await context.target.stop()

        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.observe() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.currentObservation() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.windowStill() }
        await #expect(throws: SeatDrivingFailure.notAdopted) { try await context.target.displayStill() }
        let frame = perceived.geometry.window.frame
        await #expect(throws: SeatDrivingFailure.notAdopted) {
            try await actuator.perform(.click(at: CGPoint(x: frame.midX, y: frame.midY)),
                                       in: context.window.reference.processID)
        }
        #expect(sender.sent.isEmpty)
        #expect(context.seat.currentTurn == nil)
        #expect(context.seat.adoptedWindows.map(\.id) == [context.window.id])
    }
}
