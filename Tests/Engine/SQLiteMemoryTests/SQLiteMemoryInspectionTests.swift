//
//  SQLiteMemoryInspectionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
@testable import SQLiteMemory
import Testing

/// The read-only diagnosis of an archive file: it says what the file is and changes nothing, whatever
/// the file is, and it never makes one.
@Suite("Inspecting an archive file, read only")
struct SQLiteMemoryInspectionTests {

    /// The files of a directory with their bytes. The WAL index (`-shm`) is shared memory every reader
    /// of a WAL archive updates as it reads, and holds no data: only its presence is compared.
    private func listing(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    @Test("a missing path, an empty file, another shape, a file that is no database and a current archive are told apart and left as found")
    func everyCaseLeftAsFound() async throws {
        let missing = try temporaryDatabase()
        #expect(SQLiteMemoryInspection.inspect(missing).shape == .missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "a diagnosis never makes a file")

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
            switch url {
                case empty  : #expect(report.shape == .empty)
                case other  : if case .differs(let objects) = report.shape { #expect(objects.contains("table memory_events")) }
                              else { Issue.record("another shape: \(report.shape)") }
                case garbage: if case .unreadable = report.shape {} else { Issue.record("no database: \(report.shape)") }
                default     : #expect(report.shape == .matches && report.counts["memory_events"] == 0)
            }
        }
    }
}
