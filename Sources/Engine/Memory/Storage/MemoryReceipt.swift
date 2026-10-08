//
//  MemoryReceipt.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemoryReceipt is the answer to a write that reached the store: the change is on disk, or it
/// already was. A receipt is given only after the transaction committed. A change that could not
/// be written is a `MemoryStoreError`, never a receipt, and there is no receipt for a change that
/// is merely waiting somewhere in memory.
public enum MemoryReceipt: Sendable, Equatable {

    /// The transaction committed. A read that begins after this sees the change.
    case committed

    /// A fact with the same identity and the same content was already stored. Nothing changed
    /// and no count moved.
    case alreadyApplied
}
