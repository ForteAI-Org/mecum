//
//  QtAdoptionGeometryTests.swift
//  AgentSeatKit
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Qt adoption geometry")
struct QtAdoptionGeometryTests {
    @Test("a Qt window returns to its current body rather than a stale discovery frame")
    func settledHome() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let inbound = FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame)
        let settled = inbound.replacingFrame(inbound.frame.offsetBy(dx: 80, dy: 60))
        sensing.geometry = settled
        placing.bodyFrame = settled.frame
        placing.onMove = { origin in
            let moved = CGRect(
                origin: origin,
                size  : settled.frame.size
            )
            sensing.geometry = settled.replacingFrame(moved)
            placing.bodyFrame = moved
        }
        let seat = makeSeat(
            sensing: sensing,
            placing: placing
        )
        let adopted = try await seat.adopt(
            inbound,
            platform: QtPlatform()
        )
        #expect(adopted.originalFrame == settled.frame)
        let result = await seat.release(adopted)
        #expect(result == .returned)
        #expect(placing.moves.last == settled.frame.origin)
        #expect(!placing.moves.contains(inbound.frame.origin))
    }

    @Test("a Qt body read does not permit moving a replaced WindowServer identity")
    func replacedIdentity() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let inbound = FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame)
        let replacement = FakeGeometry.reference(
            frame       : inbound.frame,
            processID   : inbound.processID + 1,
            windowNumber: inbound.windowNumber
        )
        placing.bodyFrame = inbound.frame
        var readings = 0
        sensing.windowGeometryOverride = { number in
            guard number == inbound.windowNumber else { return nil }
            readings += 1
            return readings == 1 ? inbound : replacement
        }
        let seat = makeSeat(
            sensing: sensing,
            placing: placing
        )
        await #expect(throws: SeatInterruption.self) {
            try await seat.adopt(
                inbound,
                platform: QtPlatform()
            )
        }
        #expect(placing.moves.isEmpty)
        #expect(seat.adoptedWindows.isEmpty)
    }
}
