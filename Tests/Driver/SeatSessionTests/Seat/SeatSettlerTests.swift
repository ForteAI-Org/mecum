//
//  SeatSettlerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import CoreVideo
import SeatCapture
import SeatCore
import SeatDriving
@testable import SeatSession
import Testing

/// The adaptive wait after a gesture over a scripted 30 fps window stream and a clock that moves
/// only when a frame arrives or a wait sleeps. No stream, no display, no real time.
@MainActor
@Suite("Settling on the running window stream")
struct SeatSettlerTests {

    nonisolated private static let millisecond: UInt64 = 1_000_000
    nonisolated private static let start      : UInt64 = 5_000 * millisecond
    nonisolated private static let interval   : UInt64 = 33_333_333
    nonisolated private static let cap        : Duration = .milliseconds(300)

    /// A running stream of one window: frame `k` is displayed at `start + 17 ms + k` frame intervals
    /// and shows `content(k)`; it answers `refusal` from frame `refusingFrom` on.
    @MainActor
    final class ScriptedStream {
        var now = SeatSettlerTests.start
        var slept: [Duration] = []
        var asked = 0
        let content: (Int) -> UInt8
        var refusal: LiveFrameFallback?
        var refusingFrom = 0

        private let window = FakeGeometry.identity()

        init(content: @escaping (Int) -> UInt8) { self.content = content }

        func displayed(_ index: Int) -> UInt64 {
            SeatSettlerTests.start + 17 * SeatSettlerTests.millisecond + UInt64(index) * SeatSettlerTests.interval
        }

        func next(after: UInt64, within bound: Duration) -> Result<SeatFrame, LiveFrameFallback> {
            defer { asked += 1 }
            if let refusal, asked >= refusingFrom { return .failure(refusal) }
            var index = 0
            while displayed(index) <= after { index += 1 }
            let limit = now + UInt64(bound.components.seconds) * 1_000_000_000
                + UInt64(bound.components.attoseconds / 1_000_000_000)
            guard displayed(index) <= limit else {
                now = limit
                return .failure(.noFrameInBound)
            }
            now = displayed(index)
            guard let frame = makeControlledFrame(
                of: window, screenRect: CGRect(x: 0, y: 0, width: 8, height: 8), displayTime: now
            ) else { return .failure(.copyFailed) }
            let value = content(index)
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
            CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.storeBytes(of: value, toByteOffset: 0, as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, [])
            return .success(frame)
        }

        func sleep(_ duration: Duration) {
            slept.append(duration)
            now += UInt64(duration.components.seconds) * 1_000_000_000
                + UInt64(duration.components.attoseconds / 1_000_000_000)
        }

        var elapsed: UInt64 { now - SeatSettlerTests.start }
    }

    private func settle(_ stream: ScriptedStream, cap: Duration = SeatSettlerTests.cap) async -> SeatSettler.Ending {
        await SeatSettler.wait(
            cap        : cap,
            next       : { stream.next(after: $0, within: $1) },
            displayedAt: { $0.displayTime },
            now        : { stream.now },
            sleep      : { stream.sleep($0) }
        )
    }

    @Test("frames that change and then stay identical end the wait one stability interval after the last change")
    func changeThenStable() async {
        // Frames 1 and 2 change, the third onwards repeat the second.
        let stream = ScriptedStream { min($0, 2).toByte }
        let ending = await settle(stream)

        #expect(ending == .stable)
        let lastChange = stream.displayed(2) - Self.start
        #expect(stream.elapsed >= lastChange + 90 * Self.millisecond)
        #expect(stream.elapsed <= lastChange + 90 * Self.millisecond + Self.interval)
        #expect(stream.elapsed < 300 * Self.millisecond, "before the cap")
        #expect(stream.slept.isEmpty)
    }

