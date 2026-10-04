//
//  FacilityReadiness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// PermissionKind is a TCC grant a Facility needs. The kit checks these and
/// reports them; it never prompts on its own, because a prompt the person did
/// not ask for is indistinguishable from a broken app.
public enum PermissionKind: String, Sendable, Equatable {
    case postEvent
    case screenRecording
    case accessibility
}

/// UnvalidatedScope says which half of the build-hardware pair is missing from
/// the Ledger. The distinction is operational, not cosmetic: an unknown build
/// means nobody ran the compatibility suite on this macOS, while a known build
/// on an unknown Mac means the primitives were verified but never on this
/// model, which is the cheaper of the two to promote.
public enum UnvalidatedScope: Sendable, Equatable {

    /// This `kern.osversion` has no Ledger entry at all.
    case build(String)

    /// The build is in the Ledger, this `hw.model` is not in its hardware list.
    case hardware(build: String, model: String)

    /// The build the readiness is about, in both cases.
    public var build: String {
        switch self {
        case .build(let build):              build
        case .hardware(let build, _):        build
        }
    }
}

/// FacilityReadiness is what one Facility answers about the running system,
/// before it is used. A build outside the Ledger remains `unvalidated` but
/// may act after runtime self checks and permission preflights pass. A failed
/// self check is `unavailable` even when the Ledger is favourable.
public enum FacilityReadiness: Sendable, Equatable {

    /// The Ledger validates this build and every self check agreed.
    case validated(build: String)

    /// The self checks passed but the Ledger does not cover this build, or
    /// covers the build and not this hardware model. Use is allowed and every
    /// Receipt and event keeps the unvalidated mark.
    case unvalidated(UnvalidatedScope)

    /// The Facility cannot work on this system: a symbol is missing, a record
    /// layout does not round trip, a self check failed.
    case unavailable(reason: String)

    /// A permission is missing. Distinct from `unavailable`: nothing is broken,
    /// the person has simply not granted it yet.
    case permissionMissing(kind: PermissionKind)

    /// Whether qualification permits use. Runtime failures remain refusals.
    public var allowsUse: Bool {
        switch self {
            case .validated, .unvalidated: true
            case .unavailable, .permissionMissing: false
        }
    }
}
