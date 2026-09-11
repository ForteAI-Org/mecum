//
//  SystemFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SystemFailure is what the version gate itself can get wrong: a Ledger that
/// cannot be read and a record that does not have the shape the kit was built
/// against. A primitive that fails to resolve is deliberately **not** here: it
/// is a readiness state, and turning it into a thrown error would take down
/// Facilities that never needed it.
///
/// Every case carries the numbers a compatibility report needs, because the
/// consumer writes the sentence and the kit returns the fields.
nonisolated public enum SystemFailure: Error, Sendable, Equatable {

    /// `validated-builds.json` is not in the module bundle. A build error, not
    /// a runtime condition.
    case ledgerResourceMissing(name: String)

    /// The Ledger is present and does not decode: unknown `state`, missing
    /// `checks`, malformed JSON. Never softened into an empty Ledger.
    case ledgerUnreadable(reason: String)

    /// The Ledger's schema is not the one this kit reads.
    case ledgerSchemaUnsupported(found: Int, supported: Int)

    /// `SLEventRecordPointer` returned nothing for an event the kit created.
    case eventRecordUnavailable

    /// The record's own declared length at 0x04 is not 0xF8. The only
    /// whole-record oracle the system offers, and the one check none of yabai,
    /// cua or klyk performs.
    case unsupportedRecordLength(declared: UInt32, expected: UInt32)

    /// A write or read was asked for outside the record. The audited exception
    /// to "no unsafe unwraps" is the record path, and this is the bound that
    /// makes it auditable.
    case recordOffsetOutOfBounds(offset: Int, width: Int, length: Int)

    /// A round trip through a setter did not come back: the offset moved, and
    /// the Facility must refuse rather than write into the wrong byte.
    case recordOffsetMismatch(offset: Int, wrote: String, read: String)
}