    @Test("frames that keep changing end the wait at the cap, not later")
    func keepsChanging() async {
        let stream = ScriptedStream { $0.toByte }
        let ending = await settle(stream)

        #expect(ending == .cap)
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("no frame changing waits the whole cap, so a new window is not missed")
    func noChangeWaitsTheCap() async {
        let stream = ScriptedStream { _ in 7 }
        let ending = await settle(stream)

        #expect(ending == .quiet)
        #expect(stream.elapsed == 300 * Self.millisecond)
        #expect(SeatSettler.stabilityInterval == .milliseconds(90))
    }

    @Test("a source that declines at once is today's fixed pause exactly",
          arguments: [LiveFrameFallback.notLive, .pinnedToDisplay, .recovering, .otherWindow])
    func unavailableSourceIsTheFixedPause(_ refusal: LiveFrameFallback) async {
        let stream = ScriptedStream { _ in 7 }
        stream.refusal = refusal
        let ending = await settle(stream)

        #expect(ending == .fallback(refusal))
        #expect(stream.slept == [Self.cap])
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("a source that goes away during the wait waits out the rest of the cap")
    func sourceGoneMidWait() async {
        let stream = ScriptedStream { $0.toByte }
        stream.refusal = .otherWindow
        stream.refusingFrom = 2
        let ending = await settle(stream)

        #expect(ending == .fallback(.otherWindow))
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("a 400 ms cap, the menu press's, is the same wait with its own ceiling")
    func menuCap() async {
        let changing = ScriptedStream { $0.toByte }
        #expect(await settle(changing, cap: .milliseconds(400)) == .cap)
        #expect(changing.elapsed == 400 * Self.millisecond)

        let settling = ScriptedStream { min($0, 2).toByte }
        #expect(await settle(settling, cap: .milliseconds(400)) == .stable)
        #expect(settling.elapsed < 300 * Self.millisecond)
    }

    @Test("a target with no running stream sleeps exactly the cap it is given")
    func noLiveSourceSleepsTheCap() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let recorded = SleptDurations()
        let settler = SeatSettler(target: context.target, sleep: { recorded.append($0) })

        #expect(await settler.settled(cap: .milliseconds(300)) == .fallback(.notLive))
        #expect(await settler.settled(cap: .milliseconds(400)) == .fallback(.notLive))
        #expect(recorded.values == [.milliseconds(300), .milliseconds(400)])
    }

    /// A running stream that declines, and remembers which window it was asked for.
    final class DecliningLiveFrames: LiveWindowFrameSourcing {
        private(set) var asked: [WindowIdentity] = []
        func liveFrame(
            of identity             : WindowIdentity,
            displayedAfter notBefore: UInt64,
            within bound            : Duration
        ) async -> Result<SeatFrame, LiveFrameFallback> {
            asked.append(identity)
            return .failure(.pinnedToDisplay)
        }
    }

    @Test("a borrowed target's running stream is asked for the seat's window, and a refusal is the fixed pause")
    func borrowedStreamIsAskedForTheTargetWindow() async throws {
        let context = try await ObservationAdmissionTests.composed(sender: FakeSender(), marker: 953)
        _ = try await observe(context.seat)
        let live = DecliningLiveFrames()
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat, liveFrames: live)
        let recorded = SleptDurations()
        let settler = SeatSettler(target: target, sleep: { recorded.append($0) })

        #expect(await settler.settled(cap: .milliseconds(300)) == .fallback(.pinnedToDisplay))
        #expect(live.asked == [try #require(context.window.reference.identity)])
        let slept = try #require(recorded.values.first)
        #expect(recorded.values.count == 1)
        #expect(slept <= .milliseconds(300) && slept > .milliseconds(250), "the rest of the cap, from its start")
    }

    /// Durations a fallback slept, kept on the main actor the settler waits on.
    final class SleptDurations: @unchecked Sendable {
        private(set) var values: [Duration] = []
        func append(_ value: Duration) { values.append(value) }
    }
}

private extension Int {
    var toByte: UInt8 { UInt8(truncatingIfNeeded: self + 1) }
}
