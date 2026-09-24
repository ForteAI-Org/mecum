//
//  WindowAdoptionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing
import VirtualScreens

@Suite("Window adoption rollback")
@MainActor
struct WindowAdoptionTests {
    @Test("a window stashed before adoption is staged before waiting for placement")
    func stashedBeforeAdoption() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        sensing.geometry = original.replacingFrame(CGRect(x: -227, y: 758, width: 154, height: 168))
        placing.onMove = { origin in
            if origin == original.frame.origin { sensing.geometry = original }
        }
        placing.onStage = { sensing.geometry = FakeGeometry.adoptedWindow }
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(original)
        #expect(placing.stages == 1)
        #expect(seat.isStaged(adopted))
        #expect(FakeGeometry.virtual.contains(adopted.reference.frame))
    }

    @Test("an unconfirmed partial move returns to the original frame")
    func unconfirmedMoveReturns() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        placing.onMove = { origin in
            let position = origin == original.frame.origin ? origin : CGPoint(x: 1300, y: 100)
            sensing.geometry = original.replacingFrame(CGRect(origin: position, size: original.frame.size))
        }
        let seat = makeSeat(sensing: sensing, placing: placing)
        await #expect(throws: (any Error).self) { try await seat.adopt(original) }
        #expect(placing.moves.last == original.frame.origin)
        #expect(sensing.geometry?.frame == original.frame)
        #expect(seat.adoptedWindows.isEmpty)
        let outcomes = await seat.releaseAllWindows(.returnToUserSeat)
        #expect(outcomes[original.windowNumber] == .returned)
    }

    @Test("cancellation after movement rolls back without reporting adoption success")
    func cancellationReturns() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        var task: Task<AdoptedWindow, any Error>?
        placing.onMove = { origin in
            sensing.geometry = original.replacingFrame(CGRect(origin: origin, size: original.frame.size))
            if origin != original.frame.origin { task?.cancel() }
        }
        let seat = makeSeat(sensing: sensing, placing: placing)
        task = Task { try await seat.adopt(original) }
        let running = try #require(task)
        do {
            _ = try await running.value
            Issue.record("A cancelled adoption was reported as successful")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(sensing.geometry?.frame == original.frame)
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test("an AX error after a partial write preserves evidence and rolls back")
    func partialWriteError() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        placing.afterMoveError = DisplayFailure.attributeWriteFailed(attribute: "AXPosition", code: .cannotComplete)
        placing.onMove = { origin in
            sensing.geometry = original.replacingFrame(
                CGRect(origin: origin, size: original.frame.size)
            )
        }
        let seat = makeSeat(sensing: sensing, placing: placing)
        await #expect(throws: DisplayFailure.self) { try await seat.adopt(original) }
        let failure = try #require(seat.lastAdoptionFailure)
        #expect(failure.lastObservedFrame == FakeGeometry.adoptedWindow.frame)
        #expect(failure.restoration == .returned)
        #expect(failure.restorationError is DisplayFailure)
        #expect(sensing.geometry?.frame == original.frame)
        #expect(!seat.hasPendingWindowRestorations)
    }

    @Test("an unverified rollback is retained and retried by teardown")
    func rollbackRetained() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        placing.moveError = DisplayFailure.attributeNotSettable("AXPosition")
        let seat = makeSeat(sensing: sensing, placing: placing)
        await #expect(throws: DisplayFailure.self) { try await seat.adopt(original) }
        #expect(seat.lastAdoptionFailure?.restoration == .refused)
        #expect(seat.state == .failed)
        #expect(seat.hasPendingWindowRestorations)
        placing.moveError = nil
        placing.onMove = { _ in sensing.geometry = original }
        let outcomes = await seat.releaseAllWindows(.returnToUserSeat)
        #expect(outcomes[original.windowNumber] == .returned)
        #expect(sensing.geometry?.frame == original.frame)
    }

    @Test("teardown waits for an in-flight adoption rollback and prevents late success")
    func teardownDuringAdoption() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        let seat = makeSeat(sensing: sensing, placing: placing)
        sensing.geometry = original.replacingFrame(
            CGRect(x: -227, y: 758, width: 154, height: 168)
        )
        var teardown: Task<[Int: WindowReleaseOutcome], Never>?
        var teardownStarted = false
        placing.onMove = { origin in
            if origin == original.frame.origin { sensing.geometry = original }
        }
        placing.onStageWait = {
            teardown = Task {
                teardownStarted = true
                return await seat.releaseAllWindows(.returnToUserSeat)
            }
            while !teardownStarted { await Task.yield() }
        }
        await #expect(throws: SessionFailure.self) { try await seat.adopt(original) }
        let task = try #require(teardown)
        let outcomes = await task.value
        #expect(outcomes[original.windowNumber] == .returned)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(seat.state != .ready)
        await #expect(throws: SessionFailure.self) { try await seat.adopt(original) }
    }


    @Test("release requires the original AX body behind a physical Stage Manager thumbnail", arguments: [true, false])
    func stashedReturn(bodyReturned: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(original)
        placing.onMove = { _ in
            sensing.geometry = original.replacingFrame(
                CGRect(x: -227, y: 758, width: 154, height: 168)
            )
            placing.bodyFrame = bodyReturned ? original.frame : adopted.reference.frame
        }
        let outcome = await seat.release(adopted)
        #expect(outcome == (bodyReturned ? .returned : .refused))
    }

    @Test("release waits for a late Stage Manager thumbnail without repeating AXPosition")
    func lateStashedReturn() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let original = FakeGeometry.userSeatWindow
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(original)
        #expect(adopted.originalServerFrame == nil)

        let transition = original.replacingFrame(
            CGRect(x: 1140, y: 1012, width: original.frame.width, height: original.frame.height)
        )
        let thumbnail = original.replacingFrame(CGRect(x: 15, y: 117, width: 100, height: 128))
        var readings = 0
        sensing.windowGeometryOverride = { windowNumber in
            guard windowNumber == original.windowNumber else { return nil }
            readings += 1
            return readings <= 4 ? transition : thumbnail
        }
        placing.onMove = { _ in placing.bodyFrame = original.frame }

        let outcome = await seat.release(adopted)
        #expect(outcome == .returned)
        #expect(readings >= 6)
        #expect(placing.moves.filter { $0 == original.frame.origin }.count == 1)
    }

}
