//
//  InventoryRowsDigest.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// InventoryRowsDigest is one window list after parsing: how many rows arrived,
/// what the fixture's own rows carried, how many rows belonged to somebody else,
/// and what was rejected and why.
///
/// A digest with `rowCount == 0` means the list was answered and carried nothing.
/// That is a different fact from a list that was never answered, which is why the
/// absent case lives in `InventoryReadingOutcome` and not in a count here. The
/// digest is not a claim of completeness: `CGWindowListCopyWindowInfo` describes
/// what it was willing to report at that instant and nothing more.
struct InventoryRowsDigest: Codable, Equatable {

    /// Rows the API answered with, before any judgement about them.
    let rowCount: Int

    /// The fixture's own windows, raw and unredacted, since the probe owns them.
    let fixtureRows: [FixtureWindowRow]

    /// Rows of windows this probe does not own. Counted only: their identities,
    /// titles and dictionaries are none of the probe's business.
    let foreignRowCount: Int

    /// Rows that were rejected, by reason.
    let discards: [InventoryDiscardTally]

    /// Attributes that were absent from rows the parser kept, counted by
    /// reason. Kept apart from `discards` so a gap is never read as a rejection,
    /// and counted per attribute, since one row may lack several.
    let gaps: [InventoryDiscardTally]

    var rejectedRowCount: Int { discards.reduce(0) { $0 + $1.count } }
}

/// InventoryReadingOutcome is what one reading produced, with the four answers
/// kept apart on purpose.
///
/// `nil`, an empty list and a list with rejected rows are three different
/// findings, and a conversion failure is a fourth. None of them is evidence that
/// a window was closed, and none of them is evidence that the inventory was
/// complete.
enum InventoryReadingOutcome: Codable, Equatable {

    /// The API answered a list, which was then parsed.
    case received(InventoryRowsDigest)

    /// The API answered `nil`. Nothing follows from this about any window.
    case absentList(String)

    /// The answer arrived and could not be converted into rows. It is recorded
    /// as a failure and never flattened into an empty list.
    case failed(String)

    /// The reading was not performed, or not available in this run.
    case unavailable(String)
}
