//
//  SaveFailureTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import SQLite3
import Testing
@testable import Workspace

/// A save that fails must leave nothing pending in the store's context: the
/// next unrelated save would otherwise commit it.
///
/// The failure is real. A second SQLite connection to the store file adds a
/// trigger that makes one kind of write to one table fail with an ordinary SQL
/// error, so SQLite itself refuses it and nothing in the store is faked. The error
/// must not be a constraint violation: Core Data resolves those through its
/// merge policy, and the save then succeeds.
@Suite("A failed write")
struct SaveFailureTests {

    @Test("A failed append does not reach disk with the next save")
    func aFailedAppendIsRolledBack() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store     = try WorkspaceStore.opening(in: directory)
        let workspace = UUID()
        let execution = UUID()
        let refused   = NewEvent(workspaceID: workspace, subjectID: execution, type: .executionCompleted)

        try await Self.refusing("INSERT", on: "ZWORKSPACEEVENT", in: directory) {
            await #expect(throws: (any Error).self) { try await store.append(refused) }
        }

        // An unrelated write that succeeds is the save that used to carry the
        // failed insert to disk.
        try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance())

        #expect(try await store.events(matching: EventQuery(scope: .subject(execution))).isEmpty)
        let reopened = try WorkspaceStore.opening(in: directory)
        #expect(try await reopened.events(matching: EventQuery(scope: .subject(execution))).isEmpty)
        #expect(try await reopened.workers().map(\.name) == ["Atlas"])
    }

    @Test("A failed edit is undone in memory and does not reach disk with the next save")
    func aFailedEditIsRolledBack() async throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let store  = try WorkspaceStore.opening(in: directory)
        let worker = try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance())

        try await Self.refusing("UPDATE", on: "ZWORKER", in: directory) {
            await #expect(throws: (any Error).self) { try await store.update(worker: worker.id, .name("Nova")) }
        }

        // A configuration is a new row in another table, so this save succeeds
        // and is the one that used to carry the rename with it.
        try await store.configure(worker: worker.id, selection: TemporaryStore.firstSelection)

        #expect(try await store.worker(worker.id)?.name == "Atlas")
        let reopened = try WorkspaceStore.opening(in: directory)
        let after    = try await reopened.worker(worker.id)
        #expect(after?.name == "Atlas")
        #expect(after?.configurationVersion == 1)
    }

    /// Runs `body` while SQLite fails every `statement` (`INSERT` or `UPDATE`)
    /// on `table`.
    private static func refusing(
        _ statement : String,
        on table    : String,
        in directory: URL,
        _ body      : () async throws -> Void
    ) async throws {
        let path = directory.appending(path: WorkspaceStoreFile.storeName).path(percentEncoded: false)
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        try #require(sqlite3_open(path, &connection) == SQLITE_OK)

        let create = """
            CREATE TRIGGER test_refusal BEFORE \(statement) ON \(table)
            BEGIN SELECT json('this is not JSON, so the write fails'); END;
            """
        try #require(sqlite3_exec(connection, create, nil, nil, nil) == SQLITE_OK)
        do {
            try await body()
        } catch {
            // The body's failure is the one reported; the store file is discarded.
            _ = sqlite3_exec(connection, "DROP TRIGGER test_refusal;", nil, nil, nil)
            throw error
        }
        try #require(sqlite3_exec(connection, "DROP TRIGGER test_refusal;", nil, nil, nil) == SQLITE_OK)
    }
}
