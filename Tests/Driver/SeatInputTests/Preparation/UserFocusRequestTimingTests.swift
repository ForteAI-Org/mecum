//
//  UserFocusRequestTimingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import SeatInput
import Testing

@Suite("User focus request timing")
struct UserFocusRequestTimingTests {

    @Test("a fresh record carries no full-call duration instead of a zero one")
    func absentFullCallMeasurement() {
        let timing = UserFocusRequestTiming()
        #expect(timing.restoreCallNanoseconds == nil)
        #expect(timing.restoreCallControlNanoseconds == nil)
        #expect(timing.activationNanoseconds == 0)
    }

    @Test("a measured zero stays distinguishable from a missing measurement")
    func measuredZeroIsAMeasurement() {
        var timing = UserFocusRequestTiming()
        timing.restoreCallNanoseconds = 0
        timing.restoreCallControlNanoseconds = 0
        #expect(timing.restoreCallNanoseconds == 0)
        #expect(timing != UserFocusRequestTiming())
    }

    @Test("the declared control cost is reported beside the call, never subtracted from it")
    func controlIsReportedSeparately() {
        var timing = UserFocusRequestTiming()
        timing.restoreCallNanoseconds = 8_000_000
        timing.restoreCallControlNanoseconds = 41
        #expect(timing.restoreCallNanoseconds == 8_000_000)
        #expect(timing.restoreCallControlNanoseconds == 41)
    }
}
