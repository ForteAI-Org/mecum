//
//  WindowInventoryProbeDoubles.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// SteppingProbeClock is a monotonic clock that advances by a fixed amount at
/// every reading, so a deadline can be reached in an offline test without the
/// test taking any real time. It never goes backwards, like the clock it stands
/// in for.
@MainActor
final class SteppingProbeClock: ProbeClock {

    private var current: UInt64
    private let step   : UInt64

    init(start: UInt64 = 0, step: UInt64 = 1) {
        self.current = start
        self.step    = step
    }

    var nowNanoseconds: UInt64 {
        let value = current
        current &+= step
        return value
    }
}

/// StubInventoryRowsReader answers scripted window lists, including the answers
/// the real one can give and a test cannot ask for on demand: `nil`, a failed
/// conversion, an empty list and a list of malformed rows.
///
/// It records the scopes it was asked for, in order, so a test can check that a
/// pair really is an all reading followed by an on-screen reading. Running out
/// of script answers `unavailable` rather than repeating the last answer, which
/// would quietly turn a cap violation into a plausible run.
@MainActor
final class StubInventoryRowsReader: InventoryRowsReading {

    let apiName            = "StubInventoryRowsReader"
    let relativeToWindowID = UInt32(0)

    private var scripted: [InventoryRowsResponse]

    private(set) var requestedScopes: [InventoryReadingScope] = []

    init(_ scripted: [InventoryRowsResponse]) {
        self.scripted = scripted
    }

    /// Repeats one pair of answers for as many samples as the run takes, for the
    /// tests whose subject is the loop rather than the list.
    static func repeating(_ response: InventoryRowsResponse, times: Int) -> StubInventoryRowsReader {
        StubInventoryRowsReader(Array(repeating: response, count: times))
    }

    func optionBits(for scope: InventoryReadingScope) -> UInt32 {
        scope == .all ? 1 : 2
    }

    func rows(scope: InventoryReadingScope) -> InventoryRowsResponse {
        requestedScopes.append(scope)
        guard !scripted.isEmpty else { return .unavailable("the stub has no answer left") }
        return scripted.removeFirst()
    }
}
