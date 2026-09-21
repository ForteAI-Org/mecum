//
//  TimestampedStillTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCapture
import Darwin
import Dispatch
import SeatCore
import Testing

@Suite("Timestamp-qualified stream stills")
struct TimestampedStillTests {

    private func futureDisplayTime(milliseconds: UInt64) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return mach_absolute_time()
            + milliseconds * 1_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    @Test("a scheduled frame is delivered only after its unchanged display timestamp")
    func waitsForScheduledDisplay() async throws {
        let timestamp = futureDisplayTime(milliseconds: 100)
        let frame = try #require(makeFakeFrame(displayTime: timestamp))
        let frames = AsyncStream<SeatFrame> { continuation in
            continuation.yield(frame)
            continuation.finish()
        }
        let result = try await SeatCaptureStream.firstTimestampedFrame(
            in: frames,
            deadline: CaptureDeadline(timeout: .seconds(1))
        )
        #expect(result.displayTime == timestamp)
        guard case .qualified = MachAbsoluteContentClock().contentAge(
            of: result,
            atNanoseconds: DispatchTime.now().uptimeNanoseconds
        ) else {
            Issue.record("The delivered frame still has a future display timestamp")
            return
        }
    }

    @Test("a zero display time does not hide a later valid frame")
    func skipsMalformedTimestamp() async throws {
        let malformed = try #require(makeFakeFrame(displayTime: 0))
        let valid = try #require(makeFakeFrame(displayTime: 42))
        let frames = AsyncStream<SeatFrame> { continuation in
            continuation.yield(malformed)
            continuation.yield(valid)
            continuation.finish()
        }
        let result = try await SeatCaptureStream.firstTimestampedFrame(
            in: frames,
            deadline: CaptureDeadline(timeout: .seconds(1))
        )
        #expect(result.displayTime == 42)
    }

    @Test("a scheduled display outside the request budget cannot extend that budget")
    func futureFrameHonorsDeadline() async throws {
        let pair = AsyncStream<SeatFrame>.makeStream()
        pair.continuation.yield(try #require(makeFakeFrame(
            displayTime: futureDisplayTime(milliseconds: 1_000)
        )))
        defer { pair.continuation.finish() }
        await #expect(throws: CaptureFailure.timedOut(.still)) {
            try await SeatCaptureStream.firstTimestampedFrame(
                in: pair.stream,
                deadline: CaptureDeadline(timeout: .milliseconds(20))
            )
        }
    }

    @Test("a frame without display time is skipped for one that has it")
    func skipsUntimestampedFrame() async throws {

        let missing = try #require(makeFakeFrame(displayTime: nil))
        let present = try #require(makeFakeFrame(displayTime: 42))
        let frames = AsyncStream<SeatFrame> { continuation in
            continuation.yield(missing)
            continuation.yield(present)
            continuation.finish()
        }

        let result = try await SeatCaptureStream.firstTimestampedFrame(
            in      : frames,
            deadline: CaptureDeadline(timeout: .seconds(1))
        )

        #expect(result.displayTime == 42)
    }

    @Test("cancelling a timestamp wait ends it without accepting absent evidence")
    func cancellationEndsTheWait() async {

        let pair = AsyncStream<SeatFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiting = Task {
            try await SeatCaptureStream.firstTimestampedFrame(
                in      : pair.stream,
                deadline: CaptureDeadline(timeout: .seconds(5))
            )
        }

        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        pair.continuation.finish()
    }
}
