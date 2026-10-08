//
//  MemorySnapshotRefusal.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemorySnapshotRefusal says why a snapshot answered no copy. The first three are decided before
/// any file is touched; the rest are found on the finished copy, which is then removed rather
/// than handed over. The store's own file is never changed by a snapshot.
public enum MemorySnapshotRefusal: Sendable, Equatable {

    /// The destination is the store's own file, or one of its journal files.
    case destinationIsTheSource

    /// Something already exists at the destination. Nothing is overwritten, silently or otherwise.
    case destinationExists

    /// The copy could not be created where asked: the directory is missing or not writable. The
    /// fault is the library's answer for the destination, not for the store's file.
    case destinationUnavailable(MemoryStoreFault)

    /// The copy's integrity check answered these lines instead of `ok`.
    case copyFailedIntegrityCheck([String])

    /// The copy's foreign key check found this many violations.
    case copyHasForeignKeyViolations(Int)

    /// The copy does not carry the schema the store recognises.
    case copySchema(MemorySchemaMismatch)
}
