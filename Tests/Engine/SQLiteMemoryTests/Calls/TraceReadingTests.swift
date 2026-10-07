//
//  TraceReadingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 04/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The diagnostic read of traces (`SQLiteTraceRepository`): traces most recent first and paged, one
/// trace's events in local order with their calls and the observations beside them, the observations
/// a call originated, and nothing written by any of it.
@Suite("Reading the traces")
struct TraceReadingTests {

    @Test("traces come most recent first, a page at a time, with counts of their events and calls and their first event's source")
    func tracesArePaged() async throws {
        let memory = try await AgentCallFixtures.open()
        let traces = SQLiteTraceRepository(store: memory.store)
        #expect(try await traces.traces(before: nil, limit: 10).isEmpty, "a valid empty archive has no trace")
        // trace-1: a planned call and a batch of two steps; trace-2: an observation of its own, from the cli.
        _ = try await memory.calls.record(try AgentCallFixtures.call("c1", .observe(full: false)))
        let (batch, steps) = try AgentCallFixtures.batch("b1", Array(AgentCallFixtures.sevenSteps.prefix(2)), at: AgentCallFixtures.t0 + 10)
        _ = try await memory.calls.record(batch: batch, steps: steps)
        let other = MemoryEventRecord(eventID: "o1", source: .cli, streamID: "mecum-cli-1", traceID: "trace-2", sessionID: "s",
                                      kind: .observation, app: AgentCallFixtures.app, occurredAtMS: AgentCallFixtures.t0 + 50,
                                      originEventID: "c1")
        _ = try await memory.captures.record(other)
        let all = try await traces.traces(before: nil, limit: 10)
        #expect(all.map(\.traceID) == ["trace-2", "trace-1"])
        #expect(all[1].events == 4 && all[1].calls == 4 && all[1].source == .app && all[1].streamID == "worker-1")
        #expect(all[0].events == 1 && all[0].calls == 0 && all[0].source == .cli)
        let first = try await traces.traces(before: nil, limit: 1)
        #expect(first.map(\.traceID) == ["trace-2"])
        let next = try await traces.traces(before: first[0].lastLocalOrder, limit: 1)
        #expect(next.map(\.traceID) == ["trace-1"])
        #expect(try await traces.traces(before: next[0].lastLocalOrder, limit: 1).isEmpty)
    }

    /// An event of `trace` (nil for none), a call when `call`, from the app's or the chat's stream.
    private static func event(_ memory: AgentCallFixtures.Memory, _ id: String, trace: String?, at ms: Int64,
                              call: Bool, cli: Bool) async throws {
        let record = MemoryEventRecord(eventID: id, source: cli ? .cli : .app, streamID: cli ? "chat-1" : "worker-1",
                                       traceID: trace, sessionID: "S", kind: call ? .action : .observation,
                                       app: AgentCallFixtures.app, occurredAtMS: ms)
        if call {
            _ = try await memory.calls.record(try AgentCallRecord(event: record, request: .observe(full: false)))
        } else {
            _ = try await memory.captures.record(record)
        }
    }

    @Test("a trace with an event at or above the cursor is left out whole: it belongs to a newer page, never cut in two")
    func aTraceAcrossTheCursorIsLeftOutWhole() async throws {
        let memory = try await AgentCallFixtures.open()
        let traces = SQLiteTraceRepository(store: memory.store)
        // Local orders 1…5: A, B, A, C, A. A spans the whole range; B and C sit inside it.
        for (index, trace) in ["A", "B", "A", "C", "A"].enumerated() {
            try await Self.event(memory, "e\(index)", trace: trace, at: AgentCallFixtures.t0 + Int64(index), call: index == 0, cli: false)
        }
        let all = try await traces.traces(before: nil, limit: 10)
        #expect(all.map(\.traceID) == ["A", "C", "B"])
        #expect(all[0].events == 3 && all[0].calls == 1 && all[0].firstLocalOrder < all[2].lastLocalOrder)
        // Below C's last event, A still has an event above the cursor: only B.
        #expect(try await traces.traces(before: all[1].lastLocalOrder, limit: 10).map(\.traceID) == ["B"])
        #expect(try await traces.traces(before: all[0].lastLocalOrder, limit: 1).map(\.traceID) == ["C"])
        #expect(try await traces.traces(before: all[2].lastLocalOrder, limit: 10).isEmpty)
    }

    /// How the oracle names its traces: plain ASCII, or pairs that Swift's `==` takes for one string
    /// but SQLite stores and compares as different bytes.
    enum TraceNames: String, CaseIterable {
        case ascii, canonicallyEquivalent

        func name(_ index: Int) -> String {
            switch self {
            case .ascii: "trace-\(index)"
            case .canonicallyEquivalent: index.isMultiple(of: 2) ? "caf\u{e9}-\(index / 2)" : "cafe\u{301}-\(index / 2)"
            }
        }
    }

    /// A trace id as its bytes, so a comparison never goes through Swift's string equality.
    private static func bytes(_ id: String) -> String {
        id.utf8.map(String.init).joined(separator: ".")
    }

