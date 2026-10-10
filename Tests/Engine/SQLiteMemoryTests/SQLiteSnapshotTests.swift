//
//  SQLiteSnapshotTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// A snapshot is a consistent copy through the backup API: it holds what was committed as of one
/// read transaction, wherever those pages were, log included; it is verified before it is handed
/// over; it never overwrites, never replaces the store's file, and an interrupted one leaves
/// nothing behind.
@Suite("Snapshots through the backup API")
struct SQLiteSnapshotTests {

    private func filled(_ url: URL, events: Int, configuration: SQLiteMemoryStore.Configuration = .init()) async throws -> SQLiteMemoryStore {
        let store = try await SQLiteMemoryStore.open(at: url, configuration: configuration)
        for index in 0..<events {
            _ = try await record(EventRow(id: "e\(index)", key: "k\(index)"), in: store)
        }
        return store
    }

    private func walSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? UInt64) ?? 0
    }

    @Test("the copy holds what the log holds, is one verified self-contained file, reopens, and leaves the original intact")
    func copyIsConsistentAndSelfContained() async throws {
        let url   = try temporaryDatabase()
        let store = try await filled(url, events: 50)
        #expect(try walSize(url) > 0)
        // A copy of the main file alone is what the backup API is there to avoid: the schema and the
        // rows are still in the log, so that copy does not even hold the tables.
        let plain = try temporaryDatabase("plain")
        try FileManager.default.copyItem(at: url, to: plain)
        #expect(try rawCount("SELECT count(*) FROM sqlite_schema WHERE type = 'table'", at: plain, readOnly: false) < 41)

        let destination = url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let report      = try await store.snapshot(to: destination)
        #expect(report.destination == destination.standardizedFileURL.resolvingSymlinksInPath())
        #expect(report.pageCount > 0)
        #expect(report.pageSize == 4096)
        #expect(report.steps >= 1)
        #expect(try strayFiles(beside: url) == ["copy.sqlite"])
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: destination) == 50)
        let check = try SQLiteConnection(path: destination.path)
        #expect(try check.query("PRAGMA journal_mode") { try $0.text(0) }.first == "delete")
        #expect(try check.query("PRAGMA integrity_check") { try $0.text(0) }.first == "ok")
        #expect(try check.query("PRAGMA user_version") { $0.integer(0) }.first == 2)
        check.close()
        #expect(try await store.diagnostics().snapshots == 1)

        // The original is untouched and still the store's: one more write goes to it, not to the copy.
        _ = try await record(EventRow(id: "e50", key: "k50"), in: store)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 51)
        let reopened = try await SQLiteMemoryStore.open(at: destination)
        let diagnostics = try await reopened.diagnostics()
        #expect(diagnostics.schemaVersion == 2)
        #expect(!diagnostics.bootstrappedNow)
        #expect(diagnostics.journalMode == "wal")
        #expect(try await count("SELECT count(*) FROM memory_events", in: reopened) == 50)
        #expect(try await reopened.read { try SchemaShape($0) } == SchemaShape.current)
        await reopened.close()
        await store.close()
    }

    @Test("the store's own file and its journals, an existing destination and a missing directory are refused with no file touched")
    func refusals() async throws {
        let url   = try temporaryDatabase()
        let store = try await filled(url, events: 3)
        #expect(await storeError { _ = try await store.snapshot(to: url) } == .snapshot(.destinationIsTheSource))
        #expect(await storeError { _ = try await store.snapshot(to: URL(fileURLWithPath: url.path + "-wal")) } == .snapshot(.destinationIsTheSource))
        let taken = url.deletingLastPathComponent().appendingPathComponent("taken.sqlite")
        try Data("not a copy".utf8).write(to: taken)
        #expect(await storeError { _ = try await store.snapshot(to: taken) } == .snapshot(.destinationExists))
        #expect(try Data(contentsOf: taken) == Data("not a copy".utf8))
        let nowhere = url.deletingLastPathComponent().appendingPathComponent("missing/copy.sqlite")
        let error = await storeError { _ = try await store.snapshot(to: nowhere) }
        guard case .snapshot(.destinationUnavailable(let fault))? = error else {
            Issue.record("expected destinationUnavailable, got \(String(describing: error))")
            return
        }
        #expect(fault.code.primary == 14)
        #expect(fault.phase == .snapshot)
        #expect(try strayFiles(beside: url) == ["taken.sqlite"])
        #expect(await store.liveHandles == 2)
        #expect(try await store.diagnostics().snapshots == 0)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 3)
        await store.close()
    }

    @Test("a snapshot cancelled between two steps is not handed over and leaves no file")
    func cancellationBetweenSteps() async throws {
        let url   = try temporaryDatabase()
        let store = try await filled(url, events: 5, configuration: .init(snapshotPagesPerStep: 1))
        var events = await waits(of: store)
        let destination = url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let copying = Task { await storeError { _ = try await store.snapshot(to: destination) } }
        let first = await events.next()
        guard case .yielding(.snapshot, let remaining)? = first else {
            Issue.record("expected the first yield of the snapshot, got \(String(describing: first))")
            return
        }
        #expect(remaining > 0)
        copying.cancel()
        #expect(await copying.value == .cancelled(.snapshot))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try strayFiles(beside: url) == [])
        #expect(await store.liveHandles == 2)
        #expect(try await store.diagnostics().snapshots == 0)
        _ = try await record(EventRow(id: "after", key: "k"), in: store)
        await store.close()
    }

    @Test("a close during a snapshot ends it with closed, and no handle or file survives")
    func closeDuringSnapshot() async throws {
        let url   = try temporaryDatabase()
        let store = try await filled(url, events: 5, configuration: .init(snapshotPagesPerStep: 1))
        var events = await waits(of: store)
        let destination = url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let copying = Task { await storeError { _ = try await store.snapshot(to: destination) } }
        _ = await events.next()
        await store.close()
        #expect(await copying.value == .unavailable(.closed))
        #expect(await store.liveHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try strayFiles(beside: url) == [])
    }

    @Test("a writer active in another process, holding the lock, neither blocks the copy nor gets into it")
    func activeWriterInAnotherProcess() async throws {
        let url   = try temporaryDatabase()
        let store = try await filled(url, events: 3)
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(url.path)").hasPrefix("opened bootstrapped=0"))
        #expect(try await probe.ask("hold 5 100") == "held rows=5")

        let destination = url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let report = try await store.snapshot(to: destination)
        #expect(report.pageCount > 0)
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: destination) == 3)
        #expect(try rawCount("SELECT count(*) FROM brain_apps", at: destination) == 0)

        #expect(try await probe.ask("commit") == "committed")
        #expect(try await probe.ask("close") == "closed")
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 5)
        #expect(try rawCount("SELECT count(*) FROM brain_apps", at: destination) == 0)
        await store.close()
    }
}
