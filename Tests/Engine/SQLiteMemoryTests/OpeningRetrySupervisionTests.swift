//
//  OpeningRetrySupervisionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Foundation
import Memory
import SQLiteMemory
import Testing

@Suite("Supervision: retry after an initial connection failure", .serialized)
struct OpeningFailureRetrySupervisionTests {
    @Test("an existing-only open refuses a missing file; its not-closed instance can later open as producer")
    func readerFailureDoesNotCloseTheStore() async throws {
        let url = try temporaryDatabase("initially-missing")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteMemoryStore(url: url)
        defer { Task { await store.close() } }
        let first = await storeError { try await store.open(.existingArchive) }
        guard case .open(let fault)? = first else { Issue.record("expected initial connection failure, got \(String(describing: first))"); return }
        #expect(fault.code.primary == 14)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let second = await storeError { try await store.open(.producer) }
        print("SUPERVISION retry initial connection: \(String(describing: second))")
        #expect(second == nil, "The store was never closed: its documented open failure is retryable")
        await store.close()
    }
}
