//
//  OperationalGeometryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The three geometries a held window has, on the seat rather than in a value:
/// the frame it is owed on its return, the frame it is operated at, and the
/// staging evidence. A resize moves the second and never the first, and a
/// window too large for the display is adapted rather than refused.
@Suite("Operational geometry")
@MainActor
struct OperationalGeometryTests {

    /// Waits for a condition the recovery loop reaches on its own cadence. The
    /// budget is the one the other recovery suites already wait with: the loop
    /// sleeps 250 ms between readings and the whole test bundle shares one
    /// MainActor, so a wall clock bound here is about starvation and never
    /// about the recovery.
    static func settle(
        _ condition   : @MainActor () -> Bool,
        within seconds: Double = 60
    ) async -> Bool {
        ProcessKeepAlive.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await EventLoopWait.sleep(.milliseconds(100))
        }
        return condition()
    }

    /// 880 by 640 where the seat took the window in at 800 by 600: a resize of
    /// 80 by 40 points, inside the display, at the same identity.
    static var resized: WindowReference {
        FakeGeometry.reference(frame: CGRect(
            origin: FakeGeometry.windowOrigin,
            size  : CGSize(width: 880, height: 640)
        ))
    }

    @Test("a settled resize becomes the operating geometry and the return is untouched")
    func aSettledResizeIsAdopted() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, adopted) = try await AgentSeatTests.adopted(sensing: sensing, placing: placing)
        let movesBefore = placing.moves.count

        sensing.geometry = Self.resized
        seat.report([.geometryChanged])
        #expect(seat.state == .recovering)

        let accepted = await RecoveryWait.settle(seat) { seat.state == .ready }
        #expect(accepted.satisfied, "the seat stayed in \(seat.state.rawValue): \(accepted)")

        let held = try #require(seat.adoptedWindows.first)
        #expect(held.reference.frame == Self.resized.frame)
        #expect(held.originalFrame == adopted.originalFrame,
                "what the window is owed does not move with a resize")
        #expect(seat.isStaged(held), "a resized window is not a stashed window")
        #expect(placing.moves.count == movesBefore,
                "a size is never answered by writing an origin")
        #expect(placing.resizes.isEmpty, "a window that fits the display is not adapted")
    }

    @Test("an observation taken before the resize is refused afterwards")
    func oldCoordinatesAreRefused() async throws {

        let sensing = FakeSensing()
        let sender  = FakeSender()
        let (seat, _) = try await AgentSeatTests.adopted(sensing: sensing, sender: sender)

        let turn        = try await seat.acquire()
        let observation = try await observedReference(seat)

        sensing.geometry = Self.resized
        seat.report([.geometryChanged])
        _ = await Self.settle { seat.state == .ready }

        await #expect(throws: (any Error).self) {
            try await seat.send(AgentSeatTests.click, observation: observation, turn: turn)
        }
        #expect(sender.sent.isEmpty, "no event was posted at a coordinate of the old frame")
        try? seat.release(turn)
    }

    /// The window the display cannot hold. The seat adapts it, records the
    /// frame it was found at, and the adoption goes through: the consumer used
    /// to be told to make the window smaller by hand.
    @Test("a window larger than the display is adapted and still owes its own frame")
    func aTooLargeWindowIsAdapted() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let tooLarge = CGRect(
            x     : 100,
            y     : 100,
            width : FakeGeometry.virtual.width  + 300,
            height: FakeGeometry.virtual.height + 200
        )
        let window = FakeGeometry.reference(frame: tooLarge)
        sensing.geometry = window
        placing.bodyFrame = tooLarge
        placing.onMove = { origin in
            sensing.geometry = window.replacingFrame(
                CGRect(origin: origin, size: FakeGeometry.virtual.size)
            )
        }

        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(window, platform: AppKitPlatform())

        #expect(placing.resizes.map(\.size) == [FakeGeometry.virtual.size])
        #expect(adopted.reference.frame.size == FakeGeometry.virtual.size,
                "it is operated at the size the display can hold")
        #expect(adopted.originalFrame == tooLarge,
                "and it still owes the person the frame it was found at")
        #expect(FakeGeometry.virtual.contains(adopted.reference.frame))
    }

    @Test("an application that will not take the smaller size is refused with both sizes")
    func anAdaptationTheApplicationRefuses() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let tooLarge = CGRect(
            x     : 100,
            y     : 100,
            width : FakeGeometry.virtual.width  + 300,
            height: FakeGeometry.virtual.height + 200
        )
        let window = FakeGeometry.reference(frame: tooLarge)
        sensing.geometry  = window
        placing.bodyFrame = tooLarge
        // A window with a minimum size of its own takes the write and keeps
        // what it had, which is the same conclusion as refusing the attribute.
        placing.resizeResult = tooLarge.size

        let seat = makeSeat(sensing: sensing, placing: placing)

        await #expect(throws: SessionFailure.windowDoesNotFit(
            windowNumber: window.windowNumber,
            size        : tooLarge.size,
            bounds      : FakeGeometry.virtual.size
        )) {
            try await seat.adopt(window, platform: AppKitPlatform())
        }
        #expect(placing.moves.isEmpty, "nothing was moved")
        #expect(seat.adoptedWindows.isEmpty)
    }
}
