//
//  PrimitiveState.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// PrimitiveKind is the `kind` column of the Ledger. It exists so that a row
/// can be checked against what the Facility asked for: a symbol that turns into
/// a behaviour between two builds is a rewrite, not a state change.
nonisolated public enum PrimitiveKind: String, Sendable, Codable {
    case symbol
    case objcClass = "class"
    case selector
    case field
    case record
    case behavior
}

/// PrimitiveState is three-valued on purpose. A boolean collapses "the check
/// failed" and "the check could not run", and klyk's own tri-state exists
/// because treating them alike shuts the library down for the wrong reason.
///
/// `verified` means every applicable step of the compatibility suite passed;
/// `limited` means it passed on some hardware and not on all of it; `untested`
/// means nobody ran it. Anything else in the file is a parse error, never a
/// value quietly ignored.
nonisolated public enum PrimitiveState: String, Sendable, Codable {
    case verified
    case limited
    case untested
}
