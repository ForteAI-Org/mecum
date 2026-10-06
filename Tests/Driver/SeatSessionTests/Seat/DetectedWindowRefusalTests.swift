//
//  DetectedWindowRefusalTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 06/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// A window the application opens that the seat cannot take in, and the seat
/// that keeps working.
///
/// Measured on DaVinci Resolve: a drag from the media pool to the timeline made
/// Qt put up its drag image, 101 by 88 points at level 1000, at the real cursor
/// on the person's screen. The follower tried to move it, the move was never
/// confirmed, the rollback could not put back a window that follows the cursor,
/// and the seat failed for good.
@MainActor
@Suite("A detected window the seat cannot take in")
struct DetectedWindowRefusalTests {

    static let dragImageNumber = 790
    static let dragLevel       = 1000

    /// Moves the window, at its own size, somewhere that is neither where the
    /// seat asked nor where it was found, on every write: a surface that
    /// follows the cursor.
    static func followsTheCursor(
        _ windowNumber: Int,
        _ sensing     : FakeSensing,
        _ placing     : FakePlacing
    ) {
        let steps = Holder<CGFloat>(0)
        placing.onMove = { _ in
            steps.value += 37
            let size = sensing.additionalWindows[windowNumber]?.frame.size ?? .zero
            sensing.additionalWindows[windowNumber] = AppWindowFollowTests.reference(
                windowNumber,
                frame: CGRect(origin: CGPoint(x: 40 + steps.value, y: 60), size: size)
            )
        }
    }

    @Test("a drag image above the menus is never moved, and the seat stays on its target")
    func aDragImageIsLeftAlone() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await AppWindowFollowTests.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_061
        )
        let movesBefore = placing.moves.count

        _ = AppWindowFollowTests.offer(
            Self.dragImageNumber,
            to   : sensing,
            placing,
            frame: CGRect(x: 300, y: 240, width: 101, height: 88),
            level: Self.dragLevel
        )
        Self.followsTheCursor(Self.dragImageNumber, sensing, placing)
        await AppWindowFollowTests.pass(seat)

        #expect(placing.moves.count == movesBefore, "nothing is written for a drag image")
        #expect(seat.state == .ready)
        #expect(seat.adoptedWindows.map(\.id) == [first.id])
        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == first.reference.identity)
    }

    @Test("a detected window that can be neither taken in nor put back fails nothing")
    func aRefusedDetectedWindowFailsNothing() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, first) = try await AppWindowFollowTests.followingSeat(
            sensing: sensing,
            placing: placing,
            marker : 7_062
        )

        _ = AppWindowFollowTests.offer(AppWindowFollowTests.secondWindowNumber, to: sensing, placing)
        Self.followsTheCursor(AppWindowFollowTests.secondWindowNumber, sensing, placing)
        await AppWindowFollowTests.pass(seat)

        #expect(seat.lastAdoptionFailure?.restoration == .refused, "the sequence of the live run")
        #expect(seat.state == .ready, "a window the seat found by itself fails nothing")
        #expect(seat.currentTarget?.id == first.id)
        #expect(seat.hasOutstandingWindowReturns, "what it is owed stays in the ledger")
        let delivery = try await observe(seat)
        #expect(delivery.reference.recipient == first.reference.identity)

        // A later window is still taken in: the refused one does not hold the follower up.
        _ = AppWindowFollowTests.offer(AppWindowFollowTests.thirdWindowNumber, to: sensing, placing)
        await AppWindowFollowTests.pass(seat)
        #expect(seat.adoptedWindows.map(\.id).contains(AppWindowFollowTests.thirdWindowNumber))
    }

    @Test("a window the consumer adopts that can be neither taken in nor put back still fails the seat")
    func aRefusedExplicitAdoptionStillFails() async throws {

        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat    = makeSeat(sensing: sensing, placing: placing, marker: 7_063)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())

        let other = AppWindowFollowTests.reference(AppWindowFollowTests.secondWindowNumber)
        sensing.additionalWindows[other.windowNumber] = other
        placing.bodyFrames[other.windowNumber]        = other.frame
        Self.followsTheCursor(other.windowNumber, sensing, placing)
        await #expect(throws: (any Error).self) {
            try await seat.adopt(other, platform: AppKitPlatform())
        }

        #expect(seat.state == .failed)
        #expect(seat.failureIssues.isEmpty, "no Issue names this stop")
        #expect(seat.lastAdoptionFailure?.window.windowNumber == other.windowNumber,
                "the failure the consumer's sentence is built from")
        #expect(seat.lastAdoptionFailure?.restoration == .refused)
    }
}
