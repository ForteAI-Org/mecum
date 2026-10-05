//
//  SQLiteCheckpointTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The checkpoint policy is the library's automatic passive one, documented and observed, plus an
/// explicit passive checkpoint that reports what it moved and never fails for a reader still on
/// an older snapshot.
@Suite("Checkpoints of the write-ahead log")
struct SQLiteCheckpointTests {

    private func walSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? UInt64) ?? 0
    }

    @Test("an explicit passive checkpoint moves every frame when nobody needs them, and is reported")
    func explicitCheckpoint() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        #expect(try await store.diagnostics().autoCheckpointFrames == 1000)
        for index in 0..<20 {
            _ = try await record(EventRow(id: "e\(index)", key: "k\(index)"), in: store)
        }
        let report = try await store.checkpoint()
        #expect(report.frames > 0)
        #expect(report.checkpointedFrames == report.frames)
        #expect(report.outcome == .complete)
        #expect(report.duration >= .zero)
        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.checkpoints == 1)
        #expect(diagnostics.lastCheckpoint == report)
        // Nothing new: the log's frames are all in the file already.
        let again = try await store.checkpoint()
        #expect(again.outcome == .complete)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 20)
        await store.close()
    }

    @Test("a reader on an older snapshot keeps the rest of the log: partial, not a failure, and the store writes on")
    func readerKeepsTheRest() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        for index in 0..<10 {
            _ = try await record(EventRow(id: "a\(index)", key: "a-k\(index)"), in: store)
        }
        #expect(try await store.checkpoint().outcome == .complete)
        let reader = try SQLiteConnection(path: url.path, readOnly: true)
        try reader.execute("BEGIN")
        #expect(try reader.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 10)
        for index in 0..<10 {
            _ = try await record(EventRow(id: "b\(index)", key: "b-k\(index)"), in: store)
        }
        let partial = try await store.checkpoint()
        #expect(partial.outcome == .partial)
        #expect(partial.checkpointedFrames < partial.frames)
        _ = try await record(EventRow(id: "c", key: "c-k"), in: store)
        #expect(try await count("SELECT count(*) FROM memory_events", in: store) == 21)
        #expect(try reader.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 10)
        try reader.execute("COMMIT")
        reader.close()
        let complete = try await store.checkpoint()
        #expect(complete.outcome == .complete)
        #expect(complete.checkpointedFrames == complete.frames)
        #expect(try await store.diagnostics().checkpoints == 3)
        await store.close()
    }

    @Test("the library's automatic checkpoint keeps the log bounded across many commits")
    func automaticCheckpointBoundsTheLog() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        let padding = String(repeating: "x", count: 3900)
        // Ten commits of about 250 pages each: 2500 pages, well past the 1000-frame threshold.
        for batch in 0..<10 {
            _ = try await store.write { transaction in
                for index in 0..<250 {
                    try transaction.execute("INSERT INTO brain_apps (bundle_id) VALUES (?)", [.text("app.\(batch).\(index).\(padding)")])
                }
            }
        }
        let size = try walSize(url)
        #expect(size > 0)
        #expect(size < 8 * 1024 * 1024)
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 2500)
        await store.close()
    }
}
