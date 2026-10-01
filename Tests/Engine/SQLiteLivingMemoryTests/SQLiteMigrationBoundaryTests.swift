import Foundation
import SQLite3
import Testing
@testable import SQLiteLivingMemory

struct SQLiteMigrationBoundaryTests {
    @Test func migrationRechecksAnUpgradeThatWonTheWriteLock() throws {
        let file = URL.temporaryDirectory.appending(path: "mecum-schema-race-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try connection.execute("PRAGMA application_id = \(SQLiteLivingMemorySchema.applicationID); PRAGMA user_version = 99;")
        #expect(throws: SQLiteLivingMemoryError.unsupportedSchemaVersion(path: file.path, found: 99, supported: 2)) {
            try SQLiteLivingMemoryStore.migrate(connection, schema: .current)
        }
        #expect(try connection.integer("PRAGMA user_version") == 99)
        #expect(try connection.integer("SELECT count(*) FROM sqlite_master") == 0)
    }
}
