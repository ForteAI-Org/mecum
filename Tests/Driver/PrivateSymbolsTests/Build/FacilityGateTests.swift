//
//  FacilityGateTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
@testable import PrivateSymbols
@testable import SeatCore
import Testing

/// The truth table of section 6, written against a Facility that does not
/// exist. A table written against `input` would prove the input wiring; this
/// one proves the rule, which is the thing that must not drift when a Facility
/// is added.
@Suite("Facility readiness truth table")
struct FacilityGateTests {

    static let fictitious = Facility(
        name        : "fictitious",
        requirements: [.symbol(.mainConnectionID)],
        permissions : [.postEvent]
    )

    static let build = BuildIdentity(
        osVersion     : "26A5425a",
        productVersion: "27.0",
        hardwareModel : "Mac16,1"
    )

    /// A build that no Ledger entry covers.
    static let unknownBuild = BuildIdentity(
        osVersion     : "27B99z",
        productVersion: "27.1",
        hardwareModel : "Mac16,1"
    )

    /// The Ledger's build, on a Mac nobody has validated.
    static let unknownHardware = BuildIdentity(
        osVersion     : "26A5425a",
        productVersion: "27.0",
        hardwareModel : "Mac99,9"
    )

    static func ledger(state: String = "verified") throws -> Ledger {
        let json = """
        {
          "schema_version": 1,
          "builds": {
            "26A5425a": {
              "productVersion": "27.0",
              "hardware": ["Mac16,1"],
              "validatedAt": "2026-09-08T00:00:00Z",
              "validatedBy": "test",
              "primitives": {
                "SLSMainConnectionID": {
                  "kind": "symbol", "state": "\(state)",
                  "checks": { "resolves": true }
                }
              }
            }
          }
        }
        """
        guard let data = json.data(using: .utf8) else {
            throw SystemFailure.ledgerUnreadable(reason: "test JSON is not UTF-8")
        }
        return try Ledger(data: data)
    }

    static func gate(
        inLedger    : Bool,
        selfCheckOK : Bool,
        permissionOK: Bool,
        allow       : Bool
    ) throws -> FacilityGate {
        FacilityGate.evaluate(
            facility             : fictitious,
            build                : inLedger ? build : unknownBuild,
            ledger               : try ledger(),
            selfCheckFailure     : selfCheckOK ? nil : "unresolved primitive: SLSMainConnectionID",
            missingPermission    : permissionOK ? nil : .postEvent,
            allowUnvalidatedBuild: allow
        )
    }

    /// Sixteen rows: Ledger yes/no, self checks yes/no, permission yes/no, opt
    /// in yes/no. The expectations are written out rather than computed,
    /// because a table that recomputes the rule proves nothing.
    @Test(
        "the whole table",
        arguments: [
            // ledger, selfCheck, permission, allow, readiness, mayAct, mark
            (true,  true,  true,  false, "validated",         true,  false),
            (true,  true,  true,  true,  "validated",         true,  false),
            (true,  true,  false, false, "permissionMissing",  false, false),
            (true,  true,  false, true,  "permissionMissing",  false, false),
            (true,  false, true,  false, "unavailable",        false, false),
            (true,  false, true,  true,  "unavailable",        false, false),
            (true,  false, false, false, "unavailable",        false, false),
            (true,  false, false, true,  "unavailable",        false, false),
            (false, true,  true,  false, "unvalidatedBuild",   false, true),
            (false, true,  true,  true,  "unvalidatedBuild",   true,  true),
            (false, true,  false, false, "permissionMissing",  false, false),
            (false, true,  false, true,  "permissionMissing",  false, false),
            (false, false, true,  false, "unavailable",        false, false),
            (false, false, true,  true,  "unavailable",        false, false),
            (false, false, false, false, "unavailable",        false, false),
            (false, false, false, true,  "unavailable",        false, false),
        ]
    )
    func table(
        inLedger    : Bool,
        selfCheckOK : Bool,
        permissionOK: Bool,
        allow       : Bool,
        expected    : String,
        mayAct      : Bool,
        mark        : Bool
    ) throws {
        let gate = try Self.gate(
            inLedger    : inLedger,
            selfCheckOK : selfCheckOK,
            permissionOK: permissionOK,
            allow       : allow
        )
        #expect(Self.label(of: gate.readiness) == expected)
        #expect(gate.mayAct           == mayAct)
        #expect(gate.unvalidatedBuild == mark)
    }

