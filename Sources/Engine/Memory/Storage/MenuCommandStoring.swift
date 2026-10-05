//
//  MenuCommandStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

/// MenuCommandStoring keeps the menu commands an enumeration found, as data: it runs no command,
/// merges nothing by path and chooses no command for a query. A conformer writes a command and its
/// ordered path together or not at all, and answers after the commit.
///
/// `record` is the write a producer may offer again: the same id with the same content is
/// `alreadyApplied`; other content under the id, another application included, is
/// `MemoryStoreError.identity` with nothing written. `update` is the deliberate change of what was
/// observed since, against the record the caller last read: the stored record must be that one,
/// else `MenuCommandError.staleExpectation` and nothing written, so no writer loses another's
/// update or brings older data back. Nothing deletes a command, so every reference to it stays valid.
public protocol MenuCommandStoring: Sendable {

    /// Records a command and its path, once by its id.
    func record(_ command: MenuCommandRecord) async throws -> MemoryReceipt

    /// Replaces the observed fields of the stored `expected` with `updated`'s: the title, the
    /// identifier, the submenu and enabled flags, the mark and the shortcut, and a last sighting no
    /// earlier than the stored one. The id, the application, the path and the first sighting stay.
    /// The stored record already equal to `updated` is `alreadyApplied`, the retry of this update.
    func update(from expected: MenuCommandRecord, to updated: MenuCommandRecord) async throws -> MemoryReceipt

    /// The stored command, or nil.
    func menuCommand(_ menuCommandID: String) async throws -> MenuCommandRecord?

    /// The commands of an application, those whose `pathKey` is the hint given when there is one,
    /// ordered by path (segment by segment, as UTF-8 bytes) and then by id.
    func menuCommands(of bundleID: String, pathKey: String?) async throws -> [MenuCommandRecord]
}
