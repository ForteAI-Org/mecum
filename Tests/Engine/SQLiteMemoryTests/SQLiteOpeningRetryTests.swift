//
//  SQLiteOpeningRetryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// An open that never succeeded leaves the instance retryable, from its very first step: a
/// connection the library refuses, a reader's refusal of the file it found, a directory not there
/// yet. No handle is held afterwards and nothing is created by a refused reader. A close stays
/// definitive and prevails over an open in flight, which is a different case from all of these.
@Suite("Retrying an open on the same instance", .serialized)
struct SQLiteOpeningRetryTests {

    @Test("a missing file: the reader is refused and creates nothing, then the same instance opens as producer and bootstraps")
    func missingFileThenProducer() async throws {
        let url   = try temporaryDatabase("retry-missing")
        let store = SQLiteMemoryStore(url: url)
        let first = await storeError { try await store.open(.existingArchive) }
        guard case .open(let fault)? = first else { Issue.record("expected CANTOPEN, got \(String(describing: first))"); return }
        #expect(fault.code.primary == 14)
        #expect(fault.phase == .open)
        #expect(await store.liveHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await storeError { _ = try await store.diagnostics() } == .unavailable(.notOpened), "not opened, not closed")
        // A second refusal is the same refusal: the instance is retried, not stuck.
        guard case .open? = await storeError({ try await store.open(.existingArchive) }) else {
            Issue.record("the second reader open was not the same refusal")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await store.open(.producer)
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.bootstrappedNow)
        #expect(diagnostics.schemaVersion == 2)
        #expect(await store.liveHandles == 2)
        _ = try await record(EventRow(id: "after-retry", key: "k"), in: store)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 1)
        await store.close()
        #expect(await store.liveHandles == 0)
    }

    @Test("an empty file: the reader refuses it byte for byte and bootstraps nothing; the same instance's producer then makes the archive")
    func emptyFileThenProducer() async throws {
        let url = try temporaryDatabase("retry-empty")
        try Data().write(to: url)
        let store = SQLiteMemoryStore(url: url)
        #expect(await storeError { try await store.open(.existingArchive) } == .schema(.uninitialized(fileIsEmpty: true)))
        #expect(await store.liveHandles == 0)
        #expect(try Data(contentsOf: url).isEmpty, "no header, no schema written by the refused reader")
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        try await store.open(.producer)
        #expect(try await store.diagnostics().bootstrappedNow)
        await store.close()
    }

    @Test("a directory not there yet: the producer's open fails, the directory is made, the same instance opens")
    func directoryCreatedThenRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-retry-\(UUID().uuidString)")
        let url   = directory.appendingPathComponent("memory.sqlite")
        let store = SQLiteMemoryStore(url: url)
        let first = await storeError { try await store.open() }
        guard case .open(let fault)? = first else { Issue.record("expected CANTOPEN, got \(String(describing: first))"); return }
        #expect(fault.code.primary == 14)
        #expect(await store.liveHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the store makes no directory: its owner does")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.open()
        #expect(try await store.diagnostics().bootstrappedNow)
        #expect(await store.liveHandles == 2)
        await store.close()
    }

    @Test("callers that open together on a missing file all get the refusal, never closed, and the instance is retried afterwards")
    func concurrentCallersOfAFailedConnection() async throws {
        let url   = try temporaryDatabase("retry-concurrent")
        let store = SQLiteMemoryStore(url: url)
        // Joined or not, each caller's answer is the refusal of an open that never succeeded.
        async let a = storeError { try await store.open(.existingArchive) }
        async let b = storeError { try await store.open(.existingArchive) }
        async let c = storeError { try await store.open(.existingArchive) }
        for answer in await [a, b, c] {
            guard case .open(let fault)? = answer else { Issue.record("expected CANTOPEN, got \(String(describing: answer))"); continue }
            #expect(fault.code.primary == 14)
        }
        #expect(await store.liveHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await store.open()
        #expect(await store.liveHandles == 2)
        await store.close()
    }

    @Test("a close during an open waited on by two callers prevails for both; the instance stays closed, unlike a refused open")
    func closeWithTwoWaitingCallers() async throws {
        let url    = try temporaryDatabase("retry-close")
        let holder = try SQLiteConnection(path: url.path)
        try holder.execute("BEGIN IMMEDIATE")
        let store  = SQLiteMemoryStore(url: url, configuration: SQLiteMemoryStore.Configuration(lockBudget: .seconds(30)))
        var events = await waits(of: store)
        let first  = Task { await storeError { try await store.open() } }
        _ = await events.next()
        // Joined to the open in flight, or arriving after the close, the second caller answers closed.
        let second = Task { await storeError { try await store.open(.existingArchive) } }
        await Task.yield()
        await store.close()
        try holder.execute("ROLLBACK")
        holder.close()
        #expect(await first.value == .unavailable(.closed))
        #expect(await second.value == .unavailable(.closed))
        #expect(await store.liveHandles == 0)
        #expect(await storeError { try await store.open() } == .unavailable(.closed), "close is definitive")
        #expect(await storeError { try await store.open(.existingArchive) } == .unavailable(.closed))
    }

    @Test("a close after a refused open is definitive too: the refusal left the instance retryable, the close ends it")
    func closeAfterARefusedOpen() async throws {
        let url   = try temporaryDatabase("retry-refused-then-closed")
        let store = SQLiteMemoryStore(url: url)
        guard case .open? = await storeError({ try await store.open(.existingArchive) }) else {
            Issue.record("expected the refusal")
            return
        }
        await store.close()
        #expect(await storeError { try await store.open() } == .unavailable(.closed))
        #expect(await store.liveHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing created after the close")
    }
}
