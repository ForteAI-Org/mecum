//
//  FrameReceiverTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
@testable import SeatCapture
import Synchronization
import Testing

/// A main-actor hop that does not happen until the test says so.
///
/// The whole newest-wins slot is about the window between a frame arriving and
/// the main actor presenting the previous one. With the real
/// `DispatchQueue.main.async` that window closes whenever the machine feels
/// like it, so an assertion about coalescence would be a coin toss; here the
/// test holds the window open and closes it on purpose.
nonisolated final class ManualHop: @unchecked Sendable {

    private let blocks = Mutex<[@Sendable () -> Void]>([])

    var pendingCount: Int { blocks.withLock { $0.count } }

    var hop: @Sendable (@escaping @Sendable () -> Void) -> Void {
        { [self] block in blocks.withLock { $0.append(block) } }
    }

    /// Runs every queued block, in order, the way the main queue would.
    func drain() {
        let queued = blocks.withLock { pending -> [@Sendable () -> Void] in
            defer { pending.removeAll() }
            return pending
        }
        for block in queued { block() }
    }
}

/// The frames the presented side actually received, in order.
nonisolated final class PresentedFrames: @unchecked Sendable {

    private let received = Mutex<[UInt64]>([])

    var receivedAt: [UInt64] { received.withLock { $0 } }

    var present: @MainActor @Sendable (SeatFrame, UInt64) -> Void {
        { [self] frame, _ in received.withLock { $0.append(frame.receivedAt) } }
    }
}

/// The suite is on the main actor because the hop is: the receiver hands the
/// frame over with `MainActor.assumeIsolated`, which is a real check and not a
/// promise, so a `drain()` from anywhere else would trap.
@Suite("The newest-wins slot and the generation gate")
@MainActor
struct FrameReceiverTests {

    private func makeReceiver(
        displayGeneration: UInt64 = 7,
        hop              : ManualHop,
        presented        : PresentedFrames
    ) -> FrameReceiver {
        FrameReceiver(
            displayGeneration: displayGeneration,
            present          : presented.present,
            stopped          : { _, _, _ in },
            hop              : hop.hop
        )
    }

    @Test("a frame that arrives before the previous one was presented replaces it")
    func coalescingCounts() throws {
        let hop       = ManualHop()
        let presented = PresentedFrames()
        let receiver  = makeReceiver(hop: hop, presented: presented)

        // Four frames, no main actor in between: one waits, three are thrown
        // away. That is the pool contract in behaviour, and the count is the
        // primary quality signal.
        for tick in UInt64(1)...4 {
            let frame = try #require(makeFakeFrame(displayGeneration: 7, receivedAt: tick))
            receiver.deliver(frame)
        }

        #expect(receiver.counts.produced  == 4)
        #expect(receiver.counts.coalesced == 3)
        #expect(receiver.counts.stale     == 0)
        // One hop for four frames: the main actor is asked once and finds the
        // newest frame waiting for it.
        #expect(hop.pendingCount == 1)

        hop.drain()
        #expect(presented.receivedAt == [4], "the newest frame is the one presented")

        // The slot is empty again, so the next frame asks for a new hop.
        let next = try #require(makeFakeFrame(displayGeneration: 7, receivedAt: 5))
        receiver.deliver(next)
        #expect(receiver.counts.coalesced == 3)
        #expect(hop.pendingCount == 1)
        hop.drain()
        #expect(presented.receivedAt == [4, 5])
    }

    @Test("with the main actor keeping up, nothing is coalesced")
    func noCoalescingWhenDrained() throws {
        let hop       = ManualHop()
        let presented = PresentedFrames()
        let receiver  = makeReceiver(hop: hop, presented: presented)

        for tick in UInt64(1)...5 {
            let frame = try #require(makeFakeFrame(displayGeneration: 7, receivedAt: tick))
            receiver.deliver(frame)
            hop.drain()
        }
        #expect(receiver.counts.produced  == 5)
        #expect(receiver.counts.coalesced == 0)
        #expect(presented.receivedAt == [1, 2, 3, 4, 5])
    }

    @Test("a frame from an older display generation is dropped, not presented")
    func staleGenerationIsDropped() throws {
        let hop       = ManualHop()
        let presented = PresentedFrames()
        let receiver  = makeReceiver(displayGeneration: 7, hop: hop, presented: presented)

        let stale = try #require(makeFakeFrame(displayGeneration: 6, receivedAt: 1))
        receiver.deliver(stale)

        #expect(receiver.counts.stale    == 1)
        #expect(receiver.counts.produced == 0)
        #expect(hop.pendingCount == 0)
        hop.drain()
        #expect(presented.receivedAt.isEmpty, "pixels of a display that is gone are never shown")
    }

    @Test("once the stream refuses further frames, the ones in flight are dropped")
    func refusalDropsFramesInFlight() throws {
        let hop       = ManualHop()
        let presented = PresentedFrames()
        let receiver  = makeReceiver(displayGeneration: 7, hop: hop, presented: presented)

        let accepted = try #require(makeFakeFrame(displayGeneration: 7, receivedAt: 1))
        receiver.deliver(accepted)
        #expect(receiver.counts.produced == 1)

        // This is what stop() does. A frame already inside the ScreenCaptureKit
        // callback at that moment must not reach a layer whose display is being
        // taken away.
        receiver.refuseFurtherFrames()
        receiver.refuseFurtherFrames()

        let inFlight = try #require(makeFakeFrame(displayGeneration: 7, receivedAt: 2))
        receiver.deliver(inFlight)
        #expect(receiver.counts.produced == 1)
        #expect(receiver.counts.stale    == 1)

        hop.drain()
        #expect(presented.receivedAt.isEmpty, "the frame queued before stop is also refused")
        #expect(receiver.counts.stale == 2)
    }
}
