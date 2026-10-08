//
//  SQLiteMemoryPresence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
import SQLite3

/// SQLiteMemoryPresence is an archive's presence lock: `flock(2)` on a file beside the archive,
/// `<archive>.lock`, made on first use and never moved or deleted. Whoever holds the archive's
/// files open takes it shared, before the first connection and until the last one closed: a store,
/// with the connections of its copies, and a diagnosis. A recovery takes it exclusive and never
/// waits for it: the recovery is refused while anybody holds it shared, and nobody takes it shared
/// while a recovery holds it. So no connection is open on the files a recovery moves, and none
/// opens on them until it has finished.
///
/// The lock belongs to the open file, not to the process: two presences in one process exclude each
/// other as two processes do. The kernel lets go of the lock of a process that ended, so a crash
/// leaves none behind. It coordinates only the code that takes it: a build without it, or a tool that
/// opens the archive itself (`sqlite3`), is not coordinated, and `flock` is not reliable on a network
/// volume.
final class SQLiteMemoryPresence {

    enum Mode {
        case shared, exclusive
    }

    let path: String
    let mode: Mode
    private var descriptor: Int32

    private init(path: String, mode: Mode, descriptor: Int32) {
        self.path       = path
        self.mode       = mode
        self.descriptor = descriptor
    }

    deinit { release() }

    /// The lock file of the archive at the URL.
    static func lockPath(of archive: URL) -> String { archive.path + ".lock" }

    /// Takes the archive's lock in the mode without waiting, making the lock file when it is missing.
    /// Nil when another holder's lock excludes this one; throws when the lock file can be neither
    /// opened nor made.
    static func take(_ mode: Mode, of archive: URL) throws -> SQLiteMemoryPresence? {
        let path = lockPath(of: archive)
        var descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        // A directory that may not be written still lets an existing lock file be locked.
        if descriptor < 0 { descriptor = open(path, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw failure("the presence lock \(path) could not be opened") }
        let presence = SQLiteMemoryPresence(path: path, mode: mode, descriptor: descriptor)
        while true {
            if flock(descriptor, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 { return presence }
            let code = errno
            if code == EINTR { continue }
            presence.release()
            if code == EWOULDBLOCK { return nil }
            throw failure("the presence lock \(path) could not be taken", code: code)
        }
    }

    /// Lets go of the lock; a second release is a no-op.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    var isHeld: Bool { descriptor >= 0 }

    /// A lock file that cannot be had is the archive that cannot be opened: `SQLITE_CANTOPEN` at the
    /// open, as the library answers for a directory that is missing or may not be written.
    private static func failure(_ message: String, code: Int32 = errno) -> MemoryStoreError {
        MemoryStoreError(SQLiteConnection.Failure(
            primary : SQLITE_CANTOPEN,
            extended: SQLITE_CANTOPEN,
            message : "\(message): \(String(cString: strerror(code)))"
        ), phase: .open)
    }
}
