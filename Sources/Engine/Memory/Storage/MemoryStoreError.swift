//
//  MemoryStoreError.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemoryStoreError is what a memory store answers when a write or a read did not do what was
/// asked, sorted by the next action a caller can take. Contention is not a failure, a failure is
/// not an empty archive, and a refused schema is neither: the cases keep those apart on purpose.
/// Each carries the library's primary and extended result code and the phase it was met in,
/// never a value the agent typed or read.
///
/// The pure module owns the taxonomy so a composition root can decide continuity without
/// importing a driver; the adapter that speaks SQLite fills it.
public enum MemoryStoreError: Error, Sendable, Equatable {

    /// The file could not be opened or is not a readable archive: a missing or unwritable
    /// directory, a file that is not a database, a journal mode the file refused. Nothing was
    /// created in its place and nothing in the file was changed.
    case open(MemoryStoreFault)

    /// The archive opened but its schema is not one this build can use. No reset, no downgrade.
    case schema(MemorySchemaMismatch)

    /// A write violated a constraint or a trigger of the schema, or misused the store. The
    /// transaction rolled back and the same statements must not be retried as they are.
    case contract(MemoryStoreFault)

    /// A fact with the same identity is already stored with different content. The stored one
    /// stays; nothing was written.
    case identity(MemoryIdentityConflict)

    /// A stored text is not valid UTF-8, so it was not decoded: no replacement character, no
    /// empty text, no NULL in its place. The bytes stay readable as bytes; the transaction they
    /// were read in ended. The fault says where, never what.
    case malformedText(MemoryTextFault)

    /// Another connection or process held the lock past the caller's budget. Nothing was written,
    /// and the same change may be offered again with the same identifiers: prolonged waiting, not
    /// a failure of the device or of the file.
    case contention(MemoryStoreFault, attempts: Int, waited: Duration)

    /// A conflict inside this connection, such as a statement left open on the table being
    /// changed. A store defect, not contention, so it is not waited on like one.
    case locked(MemoryStoreFault)

    /// The device or the file failed: full disk, I/O error, read-only file, corruption found after
    /// opening. The fault says whether the transaction was ended cleanly (`cleanup`); when it was,
    /// the store goes on and the caller decides about the fact whose outcome is now known to be
    /// "not written". When it was not, the store has let go of its connections and answers
    /// `unavailable(.failed)` until it is closed and a new instance is opened on the same path.
    case failed(MemoryStoreFault)

    /// A snapshot was refused before or after the copy, for a reason of the destination or of the
    /// copy itself. The store's own file is untouched, and no partial copy is left behind.
    case snapshot(MemorySnapshotRefusal)

    /// The store cannot be used at all: never opened, closed, or missing what it needs to open.
    case unavailable(Unavailability)

    /// The caller's task was cancelled while the store was waiting for a lock or between the steps
    /// of a snapshot. Nothing was written and no partial copy is left behind.
    case cancelled(Phase)

    /// Phase names the step of an operation an error was met in.
    public enum Phase: String, Sendable, Equatable, CaseIterable {
        case open, bootstrap, begin, statement, commit, checkpoint, snapshot, close
    }

    /// Unavailability says why the store cannot be used at all, before any file was touched.
    public enum Unavailability: Sendable, Equatable {

        /// `open` was never called.
        case notOpened

        /// `close` was called; a change that was waiting for a lock finds this after its wait.
        case closed

        /// The linked library is older than the schema requires.
        case library(found: String, required: String)

        /// The schema resource is not in the module's bundle: a packaging defect, not a file problem.
        case resourceMissing(String)

        /// The waiting policy would let the store retry without pausing; the message names the
        /// rule it broke. Nothing was opened.
        case misconfigured(String)

        /// A failure left a connection in a state the store could not end cleanly, so it let go of
        /// both connections. The fault is the one that was answered then. Close this instance and
        /// open a new one on the same path once the cause is removed: no reset, no other file.
        case failed(MemoryStoreFault)

        /// A recovery of the archive began and did not finish: its record is beside the archive, and
        /// no store opens the archive, nor makes an empty one, until a recovery completes it from that
        /// record. Also the answer of a recovery that cannot complete it. The sentence says what the
        /// record holds or why the recovery stopped; every file is kept.
        case interruptedRecovery(String)
    }
}
