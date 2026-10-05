//
//  ReaderOpeningSupervisionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//
//  The supervision's probe on S3-e, carried into the repository unchanged.
//

import AutomationRuntime
import Foundation
import SQLiteMemory
import Testing

@MainActor
@Suite("Supervision: a Brain catalogue read preserves a pre-existing empty file")
struct ReadingOnlySupervisionTests {
    @Test("A reader reports a zero-byte archive as unavailable, never bootstraps it")
    func catalogueDoesNotInitializeTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-read-only-supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService(directory: directory)
        try Data().write(to: memory.url)
        let before = try Data(contentsOf: memory.url)
        let result = await BrainCatalog.load(from: memory)
        switch result {
        case .unavailable: break
        case .missing: Issue.record("The existing file is not missing")
        case .loaded(let entries): Issue.record("A zero-byte file was reported as a valid catalogue with \(entries.count) entries")
        }
        let status = await memory.status()
        print("SUPERVISION zero-byte catalogue state: \(status.state); bootstrap: \(String(describing: status.diagnostics?.bootstrappedNow))")
        await memory.close()
        #expect(try Data(contentsOf: memory.url) == before, "A read-only visit must leave the pre-existing empty file intact")
    }
}
