//
//  TraceIdentityTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 05/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Trace identity is the bytes SQLite stores and compares, not Swift's string equality: two ids that
/// are canonically equivalent Unicode but differ in bytes are two traces on every page and at every
/// cursor, as the grouped query sees them.
@Suite("Trace identity")
struct TraceIdentityTests {

    @Test("ids equal only under Unicode canonical equivalence are two traces, on the whole page, at a cursor inside one and on the next page")
    func byteDistinctTracesAndStraddlingCursor() async throws {
        let memory = try await AgentCallFixtures.open()
        let traces = SQLiteTraceRepository(store: memory.store)
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        for (i, trace) in [decomposed, composed, composed].enumerated() {
            let event = MemoryEventRecord(eventID: "e\(i)", source: .cli, streamID: "supervision", traceID: trace,
                kind: .observation, app: AgentCallFixtures.app, occurredAtMS: Int64(100 + i))
            _ = try await memory.captures.record(event)
        }
        let all = try await traces.traces(before: nil, limit: 10)
        let reference: [[UInt8]] = try await memory.store.read { snapshot in
            try snapshot.query("SELECT trace_id FROM memory_events GROUP BY trace_id ORDER BY max(local_order) DESC", []) {
                Array((try $0.text(0) ?? "").utf8)
            }
        }
        #expect(all.map { Array($0.traceID.utf8) } == reference)
        let atCursor = try await traces.traces(before: 3, limit: 10)
        #expect(atCursor.map { Array($0.traceID.utf8) } == [Array(decomposed.utf8)])
        let first = try await traces.traces(before: nil, limit: 1)
        let next = try await traces.traces(before: first[0].lastLocalOrder, limit: 1)
        #expect(next.map { Array($0.traceID.utf8) } == [Array(decomposed.utf8)])
    }
}
