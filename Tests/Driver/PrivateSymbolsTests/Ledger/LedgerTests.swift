//
//  LedgerTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
@testable import PrivateSymbols
import Testing

/// The Ledger is the only file in the kit whose content is evidence rather than
/// code, so its parser is tested the way a parser of someone else's data is
/// tested: what a good row does, and what every malformed row must refuse to
/// do. A Ledger that reads a row it does not understand is worse than no
/// Ledger, because it answers `validated` on evidence it never saw.
@Suite("Ledger parsing and verdicts")
struct LedgerTests {

    static func ledger(_ json: String) throws -> Ledger {
        guard let data = json.data(using: .utf8) else {
            throw SystemFailure.ledgerUnreadable(reason: "test JSON is not UTF-8")
        }
        return try Ledger(data: data)
    }

    /// One build, one primitive, everything the schema asks for.
    static func oneRow(kind: String = "symbol", state: String = "verified") -> String {
        """
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
                  "kind": "\(kind)", "state": "\(state)",
                  "checks": { "resolves": true },
                  "notes": ""
                }
              }
            }
          }
        }
        """
    }

    static let fictitious = Facility(
        name        : "fictitious",
        requirements: [.symbol(.mainConnectionID)]
    )

    static let build = BuildIdentity(
        osVersion    : "26A5425a",
        productVersion: "27.0",
        hardwareModel: "Mac16,1"
    )

    @Test("a valid entry parses with every field")
    func validEntry() throws {
        let ledger = try Self.ledger(Self.oneRow())
        #expect(ledger.schemaVersion == 1)
        let entry = try #require(ledger.entry(for: Self.build))
        #expect(entry.productVersion == "27.0")
        #expect(entry.hardware == ["Mac16,1"])
        #expect(entry.validatedBy == "test")
        let primitive = try #require(entry.primitives["SLSMainConnectionID"])
        #expect(primitive.kind   == .symbol)
        #expect(primitive.state  == .verified)
        #expect(primitive.checks.resolves == true)
    }

    @Test("the offsets of a record row parse with their setters")
    func offsetsParse() throws {
        let ledger = try Self.ledger(Self.oneRow())
        let bundled = try Ledger.bundled()
        let entry = try #require(bundled.entry(for: Self.build))
        let record = try #require(entry.primitives["SLEventRecordPointer"])
        let offsets = try #require(record.checks.offsets)
        #expect(record.checks.recordLength    == 248)
        #expect(record.checks.allocatedLength == 256)
        #expect(offsets["0x3C"]?.field        == 51)
        #expect(offsets["0x40"]?.field        == 52)
        #expect(offsets["0x20"]?.setter       == "CGEventSetWindowLocation")
        #expect(offsets["0x3C"]?.roundTrip    == true)
        #expect(ledger.schemaVersion == bundled.schemaVersion)
    }

    @Test("an unknown state is refused, never ignored")
    func unknownStateRefused() {
        #expect(throws: SystemFailure.self) {
            try Self.ledger(Self.oneRow(state: "blessed"))
        }
    }

    @Test("an unknown kind is refused")
    func unknownKindRefused() {
        #expect(throws: SystemFailure.self) {
            try Self.ledger(Self.oneRow(kind: "incantation"))
        }
    }

    @Test("a row without checks is refused", arguments: [
        #"{"kind": "symbol", "state": "verified"}"#,
        #"{"kind": "symbol", "checks": {}}"#,
        #"{"state": "verified", "checks": {}}"#,
    ])
    func missingFieldRefused(_ row: String) {
        let json = """
        {
          "schema_version": 1,
          "builds": {
            "26A5425a": {
              "productVersion": "27.0", "hardware": ["Mac16,1"],
              "validatedAt": "x", "validatedBy": "y",
              "primitives": { "SLSMainConnectionID": \(row) }
            }
          }
        }
        """
        #expect(throws: SystemFailure.self) { try Self.ledger(json) }
    }

    @Test("an entry without its hardware list is refused")
    func missingHardwareRefused() {
        let json = """
        {
          "schema_version": 1,
          "builds": {
            "26A5425a": {
              "productVersion": "27.0",
              "validatedAt": "x", "validatedBy": "y", "primitives": {}
            }
          }
        }
        """
        #expect(throws: SystemFailure.self) { try Self.ledger(json) }
    }

    @Test("a newer schema is refused instead of read half right")
    func schemaRefused() throws {
        let json = Self.oneRow().replacingOccurrences(
            of  : "\"schema_version\": 1",
            with: "\"schema_version\": 2"
        )
        #expect(throws: SystemFailure.ledgerSchemaUnsupported(found: 2, supported: 1)) {
            try Self.ledger(json)
        }
    }

    @Test("the verdict is verified, limited or unvalidated, and never read from the file")
    func verdictDerivation() throws {
        let verified  = try Self.ledger(Self.oneRow(state: "verified"))
        let limited   = try Self.ledger(Self.oneRow(state: "limited"))
        let untested  = try Self.ledger(Self.oneRow(state: "untested"))
        let wrongKind = try Self.ledger(Self.oneRow(kind: "behavior"))

        func verdict(_ ledger: Ledger, _ facility: Facility = Self.fictitious) throws -> FacilityVerdict {
            let entry = try #require(ledger.entry(for: Self.build))
            return ledger.verdict(for: facility, in: entry)
        }

        #expect(try verdict(verified) == .validated)
        #expect(try verdict(limited)  == .limited)
        #expect(try verdict(untested) == .unvalidated)

        // The row exists under another kind: it describes something else, so
        // for this Facility the primitive is absent.
        #expect(try verdict(wrongKind) == .unvalidated)

        // A requirement with no row at all.
        let missing = Facility(name: "missing", requirements: [.symbol(.postEventRecordTo)])
        #expect(try verdict(verified, missing) == .unvalidated)

        // No requirement at all: the build entry is the whole promise, which is
        // the Fence's real situation.
        #expect(try verdict(verified, Facility(name: "empty", requirements: [])) == .validated)
    }

    @Test("the bundled Ledger loads from Bundle.module and validates every Facility")
    func bundledLedger() throws {
        let ledger = try Ledger.bundled()
        #expect(ledger.schemaVersion == Ledger.supportedSchemaVersion)
        let entry = try #require(ledger.entry(for: Self.build), "26A5425a must be in the Ledger")
        #expect(entry.hardware.contains("Mac16,1"))
        for facility in Facility.all {
            #expect(
                ledger.verdict(for: facility, in: entry) == .validated,
                "\(facility.name) must be validated on 26A5425a"
            )
        }
    }

    /// The requirement list and the Ledger keys are two halves of the same
    /// statement, and this is the test that keeps them one: a renamed primitive
    /// that only lands in one of the two files fails here instead of silently
    /// turning a Facility `unvalidated` on a machine that works.
    @Test("every requirement of every Facility has a row of the right kind")
    func requirementsCovered() throws {
        let ledger = try Ledger.bundled()
        let entry = try #require(ledger.entry(for: Self.build))
        for facility in Facility.all {
            for requirement in facility.requirements {
                let row = try #require(
                    entry.primitives[requirement.ledgerKey],
                    "\(facility.name) requires \(requirement.ledgerKey), which the Ledger does not describe"
                )
                #expect(row.kind == requirement.kind, "\(requirement.ledgerKey) is filed as \(row.kind)")
            }
        }
    }
}
