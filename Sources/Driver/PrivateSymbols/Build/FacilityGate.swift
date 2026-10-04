//
//  FacilityGate.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import SeatCore

/// FacilityGate is the derivation of section 6 of the spec: what one Facility
/// is allowed to do on the machine it woke up on. It answers three things at
/// once, because a caller that only knows the readiness does not know whether
/// it may act, and a caller that only knows it may act cannot mark its
/// Receipts.
///
/// The order of the rules is the whole design and it is deliberate:
///
/// 1. **A failed self check wins over everything.** The running system beats the
///    Ledger, so a missing symbol or a moved offset is `unavailable` even on a
///    build the Ledger blesses. Ledger coverage never lifts it.
/// 2. **Then the permission.** It is checked after the self checks because a
///    grant cannot repair a missing primitive, and reporting
///    `permissionMissing` for a Facility that could not work anyway sends the
///    person to System Settings for nothing. None of the self checks needs a
///    grant to run, so the order costs nothing.
/// 3. **Then the Ledger**, build first and hardware second.
nonisolated public struct FacilityGate: Sendable, Equatable {

    /// What the Facility answers about this system.
    public let readiness: FacilityReadiness

    /// Whether the Facility may act. Ledger coverage is evidence, not a gate.
    /// Missing permissions and failed runtime self checks still refuse.
    public let mayAct: Bool

    /// Whether every Receipt and event of this Facility must carry
    /// `unvalidatedBuild: true`. True whenever the Ledger does not cover this
    /// system, because the mark describes the evidence and not the permission.
    public let unvalidatedBuild: Bool

    init(
        readiness       : FacilityReadiness,
        mayAct          : Bool,
        unvalidatedBuild: Bool
    ) {
        self.readiness        = readiness
        self.mayAct           = mayAct
        self.unvalidatedBuild = unvalidatedBuild
    }

    /// The derivation, with the self checks and the permission already run.
    /// This is the whole rule and it touches nothing: it is the form the truth
    /// table is written against, so a Facility that does not exist can be gated
    /// in a unit test.
    ///
    /// - Parameters:
    ///   - selfCheckFailure: the reason steps 1 to 3 failed, `nil` when they
    ///     passed. Steps 4 and beyond (effect) never run at runtime.
    ///   - missingPermission: the grant the Facility needs and does not have.
    ///   - allowUnvalidatedBuild: retained for source compatibility. Unvalidated
    ///     systems may act regardless of this value after runtime checks pass.
    public static func evaluate(
        facility             : Facility,
        build                : BuildIdentity,
        ledger               : Ledger,
        selfCheckFailure     : String?,
        missingPermission    : PermissionKind?,
        allowUnvalidatedBuild: Bool = false
    ) -> FacilityGate {
        
        if let selfCheckFailure {
            return FacilityGate(
                readiness       : .unavailable(reason: selfCheckFailure),
                mayAct          : false,
                unvalidatedBuild: false
            )
        }
        
        if let missingPermission {
            return FacilityGate(
                readiness       : .permissionMissing(kind: missingPermission),
                mayAct          : false,
                unvalidatedBuild: false
            )
        }

        func unvalidated(_ scope: UnvalidatedScope) -> FacilityGate {
            FacilityGate(
                readiness       : .unvalidated(scope),
                mayAct          : true,
                unvalidatedBuild: true
            )
        }

        guard let entry = ledger.entry(for: build) else {
            return unvalidated(.build(build.osVersion))
        }
        guard entry.hardware.contains(build.hardwareModel) else {
            return unvalidated(.hardware(build: build.osVersion, model: build.hardwareModel))
        }

        return switch ledger.verdict(for: facility, in: entry) {
            case .validated:
                FacilityGate(
                    readiness       : .validated(build: build.osVersion),
                    mayAct          : true,
                    unvalidatedBuild: false
                )
                
            case .limited:
                unvalidated(
                    .hardware(build: build.osVersion, model: build.hardwareModel)
                )
        
            case .unvalidated: unvalidated(.build(build.osVersion))
        }
    }

    /// The runtime entry point: runs steps 1 to 3 against the running system,
    /// reads the bundled Ledger, preflights the grants, and derives. A Ledger
    /// that cannot be read is `unavailable` and not an empty Ledger, because an
    /// empty Ledger would conceal a damaged resource as missing qualification.
    public static func current(
        facility             : Facility,
        allowUnvalidatedBuild: Bool = false,
        build                : BuildIdentity = .current,
        table                : SymbolTable = .shared
    ) -> FacilityGate {
        let ledger: Ledger
        do {
            ledger = try Ledger.bundled()
        } catch {
            return FacilityGate(
                readiness       : .unavailable(reason: "\(error)"),
                mayAct          : false,
                unvalidatedBuild: false
            )
        }
        return evaluate(
            facility             : facility,
            build                : build,
            ledger               : ledger,
            selfCheckFailure     : selfCheckFailure(for: facility, table: table),
            missingPermission    : Permissions.firstMissing(for: facility),
            allowUnvalidatedBuild: allowUnvalidatedBuild
        )
    }

    /// Retained for source compatibility with research consumers. Unvalidated
    /// systems no longer need this flag; runtime failures still refuse.
    nonisolated(unsafe) public static var researchOptInForUnvalidatedBuilds = false

    /// Steps 1 to 3 of the compatibility suite, the ones cheap enough to run
    /// every time a Facility starts: resolution, then the record's declared
    /// length and offset round trip for the Facilities that touch a record.
    public static func selfCheckFailure(
        for facility: Facility,
        table       : SymbolTable = .shared
    ) -> String? {
        if let missing = table.firstUnresolved(of: facility.requirements) {
            return "unresolved primitive: \(missing)"
        }
        guard facility.requirements.contains(.symbol(.eventRecordPointer)) else { return nil }
        return RecordLayout.crossValidate(using: table).failureReason
    }
}
