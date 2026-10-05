//
//  SQLiteBindingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// Values cross the binding boundary whole: a text with a NUL inside it, an empty text apart from
/// NULL, Unicode of every width, a blob with zero bytes. A statement is given exactly the values it
/// asks for: a missing one is a contract error, never a silent NULL.
@Suite("Bindings and readings")
struct SQLiteBindingTests {

    private func probe() async throws -> SQLiteMemoryStore {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        _ = try await store.write { transaction in
            try transaction.execute("CREATE TEMP TABLE probe (label TEXT, value)")
        }
        return store
    }

    /// Writes the value and reads it back: as text unless `asText` is false, since a blob's bytes
    /// need not be UTF-8 and reading them as text is a refusal of its own.
    private func roundTrip(_ store: SQLiteMemoryStore, _ label: String, _ value: SQLiteValue, asText: Bool = true) async throws -> (text: String?, bytes: [UInt8]?, type: String) {
        try await store.write { transaction in
            try transaction.execute("INSERT INTO probe (label, value) VALUES (?, ?)", [.text(label), value])
            return try transaction.query("SELECT value, typeof(value) FROM probe WHERE label = ?", [.text(label)]) { row in
                (asText ? try row.text(0) : nil, row.bytes(0), try row.text(1) ?? "")
            }.first ?? (nil, nil, "")
        }
    }

    @Test("a text with a NUL inside it is stored and read back whole")
    func embeddedNUL() async throws {
        let store   = try await probe()
        let offered = "prefix\u{0000}suffix"
        #expect(offered.utf8.count == 13)
        let stored = try await roundTrip(store, "nul", .text(offered))
        #expect(stored.text == offered)
        #expect(stored.text?.utf8.count == 13)
        #expect(stored.type == "text")
        // The probe table is TEMP, so it lives on the writer's connection only.
        let length = try await store.write { transaction in
            try transaction.query("SELECT length(value), length(CAST(value AS BLOB)) FROM probe WHERE label = 'nul'") { row in
                (row.integer(0), row.integer(1))
            }.first
        }
        #expect(length?.1 == 13)
        await store.close()
    }

    @Test("Unicode of every width round-trips byte for byte")
    func unicode() async throws {
        let store   = try await probe()
        let offered = "caf\u{E9} \u{1F9E0} e\u{0301} \u{4F60}\u{597D} \u{0000}\u{FEFF}"
        let stored  = try await roundTrip(store, "unicode", .text(offered))
        #expect(stored.text == offered)
        #expect(Array(stored.text?.utf8 ?? "".utf8) == Array(offered.utf8))
        await store.close()
    }

    @Test("an empty text is a text, and NULL is NULL")
    func emptyTextVersusNull() async throws {
        let store = try await probe()
        let empty = try await roundTrip(store, "empty", .text(""))
        #expect(empty.text == "")
        #expect(empty.type == "text")
        let null = try await roundTrip(store, "null", .null)
        #expect(null.text == nil)
        #expect(null.bytes == nil)
        #expect(null.type == "null")
        await store.close()
    }

    @Test("a blob keeps its zero bytes, and an empty blob is a blob")
    func blobs() async throws {
        let store = try await probe()
        let stored = try await roundTrip(store, "blob", .blob([0, 255, 0, 1, 0]), asText: false)
        #expect(stored.bytes == [0, 255, 0, 1, 0])
        #expect(stored.type == "blob")
        let empty = try await roundTrip(store, "empty-blob", .blob([]), asText: false)
        #expect(empty.bytes == [])
        #expect(empty.type == "blob")
        await store.close()
    }

    @Test("a statement bound with fewer or more values than it asks for is a contract error, not a NULL")
    func cardinality() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let fewer = await storeError {
            _ = try await store.write { transaction in
                try transaction.query("SELECT ?1, ?2", [.integer(7)]) { ($0.integer(0), $0.integer(1)) }
            }
        }
        guard case .contract(let fewerFault)? = fewer else {
            Issue.record("a missing argument was accepted: \(String(describing: fewer))")
            return
        }
        #expect(fewerFault.code.primary == 25)
        let more = await storeError {
            _ = try await store.write { transaction in
                try transaction.query("SELECT ?1", [.integer(7), .integer(8)]) { $0.integer(0) }
            }
        }
        guard case .contract(let moreFault)? = more else {
            Issue.record("an extra argument was accepted: \(String(describing: more))")
            return
        }
        #expect(moreFault.code.primary == 25)
        let explicit = try await store.write { transaction in
            try transaction.query("SELECT ?1, ?2, typeof(?2)", [.integer(7), .null]) { ($0.integer(0), $0.integer(1), try $0.text(2)) }.first
        }
        #expect(explicit?.0 == 7)
        #expect(explicit?.1 == nil)
        #expect(explicit?.2 == "null")
        await store.close()
    }

    @Test("a text longer than the connection's length limit is refused whole, never cut")
    func lengthLimit() throws {
        let connection = try SQLiteConnection(path: try temporaryDatabase().path)
        try connection.execute("CREATE TABLE t (v TEXT)")
        let before = connection.limit(.length, to: 64)
        #expect(before > 64)
        #expect(connection.limit(.length) == 64)
        // The limit bounds the whole row, header included: 32 bytes fit under 64, 65 cannot.
        try connection.run("INSERT INTO t VALUES (?)", [.text(String(repeating: "x", count: 32))])
        let failure = #expect(throws: SQLiteConnection.Failure.self) {
            try connection.run("INSERT INTO t VALUES (?)", [.text(String(repeating: "y", count: 65))])
        }
        #expect(failure?.primary == 18)
        if let failure {
            guard case .contract(let fault) = MemoryStoreError(failure, phase: .statement) else {
                Issue.record("expected .contract")
                return
            }
            #expect(fault.code.primary == 18)
        }
        let stored = try connection.query("SELECT length(v) FROM t") { $0.integer(0) }
        #expect(stored == [32])
        connection.close()
    }

    @Test("a repeated placeholder takes one value, and a statement without placeholders takes none")
    func placeholders() async throws {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        let repeated = try await store.write { transaction in
            try transaction.query("SELECT ?1 + ?1, ?1 || ?1", [.integer(21)]) { ($0.integer(0), try $0.text(1)) }.first
        }
        #expect(repeated?.0 == 42)
        #expect(repeated?.1 == "2121")
        let plain = try await store.write { transaction in
            try transaction.execute("CREATE TEMP TABLE plain (x INTEGER)")
            try transaction.execute("INSERT INTO plain VALUES (1), (2)")
            return try transaction.query("SELECT count(*) FROM plain") { $0.integer(0) }.first
        }
        #expect(plain == 2)
        await store.close()
    }
}
