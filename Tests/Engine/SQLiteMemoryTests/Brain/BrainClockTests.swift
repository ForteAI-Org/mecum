//
//  BrainClockTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation
import Memory
import Testing

/// The one rule between the brain's dates and the millisecond columns: canonical instants round
/// trip exactly, arbitrary dates are quantized once, out-of-range values are refused, never clamped.
@Suite("The brain clock: canonical milliseconds")
struct BrainClockTests {

    /// A small deterministic generator, so the ten thousand instants are the same on every run.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test("ten thousand millisecond instants across the whole range round trip exactly through Date and back")
    func canonicalRoundTrip() throws {
        var generator = SplitMix(state: 42)
        var checked = 0
        for _ in 0..<10_000 {
            let ms = Int64.random(in: BrainClock.range, using: &generator)
            let date = try BrainClock.date(ms)
            #expect(try BrainClock.milliseconds(of: date) == ms)
            #expect(try BrainClock.canonical(date) == date, "a canonical date is its own quantization")
            checked += 1
        }
        #expect(checked == 10_000)
        // Dense coverage near the present, where the brain's dates live.
        for ms in Int64(1_700_000_000_000)...Int64(1_700_000_002_000) {
            #expect(try BrainClock.milliseconds(of: try BrainClock.date(ms)) == ms)
        }
    }

    @Test("negative instants, zero, the range bounds and the Foundation extremes convert exactly")
    func boundsAndNegatives() throws {
        for ms in [Int64(-1), 0, 1, -1_000, -1_700_000_000_123, BrainClock.range.lowerBound, BrainClock.range.upperBound] {
            #expect(try BrainClock.milliseconds(of: try BrainClock.date(ms)) == ms)
        }
        let past = try BrainClock.milliseconds(of: .distantPast), future = try BrainClock.milliseconds(of: .distantFuture)
        #expect(try BrainClock.milliseconds(of: try BrainClock.date(past)) == past)
        #expect(try BrainClock.milliseconds(of: try BrainClock.date(future)) == future)
        let oneBefore = try BrainClock.date(-1).timeIntervalSince1970
        // Date counts from 2001, so seconds since 1970 near 1970 carry about 1e-7 of error: far inside
        // half a millisecond, which is why the millisecond comes back exact while the seconds do not.
        #expect(abs(oneBefore + 0.001) < 1e-6)
        #expect(try BrainClock.milliseconds(of: try BrainClock.date(-1)) == -1)
    }

    @Test("an arbitrary date is quantized to the nearest millisecond, ties away from zero, and no round trip is claimed for it")
    func quantization() throws {
        let fine = Date(timeIntervalSince1970: 1_700_000_000.1234)
        let canonical = try BrainClock.canonical(fine)
        #expect(try BrainClock.milliseconds(of: fine) == 1_700_000_000_123)
        #expect(canonical != fine)
        #expect(abs(canonical.timeIntervalSince(fine)) <= 0.0005)
        #expect(try BrainClock.canonical(canonical) == canonical)
        // A Date stores seconds from its own reference epoch, so a value exactly on a half-millisecond
        // cannot be built from seconds since 1970; the rule is tested on either side of the tie.
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: 0.0006)) == 1)
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: -0.0006)) == -1)
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: 0.0004)) == 0)
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: -0.0004)) == 0)
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: 1_700_000_000.4996)) == 1_700_000_000_500)
        #expect(try BrainClock.milliseconds(of: Date(timeIntervalSince1970: 1_700_000_000.4994)) == 1_700_000_000_499)
    }

    @Test("an instant outside the representable range or not a number is a typed refusal, never clamped or wrapped")
    func overflowRefused() {
        #expect(throws: BrainClock.Problem.notFinite) { try BrainClock.milliseconds(of: Date(timeIntervalSince1970: .nan)) }
        #expect(throws: BrainClock.Problem.notFinite) { try BrainClock.milliseconds(of: Date(timeIntervalSince1970: .infinity)) }
        #expect(throws: BrainClock.Problem.dateOutOfRange(seconds: 1e16)) {
            try BrainClock.milliseconds(of: Date(timeIntervalSince1970: 1e16))
        }
        #expect(throws: BrainClock.Problem.dateOutOfRange(seconds: -1e16)) {
            try BrainClock.milliseconds(of: Date(timeIntervalSince1970: -1e16))
        }
        let beyond = BrainClock.range.upperBound + 1
        #expect(throws: BrainClock.Problem.millisecondsOutOfRange(beyond)) { try BrainClock.date(beyond) }
        #expect(throws: BrainClock.Problem.millisecondsOutOfRange(Int64.min)) { try BrainClock.date(Int64.min) }
        #expect(throws: BrainClock.Problem.millisecondsOutOfRange(Int64.max)) { try BrainClock.date(Int64.max) }
    }

    @Test("an absent instant stays absent in both directions, apart from zero")
    func nilPreserved() throws {
        let absent: Date? = nil, present: Date? = Date(timeIntervalSince1970: 0)
        #expect(try absent.map { try BrainClock.milliseconds(of: $0) } == nil)
        #expect(try present.map { try BrainClock.milliseconds(of: $0) } == 0)
        let stored: Int64? = nil
        #expect(try stored.map { try BrainClock.date($0) } == nil)
    }
}
