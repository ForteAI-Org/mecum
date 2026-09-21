//
//  InventoryReadingPair.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// InventoryReadingPair is one sample: an all-windows reading and an on-screen
/// reading taken one after the other, with the run and sample they belong to.
///
/// The two readings are sequential and the pair is **not** atomic. The window
/// server may change between them, a phase of the fixture may take effect
/// between them, and nothing here claims otherwise. A difference between the two
/// members is therefore a difference between two instants of two different
/// lists, never proof that a window appeared, vanished or was closed.
struct InventoryReadingPair: Codable, Equatable {

    /// The run this sample belongs to, so samples from two runs never merge.
    let runID      : String
    let sampleIndex: Int

    /// The plan phase this sample was taken after, or nil when the sample was
    /// taken outside the plan.
    let phaseIndex : Int?

    let all     : InventoryReading
    let onScreen: InventoryReading

    /// Stated in the report next to every pair, so no reader has to infer it.
    var atomicityNote: String {
        "the two readings are sequential; the pair is not atomic and neither "
            + "member attests the completeness of the inventory"
    }

    /// Window IDs of the fixture that this pair saw in `all` and not in
    /// `onScreen`. Descriptive only: it is a disagreement between two lists and
    /// it establishes nothing about visibility, ownership or closure.
    var fixtureWindowIDsOnlyInAll: [Int] {
        let onScreenIDs = Set(Self.fixtureWindowIDs(of: onScreen))
        return Self.fixtureWindowIDs(of: all).filter { !onScreenIDs.contains($0) }
    }

    static func fixtureWindowIDs(of reading: InventoryReading) -> [Int] {
        guard case .received(let digest) = reading.outcome else { return [] }
        return digest.fixtureRows.map(\.observed.windowID)
    }
}
