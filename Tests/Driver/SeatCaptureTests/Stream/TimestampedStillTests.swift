//
//  TimestampedStillTests.swift
//  AgentSeatKit
//
//  Created by OpenAI Codex on 16/09/2026.
//

@testable import SeatCapture
import Testing

@Suite("Timestamp-qualified stream stills")
struct TimestampedStillTests {

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
