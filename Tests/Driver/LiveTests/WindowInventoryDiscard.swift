//
//  WindowInventoryDiscard.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// InventoryDiscardReason is why one row of a window list was rejected, or kept
/// with a gap in it. The reasons are the point of the probe: a parser that
/// answered an empty array for a list it could not read would make a failure and
/// an inventory of zero windows look identical.
enum InventoryDiscardReason: String, Codable, CaseIterable, Equatable {

    /// The element was not a dictionary the reader can address at all.
    case malformedRow

    /// No Window ID or no owner PID, so the row cannot be attributed to anyone.
    case missingIdentity

    /// A value was present with the wrong type, a non finite number or a value
    /// outside the range its field admits.
    case invalidValue

    /// An attribute the probe records was absent. The row is kept and the field
    /// stays absent: it is never defaulted to zero or to false.
    case missingAttribute

    /// The row belongs to this process but to no window the fixture registered,
    /// so it is counted and redacted rather than attributed.
    case unattributableRow

    /// A Window ID the fixture registered came back owned by another PID, which
    /// is a reused Window ID and not the fixture's window.
    case identityMismatch
}

/// InventoryDiscardTally is a reason and how many rows met it. Counters only:
/// no dictionary, title or content of a window outside the fixture is kept.
struct InventoryDiscardTally: Codable, Equatable {

    let reason: InventoryDiscardReason
    let count : Int

    /// A stable, sorted list, so two readings of the same shape compare equal
    /// instead of differing by dictionary order.
    static func tallies(_ counts: [InventoryDiscardReason: Int]) -> [InventoryDiscardTally] {
        counts
            .filter { $0.value > 0 }
            .map { InventoryDiscardTally(reason: $0.key, count: $0.value) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
    }
}
