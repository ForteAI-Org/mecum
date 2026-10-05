//
//  MemoryServiceFailureTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

@testable import AutomationRuntime
import Foundation
import Memory
import SQLite3
import SQLiteMemory
import Testing

/// A cleanup that fails, through the service: the primary failure is a real one of the library on the
/// test's own temporary archive (a constraint raised by a trigger the test adds, or a table the test
/// removed), and the rollback after it is answered as refused by the store's internal seam
/// (`refuseNextRollbackOfTheStore`), which leaves the store unusable. Not a physical fault. The service
/// must say so after that first operation, keep the primary error for its caller, let go of the
/// archive, and open a new store on the same file after its interval, with nothing replayed.
@Suite("The service after a cleanup that fails", .serialized)
struct MemoryServiceFailureTests {

    private static let configuration = MemoryService.Configuration(
        store: .init(lockBudget: .seconds(30), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
        reopenInterval: .milliseconds(150)
    )

    /// A connection of another program on the archive, for the schema changes and locks a test needs.
    private final class Raw {
        let handle: OpaquePointer
        init(_ url: URL) throws {
            var db: OpaquePointer?
            try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
            handle = try #require(db)
        }
        @discardableResult
        func run(_ sql: String) -> Int32 { sqlite3_exec(handle, sql, nil, nil, nil) }
        func text(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
        func close() { sqlite3_close(handle) }
    }

    private func event(_ id: String, _ memory: MemoryService) -> MemoryEventRecord {
        Fixtures.context(id).event(app: Fixtures.app, occurredAtMS: memory.clock.calendarMS())
    }

    private func degradedReason(_ memory: MemoryService) async -> String? {
        if case .degraded(let reason) = await memory.status().state { return reason }
        return nil
    }

    private func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test("a constraint whose cleanup fails degrades the service at once, keeps the primary error, lets the archive go, and a new store opens after the interval")
    func aContractWithAFailedCleanupDegradesAtOnce() async throws {
        let memory = MemoryService(directory: Fixtures.directory(), configuration: Self.configuration)
        _ = try await memory.record(event("kept", memory))
        let raw = try Raw(memory.url)
        defer { raw.close() }
        #expect(raw.run("CREATE TRIGGER s4_refuse BEFORE INSERT ON memory_events WHEN NEW.event_id = 'refused' "
                        + "BEGIN SELECT RAISE(ABORT, 'refused by the test'); END") == SQLITE_OK)
        #expect(await memory.refuseNextRollbackOfTheStore(primary: 10, extended: 10, message: "rollback refused by the test's seam"))

        let error = await #expect(throws: MemoryStoreError.self) { _ = try await memory.record(event("refused", memory)) }
        guard case .contract(let primary)? = error else { Issue.record("expected the constraint, got \(String(describing: error))"); return }
        #expect(primary.code.primary == 19, "the primary error is the trigger's constraint, kept for the caller")
        #expect(primary.cleanup == .failed(MemoryStoreFault.Code(primary: 10, extended: 10), "rollback refused by the test's seam"))

        let reason = try #require(await degradedReason(memory), "degraded after the first operation, not at the next")
        #expect(reason.contains("cleanup") && reason.contains("19"), "the reason keeps the primary code and the cleanup: \(reason)")
        await #expect(throws: MemoryUnavailable.self) { _ = try await memory.event("kept") }
        // The service let go of the archive: another connection changes the journal, which needs every other gone.
        #expect(raw.run("BEGIN IMMEDIATE") == SQLITE_OK)
        #expect(raw.text("SELECT count(*) FROM memory_events") == "1", "nothing of the refused write")
        raw.run("ROLLBACK")
        raw.run("DROP TRIGGER s4_refuse")

        try await Task.sleep(for: .milliseconds(200))
        #expect(try await memory.event("kept") != nil, "a new store on the same file, after the interval")
        let status = await memory.status()
        #expect(status.isReady && status.diagnostics?.bootstrappedNow == false, "the same archive, not a new one")
        #expect(try await memory.event("refused") == nil, "nothing replayed")
        #expect(try await memory.record(event("refused", memory)) == .committed, "the owner may offer the fact again, once")
        await memory.close()
    }

