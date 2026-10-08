//
//  SQLiteTransaction.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// SQLiteTransaction is the writer's handle inside one `BEGIN IMMEDIATE ... COMMIT`, lent to a write
/// body for the length of that call. Every statement is prepared, bound by value and finalized
/// inside the call that runs it, so no cursor survives the body. A body may run more than once:
/// when the lock was busy the transaction was rolled back and is attempted again, so a body derives
/// everything it writes from its inputs and from rows it reads inside the transaction, never from
/// state it kept between attempts.
///
/// Package-visible, not public: the typed repositories and the module's own test helper are its
/// consumers. No SQL crosses the package's boundary.
package struct SQLiteTransaction {

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    /// Runs one statement to completion and answers the rows it changed.
    @discardableResult
    package func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try connection.run(sql, bindings)
    }

    /// Runs one query and maps every row inside the call.
    package func query<T>(
        _ sql     : String,
        _ bindings: [SQLiteValue] = [],
        _ row     : (SQLiteStatement.Row) throws -> T
    ) throws -> [T] {
        try connection.query(sql, bindings, row)
    }
}

/// SQLiteSnapshot is the reader's handle inside one deferred read transaction: the committed state
/// as of its first statement, held only while the read body runs. It has no way to write.
package struct SQLiteSnapshot {

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    /// Runs one query and maps every row inside the call.
    package func query<T>(
        _ sql     : String,
        _ bindings: [SQLiteValue] = [],
        _ row     : (SQLiteStatement.Row) throws -> T
    ) throws -> [T] {
        try connection.query(sql, bindings, row)
    }
}
