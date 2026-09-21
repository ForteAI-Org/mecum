//
//  WindowInventoryProbeIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Foundation

/// FixtureWindowToken names an `NSWindow` this probe's fixture created itself.
///
/// It is bookkeeping for ownership and cleanup, and it is deliberately not a
/// `WindowReference`, not a `ProcessIdentity` and not an attested identity of
/// any kind: holding one says the fixture asked AppKit for an object, nothing
/// about what the window server holds. It is kept apart from the Window ID and
/// PID later *observed* in a CoreGraphics row precisely because the two can
/// disagree, and a token that quietly became an identity would turn the probe
/// into the oracle it is built to avoid.
struct FixtureWindowToken: Hashable, Codable {

    let identifier   : UUID
    let role         : FixtureWindowRole

    /// The order the fixture created its windows in, so a report stays readable
    /// when the identifiers are not.
    let creationOrder: Int
}

/// ObservedWindowIdentity is a Window ID and owner PID as one reading carried
/// them. It is an observation with a lifetime of that reading only.
///
/// Nothing here authorizes anything. The window server hands a Window ID out
/// again after the window behind it is gone, a PID is reused after its process
/// terminates, absence from a reading is not a closure, and a failed reading is
/// not an absence. This type therefore never converts into an attested identity
/// and the probe never fabricates one from it.
struct ObservedWindowIdentity: Hashable, Codable {

    let windowID : Int
    let processID: Int
}
