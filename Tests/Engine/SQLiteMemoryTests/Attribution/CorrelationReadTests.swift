//
//  CorrelationReadTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// Correction C1 of 3d: a correlation's readers check what its writer checks. A row written by hand
/// that links events of two different known applications, which the constraints admit and the
/// writer refuses, is refused by both readers with a typed error; an unknown application stays valid.
@Suite("Correlations are read as they are written", .serialized)
struct CorrelationReadTests {

    private typealias F = AttributionFixtures

    @Test("a correlation between two different known applications, written by hand, is refused by the reader of the input and by the reader of the call", arguments: [false, true])
    func knownAppsDisagree(listing: Bool) async throws {
        let memory = try await F.open()
        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w-cross"), input: try F.click()))
        _ = try await memory.calls.record(try F.agentCall("a-other", app: AppContextIdentity(bundleID: "test.other")))
        let correlation = try ActionCorrelation(watcherEventID: "w-cross", agentEventID: "a-other", basis: .assigned)
        #expect(await factError { _ = try await memory.inputs.record(correlation) } == .appMismatch(watcherEventID: "w-cross", agentEventID: "a-other"))
        try await memory.plant([("INSERT INTO memory_action_correlations (watcher_event_id, agent_event_id, basis_kind) VALUES ('w-cross', 'a-other', 'assigned')", [])])
        #expect(try await memory.count("SELECT count(*) FROM memory_action_correlations") == 1, "the schema admits the row")
        let error = await factError {
            if listing { _ = try await memory.inputs.correlations(ofAgentEvent: "a-other") } else { _ = try await memory.inputs.correlation(ofWatcherEvent: "w-cross") }
        }
        #expect(error == .malformedRow(table: "memory_action_correlations", id: "w-cross",
                                       malformation: .invalid(.appContradiction)), "listing: \(listing)")
        #expect(try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w-after", at: F.t0 + 1), input: try F.click())) == .committed)
        await memory.store.close()
    }

    @Test("an unknown application is no contradiction for either reader")
    func unknownApp() async throws {
        let memory = try await F.open()
        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w-known"), input: try F.click()))
        _ = try await memory.calls.record(try F.agentCall("a-unknown", app: nil))
        let correlation = try ActionCorrelation(watcherEventID: "w-known", agentEventID: "a-unknown", basis: .assigned)
        #expect(try await memory.inputs.record(correlation) == .committed)
        #expect(try await memory.inputs.correlation(ofWatcherEvent: "w-known")?.isExactly(correlation) == true)
        let listed = try await memory.inputs.correlations(ofAgentEvent: "a-unknown")
        #expect(listed.count == 1 && listed[0].isExactly(correlation))
        await memory.store.close()
    }
}
