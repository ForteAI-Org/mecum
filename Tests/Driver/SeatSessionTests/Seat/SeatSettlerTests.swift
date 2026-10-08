//
//  SeatSettlerTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import CoreVideo
import Darwin
import Dispatch
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

        let window = FakeGeometry.identity()

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
            guard let frame = frame(showing: content(index), of: window, displayedAt: now)
            else { return .failure(.copyFailed) }
            return .success(frame)
        }

        /// A frame of `window` whose first byte is `value`, displayed at `displayedAt`.
        func frame(showing value: UInt8, of window: WindowIdentity, displayedAt: UInt64) -> SeatFrame? {
            guard let frame = makeControlledFrame(
                of: window, screenRect: CGRect(x: 0, y: 0, width: 8, height: 8), displayTime: displayedAt
            ) else { return nil }
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
            CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.storeBytes(of: value, toByteOffset: 0, as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, [])
            return frame
        }

        func sleep(_ duration: Duration) {
            slept.append(duration)
            now += UInt64(duration.components.seconds) * 1_000_000_000
                + UInt64(duration.components.attoseconds / 1_000_000_000)
        }

        var elapsed: UInt64 { now - SeatSettlerTests.start }
    }

    private func settle(
        _ stream  : ScriptedStream,
        cap       : Duration = SeatSettlerTests.cap,
        baselineOf: UInt8? = nil
    ) async -> SeatSettler.Ending {
        // The baseline is the frame shown just before the gesture, so before the wait began.
        let baseline = baselineOf.flatMap {
            stream.frame(showing: $0, of: stream.window, displayedAt: Self.start - 10 * Self.millisecond)
        }
        return await SeatSettler.wait(
            cap        : cap,
            baseline   : baseline,
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

    @Test("an effect drawn in the first frame after the input ends the wait as a change against the baseline")
    func effectAlreadyDrawnInTheFirstFrame() async {
        // The frame before the input shows 0; every frame after it shows 7, the first one included.
        let stream = ScriptedStream { _ in 7 }
        let ending = await settle(stream, baselineOf: 0)

        #expect(ending == .stableAgainstBaseline)
        let change = stream.displayed(0) - Self.start
        #expect(stream.elapsed >= change + 90 * Self.millisecond)
        #expect(stream.elapsed <= change + 90 * Self.millisecond + Self.interval)
        #expect(stream.elapsed < 300 * Self.millisecond, "well before the cap")
        #expect(stream.slept.isEmpty)
    }

    @Test("without a baseline the same stream is no change and waits the whole cap, as before")
    func sameStreamWithoutBaselineWaitsTheCap() async {
        let stream = ScriptedStream { _ in 7 }
        let ending = await settle(stream)

        #expect(ending == .quiet)
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("frames equal to the baseline are no change: the whole cap, so a new window is not missed")
    func noChangeAgainstTheBaselineWaitsTheCap() async {
        let stream = ScriptedStream { _ in 7 }
        let ending = await settle(stream, baselineOf: 7)

        #expect(ending == .quiet)
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("a change that comes after frames equal to the baseline is a change between later frames")
    func laterChangeIsNotAgainstTheBaseline() async {
        let stream = ScriptedStream { $0 < 2 ? 7 : 9 }
        let ending = await settle(stream, baselineOf: 7)

        #expect(ending == .stable)
        #expect(stream.elapsed < 300 * Self.millisecond)
    }

    @Test("an effect drawn at once that keeps changing still ends at the cap")
    func baselineChangeThatKeepsChangingEndsAtTheCap() async {
        let stream = ScriptedStream { $0.toByte }
        let ending = await settle(stream, baselineOf: 200)

        #expect(ending == .cap)
        #expect(stream.elapsed == 300 * Self.millisecond)
    }

    @Test("a source that declines is the fixed pause even with a baseline")
    func decliningSourceWithABaselineIsTheFixedPause() async {
        let stream = ScriptedStream { _ in 7 }
        stream.refusal = .notLive
        let ending = await settle(stream, baselineOf: 0)

        #expect(ending == .fallback(.notLive))
        #expect(stream.slept == [Self.cap])
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
          arguments: [LiveFrameFallback.notLive, .pinnedToDisplay, .recovering, .resting, .otherWindow])
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

    /// The baseline a settle uses is one copied before the delivery, of the window it settles, and
    /// young; any other is ignored and the wait is today's.
    @Test("a baseline of another window, displayed after the copy or too old is not used")
    func unusableBaselines() throws {
        let stream = ScriptedStream { _ in 0 }
        let window = stream.window
        let other  = FakeGeometry.identity(windowNumber: FakeGeometry.windowNumber + 1)
        let copied = Self.start
        func baseline(
            of identity: WindowIdentity, displayedAt: UInt64, markedAt: UInt64 = copied
        ) throws -> SeatSettler.Baseline {
            let frame = try #require(stream.frame(showing: 1, of: identity, displayedAt: displayedAt))
            return SeatSettler.Baseline(
                frame: frame, identity: identity, displayedAt: displayedAt, markedAt: markedAt
            )
        }

        let good = try baseline(of: window, displayedAt: copied - 5 * Self.millisecond)
        #expect(SeatSettler.reference(good, for: window, startedAt: copied + 40 * Self.millisecond) != nil)
        #expect(SeatSettler.reference(nil, for: window, startedAt: copied) == nil)

        let ofAnotherWindow = try baseline(of: other, displayedAt: copied - 5 * Self.millisecond)
        #expect(SeatSettler.reference(ofAnotherWindow, for: window, startedAt: copied + 40 * Self.millisecond) == nil)

        let displayedAfterTheCopy = try baseline(of: window, displayedAt: copied + 5 * Self.millisecond)
        #expect(SeatSettler.reference(displayedAfterTheCopy, for: window, startedAt: copied + 40 * Self.millisecond) == nil)

        let tooOld = copied + 2_001 * Self.millisecond
        #expect(SeatSettler.reference(good, for: window, startedAt: tooOld) == nil)
        #expect(SeatSettler.reference(good, for: window, startedAt: copied - 1) == nil, "never before its own copy")
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

    /// A running stream on the real clock with scripted pictures: the newest frame a request for
    /// "after 0" finds shows `before`, and every frame displayed after a real instant shows `after`,
    /// 33 ms later than the instant asked for, until `limit` requests have been answered.
    final class ScriptedLiveFrames: LiveWindowFrameSourcing {
        let window: WindowIdentity
        let before: UInt8
        let after : UInt8
        var limit = Int.max
        private(set) var asked = 0
        private let stream = ScriptedStream { _ in 0 }

        init(window: WindowIdentity, before: UInt8, after: UInt8) {
            self.window = window
            self.before = before
            self.after  = after
        }

        func liveFrame(
            of identity             : WindowIdentity,
            displayedAfter notBefore: UInt64,
            within bound            : Duration
        ) async -> Result<SeatFrame, LiveFrameFallback> {
            asked += 1
            guard asked <= limit else { return .failure(.noFrameInBound) }
            let isNewest = notBefore == 0
            let displayedAt = isNewest
                ? DispatchTime.now().uptimeNanoseconds - 5 * SeatSettlerTests.millisecond
                : notBefore + 33 * SeatSettlerTests.millisecond
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticks = displayedAt * UInt64(timebase.denom) / UInt64(timebase.numer)
            guard let frame = stream.frame(
                showing: isNewest ? before : after, of: window, displayedAt: ticks
            ) else { return .failure(.copyFailed) }
            return .success(frame)
        }
    }

    @Test("prepare copies the newest frame, and the wait that follows ends as a change against it")
    func prepareThenSettle() async throws {
        let context = try await ObservationAdmissionTests.composed(sender: FakeSender(), marker: 954)
        _ = try await observe(context.seat)
        let identity = try #require(context.window.reference.identity)
        let live = ScriptedLiveFrames(window: identity, before: 0, after: 7)
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat, liveFrames: live)
        let recorded = SleptDurations()
        let settler = SeatSettler(target: target, sleep: { recorded.append($0) })

        await settler.prepared()
        #expect(live.asked == 1)
        #expect(await settler.settled(cap: .milliseconds(300)) == .stableAgainstBaseline)
        #expect(recorded.values.isEmpty)

        // The baseline served that one wait: with none, the same frames are no change.
        live.limit = live.asked + 8
        #expect(await settler.settled(cap: .milliseconds(300)) == .quiet)
    }

    @Test("a stream with no frame to copy leaves no baseline, and the wait is today's")
    func prepareWithNothingToCopy() async throws {
        let context = try await ObservationAdmissionTests.composed(sender: FakeSender(), marker: 955)
        _ = try await observe(context.seat)
        let identity = try #require(context.window.reference.identity)
        let live = ScriptedLiveFrames(window: identity, before: 0, after: 7)
        live.limit = 0
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat, liveFrames: live)
        let settler = SeatSettler(target: target, sleep: { _ in })

        await settler.prepared()
        live.limit = 1 + 8
        #expect(await settler.settled(cap: .milliseconds(300)) == .quiet)
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
