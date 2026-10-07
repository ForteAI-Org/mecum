//
//  StillTimestampMemoryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import SeatCapture
import SeatCore
@testable import SeatSession
import Testing

@Suite("The memory of a one-shot Still without display time")
struct StillTimestampMemoryTests {

    private let window = FakeGeometry.identity()
    private let rect   = CGRect(x: 0, y: 0, width: 32, height: 32)

    private func frame(displayTime: UInt64?) throws -> SeatFrame {
        try #require(makeControlledFrame(of: window, screenRect: rect, displayTime: displayTime))
    }

    /// What one request did: which captures ran and what the fallback was told.
    private struct Trace: Equatable {
        var oneShots      = 0
        var fallbacks     = 0
        var attemptsSpent = [Int]()
    }

    private func request(
        _ memory    : StillTimestampMemory,
        generation  : UInt64,
        oneShotTime : UInt64?,
        fallbackTime: UInt64 = 7
    ) async throws -> (frame: SeatFrame, trace: Trace) {
        var trace = Trace()
        let oneShot  = try frame(displayTime: oneShotTime)
        let fallback = try frame(displayTime: fallbackTime)
        let result = try await memory.timestamped(
            generation: generation,
            oneShot   : { trace.oneShots += 1; return oneShot },
            fallback  : { spent in
                trace.fallbacks += 1
                trace.attemptsSpent.append(spent)
                return fallback
            }
        )
        return (result, trace)
    }

    @Test("a miss falls back and is remembered, a new generation tries the Still again")
    func missIsRememberedPerGeneration() async throws {
        let memory = StillTimestampMemory()

        // The first request of a generation always tries the one-shot, and a miss falls back to
        // the stream Still after one spent attempt.
        let first = try await request(memory, generation: 1, oneShotTime: nil)
        #expect(first.trace == Trace(oneShots: 1, fallbacks: 1, attemptsSpent: [1]))
        #expect(first.frame.displayTime == 7)

        // Later requests of that generation go straight to the stream and spend no attempt.
        let second = try await request(memory, generation: 1, oneShotTime: nil)
        #expect(second.trace == Trace(oneShots: 0, fallbacks: 1, attemptsSpent: [0]))
        #expect(second.frame.displayTime == 7)

        // Another generation tries again; a Still that carries the time is returned as it is.
        let renewed = try await request(memory, generation: 2, oneShotTime: 42)
        #expect(renewed.trace == Trace(oneShots: 1, fallbacks: 0, attemptsSpent: []))
        #expect(renewed.frame.displayTime == 42)

        // And it keeps the fast path while it keeps carrying the time.
        let kept = try await request(memory, generation: 2, oneShotTime: 43)
        #expect(kept.trace == Trace(oneShots: 1, fallbacks: 0, attemptsSpent: []))
        #expect(kept.frame.displayTime == 43)
    }

    @Test("a Still with a display time clears a miss of its generation, a failure records nothing")
    func timestampClearsAndFailureRecordsNothing() async throws {
        let memory = StillTimestampMemory()
        struct Refused: Error {}

        await #expect(throws: Refused.self) {
            try await memory.timestamped(
                generation: 1,
                oneShot   : { throw Refused() },
                fallback  : { _ in throw Refused() }
            )
        }
        #expect(!memory.skipsOneShot(of: 1))

        memory.record(try frame(displayTime: nil), of: 1)
        #expect(memory.skipsOneShot(of: 1))
        #expect(!memory.skipsOneShot(of: 2))

        memory.record(try frame(displayTime: 5), of: 1)
        #expect(!memory.skipsOneShot(of: 1))
    }
}
