//
//  Support.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// A fresh database path in a directory of its own, so no test shares a file with another.
func temporaryDatabase(_ name: String = "memory") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mecum-sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(name).sqlite")
}

/// The store error an operation throws, or nil when it succeeds. Any other error is a defect of
/// the test and is recorded as one.
func storeError(_ operation: () async throws -> Void) async -> MemoryStoreError? {
    do {
        try await operation()
        return nil
    } catch let error as MemoryStoreError {
        return error
    } catch {
        Issue.record("an error outside the store's taxonomy: \(error)")
        return nil
    }
}

/// Counts of the schema objects a file holds, apart from the library's own.
struct SchemaShape: Equatable, Sendable {

    let tables  : Int
    let triggers: Int
    let indexes : Int

    init(tables: Int, triggers: Int, indexes: Int) {
        self.tables   = tables
        self.triggers = triggers
        self.indexes  = indexes
    }

    init(_ snapshot: SQLiteSnapshot) throws {
        let counts = try snapshot.query(
            "SELECT type, count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' GROUP BY type"
        ) { row in (try row.text(0) ?? "", Int(row.integer(1) ?? 0)) }
        let byType = Dictionary(uniqueKeysWithValues: counts)
        self.init(tables: byType["table"] ?? 0, triggers: byType["trigger"] ?? 0, indexes: byType["index"] ?? 0)
    }
}

/// One `memory_events` row as the idempotency tests write and read it: the identity is the
/// event id, the content is everything else.
struct EventRow: Equatable, Sendable {

    var id        : String
    var key       : String
    var source    = "app"
    var stream    = "worker-1"
    var kind      = "action"
    var occurredAt: Int64 = 100
    var capture   = "complete"

    /// The canonical content, for a conflict report.
    var fingerprint: String {
        [source, stream, key, kind, String(occurredAt), capture].joined(separator: "|")
    }
}

/// Writes the event once: the same identity with the same content is already applied, the same
/// identity with other content is a conflict. This is the check-then-insert pattern the typed
/// repositories will use; here it lives in the test so the store's contract is proven on its own.
func record(_ event: EventRow, in store: SQLiteMemoryStore) async throws -> MemoryReceipt {
    try await store.write { transaction in
        let stored = try transaction.query(
            """
            SELECT source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status
            FROM memory_events WHERE event_id = ?
            """,
            [.text(event.id)]
        ) { row in
            EventRow(
                id        : event.id,
                key       : try row.text(2) ?? "",
                source    : try row.text(0) ?? "",
                stream    : try row.text(1) ?? "",
                kind      : try row.text(3) ?? "",
                occurredAt: row.integer(4) ?? 0,
                capture   : try row.text(5) ?? ""
            )
        }.first
        if let stored {
            guard stored == event else {
                throw MemoryStoreError.identity(MemoryIdentityConflict(
                    identity          : event.id,
                    storedFingerprint : stored.fingerprint,
                    offeredFingerprint: event.fingerprint
                ))
            }
            return .alreadyApplied
        }
        try transaction.execute(
            """
            INSERT INTO memory_events
                (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(event.id), .text(event.source), .text(event.stream), .text(event.key),
             .text(event.kind), .integer(event.occurredAt), .text(event.capture)]
        )
        return .committed
    }
}

/// One cycle of `record`, through `attemptWrite`: answers `contention` when the budget is spent.
func recordOnce(_ event: EventRow, in store: SQLiteMemoryStore) async throws -> MemoryReceipt {
    try await store.attemptWrite { transaction in
        try transaction.execute(
            """
            INSERT INTO memory_events
                (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(event.id), .text(event.source), .text(event.stream), .text(event.key),
             .text(event.kind), .integer(event.occurredAt), .text(event.capture)]
        )
        return .committed
    }
}

/// Runs one statement through the store and answers the contract fault it was refused with, or
/// records an issue when it was accepted or refused for another reason.
func refusal(of sql: String, in store: SQLiteMemoryStore) async -> MemoryStoreFault? {
    let error = await storeError { _ = try await store.write { try $0.execute(sql) } }
    guard case .contract(let fault)? = error else {
        Issue.record("expected a contract refusal for `\(sql)`, got \(String(describing: error))")
        return nil
    }
    return fault
}

/// Counts the rows a query answers, on the store's reader.
func count(_ sql: String, in store: SQLiteMemoryStore) async throws -> Int64 {
    try await store.read { snapshot in
        try snapshot.query(sql) { $0.integer(0) ?? -1 }.first ?? -1
    }
}

/// A stream of the store's wait events, installed before the operation under test starts, so a
/// test resumes exactly when the store announces the pause or the yield it is about to take.
func waits(of store: SQLiteMemoryStore) async -> AsyncStream<SQLiteMemoryStore.WaitEvent>.Iterator {
    let (events, continuation) = AsyncStream<SQLiteMemoryStore.WaitEvent>.makeStream()
    await store.observeWaits { continuation.yield($0) }
    return events.makeAsyncIterator()
}

/// Counts the rows a query answers on a bare connection to the file, outside any store.
func rawCount(_ sql: String, at url: URL, readOnly: Bool = true) throws -> Int64 {
    let connection = try SQLiteConnection(path: url.path, readOnly: readOnly)
    defer { connection.close() }
    return try connection.query(sql) { $0.integer(0) ?? -1 }.first ?? -1
}

/// The names in a directory, apart from the file itself, its journals and its presence lock: what a
/// snapshot or an interrupted one left behind.
func strayFiles(beside url: URL) throws -> [String] {
    let own = url.lastPathComponent
    return try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        .filter { ![own, own + "-wal", own + "-shm", own + "-journal", own + ".lock"].contains($0) }
        .sorted()
}
