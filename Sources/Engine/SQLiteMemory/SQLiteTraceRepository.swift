//
//  SQLiteTraceRepository.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 04/10/2026.
//

import Memory

/// SQLiteTraceRepository is `MemoryTraceReading` over `SQLiteMemoryStore`: reads of `memory_events`
/// grouped by trace, and each event through the events' own codec with its call through the calls'
/// codec, in one snapshot per page. It writes nothing.
public struct SQLiteTraceRepository: MemoryTraceReading {

    private let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    /// The traces whose last event is below `localOrder`, most recent last event first. A trace with an
    /// event at or above the cursor belongs entirely to a newer page, so it is left out whole. The page
    /// walks the events down from the cursor and stops once it has `limit` traces, then counts only
    /// those. The walk still reads every event it meets on the way, the events of traces left out among
    /// them, so at worst a page reads every event below the cursor.
    public func traces(before localOrder: Int64?, limit: Int) async throws -> [TraceSummary] {
        guard limit > 0 else { return [] }
        let cursor = localOrder ?? Int64.max
        return try await store.read { snapshot in
            // Keyed by the id's bytes, as SQLite compares it: Swift's `==` takes two canonically
            // equivalent ids for one, and the second trace would vanish from every page.
            var seen: Set<[UInt8]> = []
            var chosen: [String] = []
            var position = cursor
            walk: while chosen.count < limit {
                let rows = try snapshot.query(
                    "SELECT local_order, trace_id FROM memory_events WHERE local_order < ? AND trace_id IS NOT NULL ORDER BY local_order DESC LIMIT ?",
                    [.integer(position), .integer(Self.walkChunk)]
                ) { (order: $0.integer(0) ?? 0, trace: try $0.text(1) ?? "") }
                if rows.isEmpty { break }
                for row in rows {
                    position = row.order
                    guard seen.insert(Array(row.trace.utf8)).inserted else { continue }
                    // Walking down from the cursor, a trace is first met at its last event below it; it
                    // belongs here only when it has none at or above the cursor.
                    let straddles = try !snapshot.query(
                        "SELECT 1 FROM memory_events WHERE trace_id = ? AND local_order >= ? LIMIT 1",
                        [.text(row.trace), .integer(cursor)]
                    ) { _ in true }.isEmpty
                    if straddles { continue }
                    chosen.append(row.trace)
                    if chosen.count == limit { break walk }
                }
            }
            return try chosen.map { traceID in try Self.summary(snapshot, traceID: traceID) }
        }
    }

    /// How many events a page reads down from the cursor at a time.
    private static let walkChunk: Int64 = 256

    /// One trace's counts, bounds and first event's source.
    private static func summary(_ snapshot: SQLiteSnapshot, traceID: String) throws -> TraceSummary {
        let counts = try snapshot.query(
            """
            SELECT count(*), sum(CASE WHEN a.event_id IS NULL THEN 0 ELSE 1 END),
                   min(e.local_order), max(e.local_order), min(e.occurred_at_ms), max(e.occurred_at_ms)
            FROM memory_events e LEFT JOIN memory_agent_actions a ON a.event_id = e.event_id
            WHERE e.trace_id = ?
            """,
            [.text(traceID)]
        ) { row in
            (events: Int(row.integer(0) ?? 0), calls: Int(row.integer(1) ?? 0), firstOrder: row.integer(2) ?? 0,
             lastOrder: row.integer(3) ?? 0, firstMS: row.integer(4) ?? 0, lastMS: row.integer(5) ?? 0)
        }[0]
        let first = try snapshot.query(
            "SELECT source, source_stream_id FROM memory_events WHERE trace_id = ? ORDER BY local_order LIMIT 1",
            [.text(traceID)]
        ) { (code: try $0.text(0) ?? "", stream: try $0.text(1) ?? "") }[0]
        guard let source = MemoryEventSource(rawValue: first.code) else {
            throw EventFactError.malformedRow(table: "memory_events", id: traceID,
                                              malformation: .unknownCode(column: "source", code: first.code))
        }
        return TraceSummary(
            traceID: traceID, events: counts.events, calls: counts.calls,
            firstLocalOrder: counts.firstOrder, lastLocalOrder: counts.lastOrder,
            firstOccurredAtMS: counts.firstMS, lastOccurredAtMS: counts.lastMS,
            source: source, streamID: first.stream
        )
    }

    public func entries(inTrace traceID: String, after localOrder: Int64?, limit: Int) async throws -> [TraceEntry] {
        guard limit > 0 else { return [] }
        return try await store.read { snapshot in
            let rows = try snapshot.query(
                "SELECT event_id, local_order FROM memory_events WHERE trace_id = ? AND local_order > ? ORDER BY local_order LIMIT ?",
                [.text(traceID), .integer(localOrder ?? 0), .integer(Int64(limit))]
            ) { (id: try $0.text(0) ?? "", order: $0.integer(1) ?? 0) }
            return try rows.compactMap { row in
                guard let event = try SQLiteEventRows.read(snapshot, eventID: row.id) else { return nil }
                return TraceEntry(localOrder: row.order, event: event, call: try SQLiteAgentCallRows.call(snapshot, eventID: row.id))
            }
        }
    }

    public func observations(originatedBy eventID: String) async throws -> [MemoryEventRecord] {
        try await store.read { snapshot in
            let ids = try snapshot.query(
                "SELECT event_id FROM memory_events WHERE origin_event_id = ? ORDER BY local_order", [.text(eventID)]
            ) { try $0.text(0) ?? "" }
            return try ids.compactMap { try SQLiteEventRows.read(snapshot, eventID: $0) }
        }
    }
}