    @Test("a constraint whose rollback succeeds is the caller's error and degrades nothing")
    func aContractWithACleanRollbackStaysReady() async throws {
        let memory = MemoryService(directory: Fixtures.directory(), configuration: Self.configuration)
        _ = try await memory.record(event("kept", memory))
        let raw = try Raw(memory.url)
        defer { raw.close() }
        raw.run("CREATE TRIGGER s4_refuse BEFORE INSERT ON memory_events WHEN NEW.event_id = 'refused' "
                + "BEGIN SELECT RAISE(ABORT, 'refused by the test'); END")
        let error = await #expect(throws: MemoryStoreError.self) { _ = try await memory.record(event("refused", memory)) }
        guard case .contract(let fault)? = error else { Issue.record("expected the constraint"); return }
        #expect(fault.cleanup == .rolledBack)
        #expect(await memory.status().isReady, "a healthy archive is not degraded by a refused fact")
        _ = try await memory.record(event("after", memory))
        await memory.close()
    }

    @Test("a caller already waiting for the lock when a read's cleanup fails is told, writes nothing, and the archive is let go")
    func aWaitingCallerMeetsTheFailure() async throws {
        let memory = MemoryService(directory: Fixtures.directory(), configuration: Self.configuration)
        _ = try await memory.record(event("kept", memory))
        let raw = try Raw(memory.url)
        defer { raw.close() }
        #expect(raw.run("DROP TABLE memory_experiences") == SQLITE_OK, "a table the catalogue reads, gone: a real library error")
        #expect(raw.run("BEGIN IMMEDIATE") == SQLITE_OK)
        let waiting = Task { try await memory.record(event("waiting", memory)) }
        await until { await memory.status().diagnostics?.retainedWrites == 1 }
        #expect(await memory.status().diagnostics?.retainedWrites == 1)

        #expect(await memory.refuseNextRollbackOfTheStore(primary: 10, extended: 10, message: "rollback refused by the test's seam"))
        let error = await #expect(throws: MemoryStoreError.self) { _ = try await memory.overview() }
        guard case .contract(let primary)? = error else { Issue.record("expected the read's failure, got \(String(describing: error))"); return }
        #expect(primary.code.primary == 1)
        #expect(await degradedReason(memory) != nil, "degraded by the read itself")

        raw.run("ROLLBACK")
        let answer = await waiting.result
        if case .success = answer { Issue.record("the waiting write claimed a save") }
        #expect(raw.text("SELECT count(*) FROM memory_events WHERE event_id = 'waiting'") == "0")
        #expect(raw.text("PRAGMA journal_mode = DELETE") == "delete", "no connection of the service is left on the file")
        await memory.close()
    }

    @Test("a close prevails over a degraded service: closed for good, never reopened after the interval")
    func closePrevailsOverTheDegradedState() async throws {
        let memory = MemoryService(directory: Fixtures.directory(), configuration: Self.configuration)
        _ = try await memory.record(event("kept", memory))
        let raw = try Raw(memory.url)
        defer { raw.close() }
        raw.run("CREATE TRIGGER s4_refuse BEFORE INSERT ON memory_events WHEN NEW.event_id = 'refused' "
                + "BEGIN SELECT RAISE(ABORT, 'refused by the test'); END")
        _ = await memory.refuseNextRollbackOfTheStore(primary: 10, extended: 10, message: "refused")
        _ = try? await memory.record(event("refused", memory))
        #expect(await degradedReason(memory) != nil)
        await memory.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await memory.status().state == .closed)
        await #expect(throws: MemoryUnavailable.self) { _ = try await memory.event("kept") }
        #expect(await memory.status().state == .closed)
    }
}
