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
/// before it is used. It fails closed: a build outside the Ledger is
/// `unvalidated` and refuses to act unless the consumer opted in for that
/// Facility, and a failed self check is `unavailable` even when the Ledger is
/// favourable, because the running system wins over the record.
public enum FacilityReadiness: Sendable, Equatable {

    /// The Ledger validates this build and every self check agreed.
    case validated(build: String)

    /// The self checks passed but the Ledger does not cover this build, or
    /// covers the build and not this hardware model. Refused unless the
    /// consumer allows unvalidated builds for this Facility, and marked on
    /// every Receipt and event when it does.
    case unvalidated(UnvalidatedScope)

    /// The Facility cannot work on this system: a symbol is missing, a record
    /// layout does not round trip, a self check failed.
    case unavailable(reason: String)

    /// A permission is missing. Distinct from `unavailable`: nothing is broken,
    /// the person has simply not granted it yet.
    case permissionMissing(kind: PermissionKind)

    /// True only when the Facility may act without an explicit opt in.
    public var allowsUse: Bool {
        if case .validated = self { return true }
        return false
    }
}
