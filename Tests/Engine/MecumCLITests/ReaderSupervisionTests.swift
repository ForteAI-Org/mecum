//
//  ReaderSupervisionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//
//  The supervision's probes on S3-e, carried into the repository unchanged.
//

import AutomationRuntime
import Foundation
import SQLite3
import Testing
@testable import mecum

@MainActor
@Suite("Supervision: readers do not turn another empty SQLite file into a Mecum archive", .serialized)
struct UninitializedArchiveSupervisionTests {
    @Test(arguments: [false, true])
    func anInitializedSQLiteFileIsNotAMecumArchive(useCatalogue: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-sqlite-empty-supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService(directory: directory)
        var db: OpaquePointer?
        try #require(sqlite3_open(memory.url.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK)
        try #require(sqlite3_close(db) == SQLITE_OK)
        let before = try Data(contentsOf: memory.url)
        try #require(!before.isEmpty, "The fixture is a real initialized SQLite file, not a zero-byte placeholder")
        if useCatalogue {
            let result = await BrainCatalog.load(from: memory)
            if case .unavailable = result {} else { Issue.record("The catalogue accepted a SQLite file without the Mecum schema") }
        } else {
            do {
                try await MemoryDiagnosis.open(memory, path: memory.url.path)
                Issue.record("The diagnostic reader accepted and initialized an existing SQLite file without the Mecum schema")
            } catch {}
        }
        await memory.close()
        let after = try Data(contentsOf: memory.url)
        print("SUPERVISION initialized-empty SQLite file, catalogue=\(useCatalogue), bytes before=\(before.count), after=\(after.count)")
        #expect(after == before, "Read-only diagnosis must preserve an uninitialized SQLite file byte for byte")
    }
}

@testable import mecum

@Suite("Supervision: the batch header uses the documented literal escape")
struct BatchHeaderSupervisionTests {
    @Test("A window title beginning with -- is literal before the actual step boundary")
    func aLiteralWindowInTheHeader() throws {
        do {
            let plan = try BatchPlan(arguments: ["batch", "App", "--window", "--", "--Window", "--seat", "--", "act", "Create"])
            #expect(plan.invocation.options["window"] == "--Window")
            #expect(plan.steps.count == 1)
        } catch {
            Issue.record("The valid escaped header was refused: \(error)")
        }
    }
}
