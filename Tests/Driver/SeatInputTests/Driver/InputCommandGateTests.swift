//
//  InputCommandGateTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatInput
import Testing

@Suite("Prepared input boundary")
@MainActor
struct InputCommandGateTests {
    @Test("a pause or cancellation during preparation prevents the following post", arguments: [false, true])
    func suspendedBoundary(_ cancel: Bool) async {
        let gate = InputCommandGate()
        var resume: CheckedContinuation<Void, Never>?
        var posted = false
        gate.setPreparation { correlationID in
            #expect(correlationID == 42)
            await withCheckedContinuation { resume = $0 }
        }
        let task = Task {
            try await gate.prepare(correlationID: 42)
            posted = true
        }
        while resume == nil { await Task.yield() }
        #expect(!posted)
        if cancel { task.cancel() } else { gate.pause() }
        resume?.resume()
        let result = await task.result
        if case .success = result { Issue.record("An interrupted boundary must throw") }
        #expect(!posted)
    }

    @Test("every command boundary awaits its own preparation")
    func eachBoundary() async throws {
        let gate = InputCommandGate()
        var prepared: [Int64] = []
        gate.setPreparation { prepared.append($0) }
        for correlationID in 1...3 {
            try await gate.prepare(correlationID: Int64(correlationID))
            #expect(prepared.count == correlationID)
        }
        gate.pause()
        await #expect(throws: InputFailure.inputPaused) { try await gate.prepare(correlationID: 4) }
        #expect(prepared == [1, 2, 3])
    }
}
