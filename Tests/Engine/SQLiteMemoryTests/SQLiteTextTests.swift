//
//  SQLiteTextTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// A stored text is read strictly: bytes that are not valid UTF-8 are refused with a typed error
/// that says where and never what, not replaced, not emptied, not turned into NULL. The bytes stay
/// readable as bytes. `STRICT` checks a value's storage class and lets such bytes into a text
/// column, which is why the check is the store's.
@Suite("Strict text reading")
struct SQLiteTextTests {

    /// A STRICT temporary table on the writer, filled through SQL so the bytes never pass through
    /// this module's own binding: the fixture is the library's `CAST(X'..' AS TEXT)`.
    private func fixture(_ rows: [(label: String, sql: String)]) async throws -> SQLiteMemoryStore {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        _ = try await store.write { transaction in
            try transaction.execute("CREATE TEMP TABLE strict_probe (label TEXT NOT NULL, value TEXT) STRICT")
            for row in rows {
                try transaction.execute("INSERT INTO strict_probe VALUES ('\(row.label)', \(row.sql))")
            }
        }
        return store
    }

    private func readText(_ label: String, in store: SQLiteMemoryStore) async -> MemoryStoreError? {
        await storeError {
            _ = try await store.write { transaction in
                try transaction.query("SELECT value FROM strict_probe WHERE label = ?", [.text(label)]) { try $0.text(0) }
            }
        }
    }

    private func readBytes(_ label: String, in store: SQLiteMemoryStore) async throws -> [UInt8]? {
        try await store.write { transaction in
            try transaction.query("SELECT value FROM strict_probe WHERE label = ?", [.text(label)]) { $0.bytes(0) }.first ?? nil
        }
    }

    @Test("invalid UTF-8 in a STRICT text column is refused by position, and its bytes stay readable")
    func invalidSequences() async throws {
        let store = try await fixture([
            ("middle",    "CAST(X'61FF62' AS TEXT)"),
            ("truncated", "CAST(X'E282' AS TEXT)"),
            ("overlong",  "CAST(X'C080' AS TEXT)"),
            ("surrogate", "CAST(X'EDA080' AS TEXT)"),
            ("after",     "CAST(X'C3A9FF' AS TEXT)"),
        ])
        let storedAsText = try await store.write { transaction in
            try transaction.query("SELECT typeof(value) FROM strict_probe WHERE label = 'middle'") { try $0.text(0) }.first ?? nil
        }
        #expect(storedAsText == "text")
        let committedBefore = try await store.diagnostics().commits
        #expect(await readText("middle", in: store) == .malformedText(MemoryTextFault(column: 0, byteCount: 3, invalidByteOffset: 1)))
        #expect(await readText("truncated", in: store) == .malformedText(MemoryTextFault(column: 0, byteCount: 2, invalidByteOffset: 0)))
        #expect(await readText("overlong", in: store) == .malformedText(MemoryTextFault(column: 0, byteCount: 2, invalidByteOffset: 0)))
        #expect(await readText("surrogate", in: store) == .malformedText(MemoryTextFault(column: 0, byteCount: 3, invalidByteOffset: 0)))
        #expect(await readText("after", in: store) == .malformedText(MemoryTextFault(column: 0, byteCount: 3, invalidByteOffset: 2)))
        // Each refusal ended its transaction with nothing committed; the store goes on.
        #expect(try await store.diagnostics().commits == committedBefore)
        #expect(await store.liveHandles == 2)
        #expect(try await readBytes("middle", in: store) == [0x61, 0xFF, 0x62])
        #expect(try await readBytes("after", in: store) == [0xC3, 0xA9, 0xFF])
        _ = try await store.write { try $0.execute("INSERT INTO strict_probe VALUES ('later', 'fine')") }
        #expect(try await store.diagnostics().commits == committedBefore + 3)
        await store.close()
    }

    @Test("valid text of every shape reads back whole: Unicode, an internal NUL, empty, and NULL stays NULL")
    func validShapes() async throws {
        let store = try await fixture([
            ("unicode", "CAST(X'636166C3A920F09FA7A0' AS TEXT)"),
            ("nul",     "CAST(X'7000710072' AS TEXT)"),
            ("empty",   "''"),
            ("null",    "NULL"),
        ])
        let rows = try await store.write { transaction in
            try transaction.query("SELECT label, value, typeof(value) FROM strict_probe ORDER BY label") { row in
                (try row.text(0) ?? "", try row.text(1), try row.text(2) ?? "")
            }
        }
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, ($0.1, $0.2)) })
        #expect(byLabel["unicode"]?.0 == "caf\u{E9} \u{1F9E0}")
        #expect(byLabel["nul"]?.0 == "p\u{0000}q\u{0000}r")
        #expect(byLabel["nul"]?.0?.utf8.count == 5)
        #expect(byLabel["empty"]?.0 == "")
        #expect(byLabel["empty"]?.1 == "text")
        #expect(byLabel["null"]?.0 == nil)
        #expect(byLabel["null"]?.1 == "null")
        await store.close()
    }

    @Test("the reader refuses the same bytes in a persisted STRICT table, and reads on")
    func onTheReader() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        _ = try await store.write { transaction in
            try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (1, CAST(X'61FF62' AS TEXT))")
            try transaction.execute("INSERT INTO brain_apps (app_id, bundle_id) VALUES (2, 'fine.app')")
        }
        let refused = await storeError {
            _ = try await store.read { snapshot in
                try snapshot.query("SELECT bundle_id FROM brain_apps WHERE app_id = 1") { try $0.text(0) }
            }
        }
        #expect(refused == .malformedText(MemoryTextFault(column: 0, byteCount: 3, invalidByteOffset: 1)))
        let bytes = try await store.read { snapshot in
            try snapshot.query("SELECT bundle_id FROM brain_apps WHERE app_id = 1") { $0.bytes(0) }.first ?? nil
        }
        #expect(bytes == [0x61, 0xFF, 0x62])
        let fine = try await store.read { snapshot in
            try snapshot.query("SELECT bundle_id FROM brain_apps WHERE app_id = 2") { try $0.text(0) }.first ?? nil
        }
        #expect(fine == "fine.app")
        #expect(try await count("SELECT count(*) FROM brain_apps", in: store) == 2)
        await store.close()
    }
}
