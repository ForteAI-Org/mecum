//
//  SQLiteProcessTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// Two real processes on one file, through `memory-probe`: the file's own locks, not the actor,
/// keep them apart. Every order of events is decided on a line the helper answers, with a
/// deadline; a crash is a `SIGKILL` at a point the helper announced.
@Suite("Two real processes on one file")
struct SQLiteProcessTests {

    private func walSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? UInt64) ?? 0
    }

    @Test("two processes opening one fresh file at once create the schema once; the same fact is applied once across them")
    func concurrentBootstrapAndIdempotency() async throws {
        let url    = try temporaryDatabase()
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")
        let a = try ProbeProcess()
        let b = try ProbeProcess()
        defer { a.end(); b.end() }
        #expect(try await a.ask("waits") == "waits on")
        #expect(try await b.ask("waits") == "waits on")
        await a.send("open \(url.path) 30000")
        await b.send("open \(url.path) 30000")
        // Both are inside their open, waiting for the lock this process holds: the opens overlap.
        #expect(try await a.expect("a wait line") == "wait pausing bootstrap 1")
        #expect(try await b.expect("a wait line") == "wait pausing bootstrap 1")
        try holder.execute("ROLLBACK")
        holder.close()
        let openedA = try await a.expect(prefix: "opened ")
        let openedB = try await b.expect(prefix: "opened ")
        let bootstrapped = [openedA, openedB].filter { $0.hasPrefix("opened bootstrapped=1") }.count
        #expect(bootstrapped == 1, Comment(rawValue: "\(openedA) / \(openedB)"))

        #expect(try await a.ask("record e1 k1 100") == "committed")
        #expect(try await b.ask("record e1 k1 100") == "alreadyApplied")
        #expect(try await b.ask("record e1 k1 200") == "error identity")
        #expect(try await b.ask("record e2 k2 100") == "committed")
        #expect(try await a.ask("record e2 k2 100") == "alreadyApplied")
        #expect(try await a.ask("close") == "closed")
        #expect(try await b.ask("close") == "closed")

        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(!(try await store.diagnostics().bootstrappedNow))
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 2)
        #expect(try await store.read { try SchemaShape($0) } == SchemaShape(tables: 48, triggers: 48, indexes: 31))
        await store.close()
    }

    @Test("three processes doing read-modify-write on one stream lose no update")
    func noLostUpdates() async throws {
        let url    = try temporaryDatabase()
        let probes = try (0..<3).map { _ in try ProbeProcess() }
        defer { probes.forEach { $0.end() } }
        for probe in probes {
            #expect(try await probe.ask("open \(url.path)").hasPrefix("opened "))
        }
        for probe in probes {
            await probe.send("increment s 40")
        }
        for probe in probes {
            #expect(try await probe.expect(prefix: "incremented 40", timeout: .seconds(60)).hasPrefix("incremented 40 last="))
        }
        #expect(try await probes[0].ask("count-events s") == "events 120 distinct=120 max=120")
        for probe in probes {
            #expect(try await probe.ask("close") == "closed")
        }
        let store = try await SQLiteMemoryStore.open(at: url)
        let rows = try await store.read { snapshot in
            try snapshot.query("SELECT occurred_at_ms FROM memory_events WHERE source_stream_id = 's' ORDER BY occurred_at_ms") { $0.integer(0) ?? 0 }
        }
        #expect(rows == Array(1...120))
        await store.close()
    }

    @Test("a process killed after its changes and before its commit leaves no partial row")
    func killedBeforeCommit() async throws {
        let url   = try temporaryDatabase()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened "))
        let logBefore = try walSize(url)
        // A small cache (64 KiB, spilling) puts the transaction's pages into the log before the commit:
        // the interruption is of frames already on disk, which the next open must leave out.
        #expect(try await probe.ask("hold 1200 3000 64") == "held rows=1200")
        let logDuring = try walSize(url)
        #expect(logDuring > logBefore + 1_000_000, Comment(rawValue: "log \(logBefore) -> \(logDuring) bytes"))
        probe.kill()
        let exit = try await probe.exit()
        #expect(exit?.reason == .uncaughtSignal)
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(!(try await store.diagnostics().bootstrappedNow))
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 0)
        #expect(try await store.read { try $0.query("PRAGMA integrity_check") { try $0.text(0) } } == ["ok"])
        _ = try await store.write { try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('after.app')") }
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 1)
        await store.close()
    }

    @Test("a process killed after it confirmed its commit leaves the fact, which the same identity finds")
    func killedAfterCommit() async throws {
        let url   = try temporaryDatabase()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened "))
        #expect(try await probe.ask("record e1 k1 100") == "committed")
        probe.kill()
        #expect(try await probe.exit()?.reason == .uncaughtSignal)
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await record(EventRow(id: "e1", key: "k1"), in: store) == .alreadyApplied)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 1)
        await store.close()
    }

    @Test("a process that dies after its commit and before answering: the caller learns the outcome from the identity, not by acting again")
    func diedBeforeAnswering() async throws {
        let url   = try temporaryDatabase()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened "))
        await probe.send("record-and-die e2 k2 100")
        #expect(try await probe.receive(waitingFor: "the end of the helper's output") == nil)
        #expect(try await probe.exit()?.reason == .uncaughtSignal)
        // No answer came: the outcome is unknown to the caller until it asks by the same identity.
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await record(EventRow(id: "e2", key: "k2"), in: store) == .alreadyApplied)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 1)
        await store.close()
    }
}
