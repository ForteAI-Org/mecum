//
//  InventoryReading.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// InventoryReadingScope is which of the two lists a reading asked for.
///
/// `all` includes surfaces that were never shown, which is the whole reason the
/// probe reads both: a window missing from `onScreenOnly` and present in `all`
/// is a difference between two lists and not a window that closed.
enum InventoryReadingScope: String, Codable, Equatable {

    case all
    case onScreenOnly
}

/// InventoryReading is one call to the window list API: which list was asked
/// for, with which options, when it started and ended on a monotonic clock, and
/// what came back.
///
/// The provenance is stored rather than assumed because the option bits are the
/// difference between the two readings, and a report that only said "all" could
/// not be checked against the call that produced it. The interval is monotonic
/// nanoseconds, kept as start and end rather than a duration so an overlapping
/// or reordered pair stays visible.
struct InventoryReading: Codable, Equatable {

    let scope             : InventoryReadingScope
    let apiName           : String
    let optionBits        : UInt32
    let relativeToWindowID: UInt32
    let startedAtNanoseconds: UInt64
    let endedAtNanoseconds  : UInt64
    let outcome             : InventoryReadingOutcome

    /// Zero when the clock did not move between the two samples, which a
    /// diagnostic reader should treat as resolution and not as an instant call.
    var elapsedNanoseconds: UInt64 {
        endedAtNanoseconds >= startedAtNanoseconds
            ? endedAtNanoseconds &- startedAtNanoseconds
            : 0
    }

    /// True when the API answered a list at all, in any shape. It is not a claim
    /// that the list is complete, and it is not used to decide anything.
    var hasList: Bool {
        if case .received = outcome { return true }
        return false
    }
}