    @Test("pages match the grouped query they replaced, byte for byte, on interleaved traces, events with no trace or no call, two sources and a calendar that goes back, at every cursor",
          arguments: TraceNames.allCases)
    func pagesMatchTheGroupedQuery(names: TraceNames) async throws {
        let memory = try await AgentCallFixtures.open()
        let traces = SQLiteTraceRepository(store: memory.store)
        #expect(try await traces.traces(before: 5, limit: 3).isEmpty, "an empty archive has no page")
        var state: UInt64 = 20_261_003
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for index in 0..<160 {
            let roll = next(10)
            let trace: String? = roll == 0 ? nil : names.name(next(12))
            // The calendar goes back now and then; local order never does.
            let ms = AgentCallFixtures.t0 + Int64(index * 10) - (next(4) == 0 ? 500 : 0)
            try await Self.event(memory, "e\(index)", trace: trace, at: ms, call: roll % 3 == 0, cli: next(2) == 0)
        }
        func reference(_ before: Int64?, _ limit: Int) async throws -> [String] {
            try await memory.store.read { snapshot in
                try snapshot.query(
                    """
                    SELECT g.trace_id, g.events, g.calls, g.first_order, g.last_order, g.first_ms, g.last_ms,
                           f.source, f.source_stream_id
                    FROM (SELECT e.trace_id AS trace_id, count(*) AS events,
                                 sum(CASE WHEN a.event_id IS NULL THEN 0 ELSE 1 END) AS calls,
                                 min(e.local_order) AS first_order, max(e.local_order) AS last_order,
                                 min(e.occurred_at_ms) AS first_ms, max(e.occurred_at_ms) AS last_ms
                          FROM memory_events e LEFT JOIN memory_agent_actions a ON a.event_id = e.event_id
                          WHERE e.trace_id IS NOT NULL
                          GROUP BY e.trace_id) g
                    JOIN memory_events f ON f.trace_id = g.trace_id AND f.local_order = g.first_order
                    WHERE g.last_order < ?
                    ORDER BY g.last_order DESC
                    LIMIT ?
                    """,
                    [.integer(before ?? Int64.max), .integer(Int64(limit))]
                ) { row in
                    "\(Self.bytes(try row.text(0) ?? "")) \(row.integer(1) ?? -1) \(row.integer(2) ?? -1) \(row.integer(3) ?? -1) "
                        + "\(row.integer(4) ?? -1) \(row.integer(5) ?? -1) \(row.integer(6) ?? -1) \(try row.text(7) ?? "") \(try row.text(8) ?? "")"
                }
            }
        }
        func page(_ before: Int64?, _ limit: Int) async throws -> [String] {
            try await traces.traces(before: before, limit: limit).map {
                "\(Self.bytes($0.traceID)) \($0.events) \($0.calls) \($0.firstLocalOrder) \($0.lastLocalOrder) "
                    + "\($0.firstOccurredAtMS) \($0.lastOccurredAtMS) \($0.source.rawValue) \($0.streamID)"
            }
        }
        let last = try await memory.store.read { try $0.query("SELECT max(local_order) FROM memory_events", []) { $0.integer(0) ?? 0 } }[0]
        var compared = 0
        for before in [nil] + (0...(last + 1)).map(Optional.some) {
            for limit in [1, 2, 5, 50] {
                let expected = try await reference(before, limit), actual = try await page(before, limit)
                #expect(actual == expected, "before \(String(describing: before)), limit \(limit)")
                compared += 1
            }
        }
        // The whole pagination, page after page, reaches every trace once.
        var seen: [[UInt8]] = []
        var before: Int64?
        while true {
            let next = try await traces.traces(before: before, limit: 3)
            if next.isEmpty { break }
            seen += next.map { Array($0.traceID.utf8) }
            before = next.last?.lastLocalOrder
        }
        let distinct = try await memory.store.read {
            try $0.query("SELECT count(DISTINCT trace_id) FROM memory_events WHERE trace_id IS NOT NULL", []) { $0.integer(0) ?? 0 }
        }[0]
        #expect(Set(seen).count == seen.count && Int64(seen.count) == distinct, "each trace on exactly one page")
        #expect(compared == 4 * Int(last + 3))
    }

    @Test("a trace's entries are its events in local order, each with its call or none, and a call's own observations are found by origin")
    func entriesAndOrigins() async throws {
        let memory = try await AgentCallFixtures.open()
        let traces = SQLiteTraceRepository(store: memory.store)
        _ = try await memory.calls.record(try AgentCallFixtures.call("open", .openSession(app: "Test", window: nil), session: nil))
        let own = MemoryEventRecord(eventID: "open.observation", source: .app, streamID: "worker-1", traceID: "trace-1",
                                    sessionID: "S", kind: .observation, app: AgentCallFixtures.app,
                                    occurredAtMS: AgentCallFixtures.t0 + 1, originEventID: "open")
        _ = try await memory.captures.record(own)
        _ = try await memory.calls.advance([AgentCallTransition("open", .started(atMS: AgentCallFixtures.t0 + 2))])
        let entries = try await traces.entries(inTrace: "trace-1", after: nil, limit: 10)
        #expect(entries.map(\.event.eventID) == ["open", "open.observation"])
        #expect(entries[0].call?.progress.status == .started, "read as started: no terminal state is made up")
        #expect(entries[1].call == nil && entries[1].event.originEventID == "open")
        #expect(entries[0].localOrder < entries[1].localOrder)
        let page = try await traces.entries(inTrace: "trace-1", after: entries[0].localOrder, limit: 10)
        #expect(page.map(\.event.eventID) == ["open.observation"])
        #expect(try await traces.observations(originatedBy: "open").map(\.eventID) == ["open.observation"])
        #expect(try await traces.observations(originatedBy: "nothing").isEmpty)
        #expect(try await traces.entries(inTrace: "no-such-trace", after: nil, limit: 10).isEmpty)
        let ledger = try await memory.ledger()
        _ = try await traces.traces(before: nil, limit: 10)
        _ = try await traces.entries(inTrace: "trace-1", after: nil, limit: 10)
        #expect(try await memory.ledger() == ledger, "reading wrote nothing")
        #expect(try await memory.store.diagnostics().commits == 3, "the three writes of the fixture, none of the readings")
    }
}
