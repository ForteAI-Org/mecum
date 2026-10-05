//
//  ReaderOpeningTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import CryptoKit
import Foundation
import Memory
import SQLite3
import SQLiteMemory
import Testing

/// A reader's open (`MemoryService.openForReading`, `SQLiteMemoryStore.Opening.existingArchive`)
/// against a producer's: files that are not a Mecum archive are refused and left byte for byte,
/// with no table, version, journal or commit added and the service as it was; a valid archive opens
/// with nothing written; a producer still creates, bootstraps and writes on the same service; an open
/// in flight is shared both ways; only the owner closes.
@MainActor
@Suite("Opening the memory for a reader", .serialized)
struct ReaderOpeningTests {

    private static let quick = MemoryService.Configuration(
        store: .init(lockBudget: .milliseconds(10), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(2)),
        reopenInterval: .seconds(60)
    )

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `sql` on a file of its own, as another program would make it.
    private static func sqlite(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        try #require(sqlite3_close(db) == SQLITE_OK)
    }

    /// The tables and the user version of a file, read with a connection of its own.
    private static func shape(_ url: URL) throws -> (tables: Int, version: Int) {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func count(_ sql: String) -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
        }
        return (count("SELECT count(*) FROM sqlite_schema WHERE type = 'table'"), count("PRAGMA user_version"))
    }

    private static func prepared(_ make: (URL) throws -> Void) throws -> (directory: URL, file: URL) {
        let directory = Fixtures.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.sqlite")
        try make(file)
        return (directory, file)
    }

    @Test("files that are not a Mecum archive are refused by a reader and left byte for byte, the service as it was", arguments: [
        "zero bytes", "SQLite with no schema", "another program's tables", "a newer schema version",
    ])
    func refusedFilesAreUntouched(_ kind: String) async throws {
        let (directory, file) = try Self.prepared { file in
            switch kind {
                case "zero bytes"               : try Data().write(to: file)
                case "SQLite with no schema"    : try Self.sqlite(file, "VACUUM")
                case "another program's tables" : try Self.sqlite(file, "CREATE TABLE notes(x); INSERT INTO notes VALUES (1);")
                default                         : try Self.sqlite(file, "CREATE TABLE t(x); PRAGMA user_version = 9;")
            }
        }
        let before = try Self.digest(file)
        let shapeBefore = kind == "zero bytes" ? nil : try Self.shape(file)
        let memory = MemoryService(directory: directory)
        await #expect(throws: (any Error).self) { try await memory.openForReading() }
        guard case .unavailable = await BrainCatalog.load(from: memory) else {
            Issue.record("\(kind) was not said unavailable"); return
        }
        let status = await memory.status()
        #expect(status.state == .notOpened, "a refused reading leaves the service as it was: \(status.state)")
        #expect(status.diagnostics == nil, "nothing was opened: no commit, no bootstrap")
        await memory.close()
        #expect(try Self.digest(file) == before, "\(kind): byte for byte")
        if let shapeBefore {
            let after = try Self.shape(file)
            #expect(after.tables == shapeBefore.tables && after.version == shapeBefore.version, "no table and no version added")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"), "no journal turned to WAL")
    }

    @Test("a reader creates nothing: no directory and no file, and a file gone after it was seen is not replaced")
    func missingStaysMissing() async throws {
        let directory = Fixtures.directory()
        let memory = MemoryService(directory: directory)
        #expect(await BrainCatalog.load(from: memory) == .missing(path: memory.url.path))
        await #expect(throws: (any Error).self) { try await memory.openForReading() }
        #expect(!FileManager.default.fileExists(atPath: directory.path), "neither the directory nor the file was created")
        await memory.close()
    }

    @Test("a valid archive opens for reading with nothing written, and its Brain and traces read back")
    func aValidArchiveOpens() async throws {
        let directory = Fixtures.directory()
        let producer = MemoryService(directory: directory)
        let context = Fixtures.context("valid-1")
        try await Fixtures.plan(.observe, context, in: producer)
        let clock = producer.clock
        let brain = BrainMemory(brains: producer, applications: producer, clock: { clock.brainNow() })
        _ = await CallRecorder(memory: producer, brain: brain, context: context, sessionRevision: 1, requestedAt: clock.brainNow())
            .observe(Fixtures.window(["Export", "Cancel"]))
        await producer.close()
        let file = directory.appendingPathComponent("memory.sqlite")
        let reader = MemoryService(directory: directory)
        try await reader.openForReading()
        let status = await reader.status()
        #expect(status.isReady && status.diagnostics?.bootstrappedNow == false && status.diagnostics?.commits == 0)
        guard case .loaded(let entries) = await BrainCatalog.load(from: reader) else { Issue.record("not loaded"); return }
        #expect(entries.map(\.bundleID) == [Fixtures.bundle])
        #expect(try await reader.entries(inTrace: "trace-1", after: nil, limit: 10).count == 1)
        #expect(await reader.status().diagnostics?.commits == 0, "the readings committed nothing")
        await reader.close()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("the owner's service stays a producer: after a refused or a missing reading it creates, bootstraps and keeps writing")
    func theProducerIsNotDisabled() async throws {
        // A visit to a missing archive, then the owner's first write creates it, and a later visit reads it.
        let fresh = MemoryService(directory: Fixtures.directory())
        #expect(await BrainCatalog.load(from: fresh) == .missing(path: fresh.url.path))
        try await Fixtures.plan(.observe, Fixtures.context("fresh-1"), in: fresh)
        #expect(await fresh.status().diagnostics?.bootstrappedNow == true, "the producer's open made the archive, as in S1")
        guard case .loaded = await BrainCatalog.load(from: fresh) else { Issue.record("the new archive was not read"); return }
        try await Fixtures.plan(.observe, Fixtures.context("fresh-2"), in: fresh)
        #expect(try await fresh.event("fresh-2") != nil, "and keeps writing after the visit")
        #expect(await fresh.status().isReady, "the visit closed nothing")
        await fresh.close()
        // A visit to a zero-byte file is refused; the owner's producer open then bootstraps it, its own decision.
        let (directory, _) = try Self.prepared { try Data().write(to: $0) }
        let shared = MemoryService(directory: directory)
        guard case .unavailable = await BrainCatalog.load(from: shared) else { Issue.record("not refused"); return }
        try await Fixtures.plan(.observe, Fixtures.context("after-refusal"), in: shared)
        #expect(try await shared.event("after-refusal") != nil)
        guard case .loaded = await BrainCatalog.load(from: shared) else { Issue.record("the bootstrapped archive was not read"); return }
        await shared.close()
    }

    @Test("a reader joins the owner's open in flight and shares it: no second archive, no close by the reader")
    func aReaderJoinsTheOwnersOpen() async throws {
        let directory = Fixtures.directory()
        let first = MemoryService(directory: directory)
        try await first.open()
        await first.close()
        let writer = try ExternalWriter(directory.appendingPathComponent("memory.sqlite"))
        writer.lock()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        let owner = Task { try await service.open() }
        await Self.until { await service.status().state == .opening }
        let reading = Task { await BrainCatalog.load(from: service) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await service.status().state == .opening, "still the owner's one attempt")
        writer.release()
        try await owner.value
        #expect(await reading.value == .loaded([]))
        #expect(await service.status().isReady, "the reader closed nothing")
        try await Fixtures.plan(.observe, Fixtures.context("after-join"), in: service)
        await service.close()
    }

    @Test("a producer that joins a reader's attempt which refuses the file gets its own open at once, and the reader its refusal")
    func aProducerJoiningARefusedReading() async throws {
        let (directory, file) = try Self.prepared { try Data().write(to: $0) }
        // Another program holds the file exclusively: the reader's attempt waits, cycle after cycle.
        let holder = try ExternalWriter(file)
        holder.lockExclusively()
        let service = MemoryService(directory: directory, configuration: Self.quick)
        let reader = Task { try await service.openForReading() }
        await Self.until { await service.status().state == .opening }
        let producer = Task { try await Fixtures.plan(.observe, Fixtures.context("joined"), in: service) }
        try await Task.sleep(for: .milliseconds(40))
        holder.release()
        let refusal = await reader.result
        if case .failure(MemoryStoreError.schema(.uninitialized(let empty))) = refusal { #expect(empty) }
        else { Issue.record("the reader was not refused: \(refusal)") }
        try await producer.value
        #expect(try await service.event("joined") != nil, "the producer opened on its own and wrote")
        #expect(await service.status().diagnostics?.bootstrappedNow == true)
        await service.close()
    }

    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