    static func label(of readiness: FacilityReadiness) -> String {
        switch readiness {
        case .validated:                    "validated"
        case .unvalidated(.build):          "unvalidatedBuild"
        case .unvalidated(.hardware):       "unvalidatedHardware"
        case .unavailable:                  "unavailable"
        case .permissionMissing:            "permissionMissing"
        }
    }

    @Test("a failed self check keeps its reason, and the opt in never lifts it")
    func selfCheckReasonSurvives() throws {
        let gate = try Self.gate(inLedger: true, selfCheckOK: false, permissionOK: true, allow: true)
        #expect(gate.readiness == .unavailable(reason: "unresolved primitive: SLSMainConnectionID"))
        #expect(!gate.mayAct)
    }

    @Test("a known build on an unknown Mac is unvalidated hardware, not unvalidated build")
    func unknownHardwareScope() throws {
        let gate = FacilityGate.evaluate(
            facility             : Self.fictitious,
            build                : Self.unknownHardware,
            ledger               : try Self.ledger(),
            selfCheckFailure     : nil,
            missingPermission    : nil,
            allowUnvalidatedBuild: false
        )
        #expect(gate.readiness == .unvalidated(.hardware(build: "26A5425a", model: "Mac99,9")))
        #expect(gate.unvalidatedBuild)
        #expect(!gate.mayAct)
    }

    @Test("the opt in lets an unvalidated Mac act, still marked")
    func unknownHardwareOptIn() throws {
        let gate = FacilityGate.evaluate(
            facility             : Self.fictitious,
            build                : Self.unknownHardware,
            ledger               : try Self.ledger(),
            selfCheckFailure     : nil,
            missingPermission    : nil,
            allowUnvalidatedBuild: true
        )
        #expect(gate.mayAct)
        #expect(gate.unvalidatedBuild)
    }

    @Test("a limited primitive keeps the Facility out of validated")
    func limitedVerdict() throws {
        let gate = FacilityGate.evaluate(
            facility             : Self.fictitious,
            build                : Self.build,
            ledger               : try Self.ledger(state: "limited"),
            selfCheckFailure     : nil,
            missingPermission    : nil,
            allowUnvalidatedBuild: false
        )
        #expect(gate.readiness == .unvalidated(.hardware(build: "26A5425a", model: "Mac16,1")))
        #expect(!gate.mayAct)
    }

    @Test("an untested primitive is unvalidated on the build's own key")
    func untestedVerdict() throws {
        let gate = FacilityGate.evaluate(
            facility             : Self.fictitious,
            build                : Self.build,
            ledger               : try Self.ledger(state: "untested"),
            selfCheckFailure     : nil,
            missingPermission    : nil,
            allowUnvalidatedBuild: false
        )
        #expect(gate.readiness == .unvalidated(.build("26A5425a")))
    }

    @Test("only validated allows use without an opt in")
    func allowsUse() throws {
        let validated = try Self.gate(inLedger: true, selfCheckOK: true, permissionOK: true, allow: false)
        #expect(validated.readiness.allowsUse)
        let unvalidated = try Self.gate(inLedger: false, selfCheckOK: true, permissionOK: true, allow: true)
        #expect(!unvalidated.readiness.allowsUse)
        #expect(unvalidated.mayAct)
    }

    @Test("the unvalidated scope always names the build it is about")
    func scopeCarriesBuild() {
        #expect(UnvalidatedScope.build("26A5425a").build == "26A5425a")
        #expect(UnvalidatedScope.hardware(build: "26A5425a", model: "Mac99,9").build == "26A5425a")
    }
}
