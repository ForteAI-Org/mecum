//
//  SQLiteMemoryInspectionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The read-only diagnosis of an archive file: it says what this build's open would make of the file,
/// reads one committed state under the library's locks and the archive's presence lock, changes
/// nothing of the file, and never makes one.
@Suite("Inspecting an archive file, read only")
struct SQLiteMemoryInspectionTests {

    /// The files of a directory with their bytes, but the two a reader may touch without changing any
    /// data: the WAL index (`-shm`), shared memory every reader of a WAL archive updates, compared by
    /// presence only, and the presence lock, an empty file a diagnosis may make once.
    private func listing(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !name.hasSuffix(".lock") {
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    private func lockIsEmptyIfMade(beside url: URL) throws {
        let lock = url.path + ".lock"
        guard FileManager.default.fileExists(atPath: lock) else { return }
        #expect(try Data(contentsOf: URL(fileURLWithPath: lock)).isEmpty, "the presence lock holds no data")
    }

    @Test("a missing path, an empty file, another shape, a file that is no database and a current archive are told apart and left as found")
    func everyCaseLeftAsFound() async throws {
        let missing = try temporaryDatabase()
        #expect(SQLiteMemoryInspection.inspect(missing).shape == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: missing.deletingLastPathComponent().path).isEmpty,
                "a diagnosis of a missing archive makes nothing, not even the lock file")

        let empty = try temporaryDatabase()
        try Data().write(to: empty)
        let other = try temporaryDatabase()
        let raw = try SQLiteConnection(path: other.path)
        try raw.execute("CREATE TABLE memory_events (x INTEGER)")
        try raw.execute("PRAGMA user_version = 1")
        raw.close()
        let garbage = try temporaryDatabase()
        try Data(repeating: 0x5A, count: 8192).write(to: garbage)
        let current = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: current)
        await store.close()

        for (name, url) in [("empty", empty), ("other", other), ("garbage", garbage), ("current", current)] {
            let before = try listing(url.deletingLastPathComponent())
            let report = SQLiteMemoryInspection.inspect(url)
            let after  = try listing(url.deletingLastPathComponent())
            #expect(after == before, "\(name): \(before.keys.sorted()) became \(after.keys.sorted())")
            try lockIsEmptyIfMade(beside: url)
            switch url {
                case empty  : #expect(report.shape == .empty)
                case other  : if case .refused(.missingTables(let tables)) = report.shape { #expect(tables.contains("memory_agent_actions")) }
                              else { Issue.record("another shape: \(report.shape)") }
                case garbage: if case .unreadable = report.shape {} else { Issue.record("no database: \(report.shape)") }
                default     : #expect(report.shape == .current && report.counts["memory_events"] == 0
                                      && report.schemaVersion == 2)
            }
        }
    }

    @Test("a newer schema version is refused as newer, not reported as this build's shape, and left as found")
    func futureVersion() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("PRAGMA user_version = 99")
        raw.close()
        let before = try listing(url.deletingLastPathComponent())
        let report = SQLiteMemoryInspection.inspect(url)
        #expect(report.shape == .refused(.future(found: 99, supported: 2)))
        #expect(report.schemaVersion == 99 && report.counts.isEmpty)
        #expect(try listing(url.deletingLastPathComponent()) == before)
    }

    @Test("version, shape and counts are one committed state: a commit by another connection during the reading is not in the report")
    func oneCommittedState() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        let writer = try SQLiteConnection(path: url.path)
        defer { writer.close() }
        try writer.execute("INSERT INTO brain_apps (bundle_id) VALUES ('com.example.before')")

        var committedDuringTheReading = false
        let report = SQLiteMemoryInspection.inspect(url) {
            // A writer opened after the diagnosis began, committing between its reads.
            do {
                try writer.execute("INSERT INTO brain_apps (bundle_id) VALUES ('com.example.during')")
                committedDuringTheReading = true
            } catch { Issue.record("the writer could not commit while the diagnosis read: \(error)") }
        }
        #expect(committedDuringTheReading, "a reader does not hold up the writer")
        #expect(report.shape == .current)
        #expect(report.counts["brain_apps"] == 1, "the report is the state as of its first read: \(report.counts)")
        #expect(SQLiteMemoryInspection.inspect(url).counts["brain_apps"] == 2, "the next diagnosis sees the commit")
    }

    @Test("an archive opened by a store of this process while the diagnosis reads it is read through the library's locks, never as immutable")
    func readWhileOpen() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        defer { Task { await store.close() } }
        _ = try await store.write { try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('com.example.open')") }
        let report = SQLiteMemoryInspection.inspect(url)
        #expect(report.shape == .current && report.counts["brain_apps"] == 1)
        _ = try await store.write { try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('com.example.again')") }
        #expect(SQLiteMemoryInspection.inspect(url).counts["brain_apps"] == 2, "the diagnosis sees the store's commits")
    }

    @Test("a WAL archive whose log files are gone is not read as immutable: the diagnosis says it cannot read it as it lies, and makes no file")
    func walArchiveWithoutItsLogFiles() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let before = try listing(url.deletingLastPathComponent())
        let report = SQLiteMemoryInspection.inspect(url)
        guard case .unavailable(let why) = report.shape else { Issue.record("expected unavailable, got \(report.shape)"); return }
        #expect(why.contains("log files"))
        #expect(try listing(url.deletingLastPathComponent()) == before, "no -wal or -shm was made")
    }

    @Test("while a recovery holds the archive the diagnosis reads nothing and says so; afterwards it reads")
    func recoveryHoldsTheArchive() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        await store.close()
        let recovery = try #require(try SQLiteMemoryPresence.take(.exclusive, of: url))
        let held = SQLiteMemoryInspection.inspect(url)
        guard case .unavailable(let why) = held.shape else { Issue.record("expected unavailable, got \(held.shape)"); return }
        #expect(why.contains("recovery") && held.schemaVersion == nil)
        recovery.release()
        #expect(SQLiteMemoryInspection.inspect(url).shape == .current)
    }
}
