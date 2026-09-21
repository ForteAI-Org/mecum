//
//  ContentClockTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore
@testable import SeatCapture
import Testing

@Suite("The WindowServer display clock")
struct ContentClockTests {

    @Test("mach ticks are converted to Dispatch uptime nanoseconds")
    func convertsMachTicks() throws {
        let clock = MachAbsoluteContentClock(numerator: 3, denominator: 2)
        let frame = try #require(makeFakeFrame(displayTime: 100))

        #expect(clock.isQualified)
        #expect(clock.contentAge(of: frame, atNanoseconds: 200) == .qualified(nanoseconds: 50))
    }

    @Test("a missing display timestamp stays unknown")
    func missingTimestamp() throws {
        let clock = MachAbsoluteContentClock(numerator: 1, denominator: 1)
        let frame = try #require(makeFakeFrame())

        #expect(clock.contentAge(of: frame, atNanoseconds: 200) == .unknown(.timestampMissing))
    }

    @Test("zero and overflowing timestamps are malformed")
    func malformedTimestamps() throws {
        let identity = MachAbsoluteContentClock(numerator: 1, denominator: 1)
        let multiplying = MachAbsoluteContentClock(numerator: 2, denominator: 1)
        let zero = try #require(makeFakeFrame(displayTime: 0))
        let overflow = try #require(makeFakeFrame(displayTime: .max))

        #expect(identity.contentAge(of: zero, atNanoseconds: 200) == .unknown(.timestampMalformed))
        #expect(multiplying.contentAge(of: overflow, atNanoseconds: .max) == .unknown(.timestampMalformed))
    }

    @Test("a display timestamp after the caller's reading is refused")
    func futureTimestamp() throws {
        let clock = MachAbsoluteContentClock(numerator: 1, denominator: 1)
        let frame = try #require(makeFakeFrame(displayTime: 201))

        #expect(clock.contentAge(of: frame, atNanoseconds: 200) == .unknown(.timestampNotMonotonic))
    }

    @Test("an invalid timebase cannot qualify the clock")
    func invalidTimebase() throws {
        let clock = MachAbsoluteContentClock(numerator: 1, denominator: 0)
        let frame = try #require(makeFakeFrame(displayTime: 100))

        #expect(!clock.isQualified)
        #expect(clock.contentAge(of: frame, atNanoseconds: 200) == .unknown(.clockNotQualified))
    }
}
