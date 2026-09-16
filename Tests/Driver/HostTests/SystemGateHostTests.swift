//
//  SystemGateHostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import Testing

/// The host tier of the version gate: it resolves the real symbols on the build
/// it is running on and reproduces, byte for byte, the round trip the offsets
/// were measured with. Nothing is posted, nothing is prompted: every event created
/// here is thrown away, and only `preflight` is ever called.
@Suite("System gate on the running build", .serialized)
struct SystemGateHostTests {

    /// The measured values. If a line of this table stops holding, the offsets
    /// moved and every Facility that writes a record has to refuse.
    static let measuredDeclaredLength: UInt32 = 248
    static let measuredWindowField   : UInt32 = 51
    static let measuredOwnerField    : UInt32 = 52

    @Test("every private symbol resolves, in the image the Ledger names", .enabled(if: tierEnabled()))
    func symbolsResolve() throws {
        let table  = SymbolTable.shared
        let ledger = try Ledger.bundled()
        let entry  = try #require(
            ledger.entry(for: .current),
            "this build (\(BuildIdentity.current.osVersion)) is not in the Ledger"
        )

        for symbol in PrivateSymbol.allCases {
            let resolved = try #require(table.symbols[symbol], "\(symbol.rawValue) did not resolve")
            #expect(resolved.name    == symbol.rawValue)
            #expect(resolved.address != 0)
            guard let row = entry.primitives[symbol.rawValue], let expected = row.image else { continue }
            #expect(
                resolved.image == expected,
                "\(symbol.rawValue) resolved in \(resolved.image), the Ledger says \(expected)"
            )
        }
    }

    @Test("every private class answers, and so does every selector", .enabled(if: tierEnabled()))
    func classesResolve() {
        let table = SymbolTable.shared
        for privateClass in PrivateClass.allCases {
            #expect(table.classes[privateClass] != nil, "\(privateClass.rawValue) did not resolve")
        }
        for selector in PrivateSelector.all {
            #expect(
                table.selectors.contains(selector.ledgerKey),
                "\(selector.ledgerKey) is not answered by its class"
            )
        }
    }

    /// The whole measured map, reproduced: the record's declared length, the two
    /// integer offsets against their field ids in both directions, the
    /// window-local point against `CGEventSetWindowLocation`, and the negative
    /// half of the finding, that **no** public double field reads 0x20 or 0x28
    /// back.
    @Test("the record round trip reproduces the measured map", .enabled(if: tierEnabled()))
    func recordRoundTrip() throws {
        let table = SymbolTable.shared
        let recordPointer = try #require(
            table.function(.eventRecordPointer, as: SymbolABI.EventRecordPointer.self)
        )
        let source = try #require(CGEventSource(stateID: .privateState))
        let event  = try #require(
            CGEvent(
                mouseEventSource   : source,
                mouseType          : .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 100, y: 200),
                mouseButton        : .left
            )
        )
        let eventPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(event).toOpaque())
        let record = try #require(recordPointer(UnsafeRawPointer(eventPointer)))

        let declared = try RecordLayout.validateDeclaredLength(of: record)
        #expect(declared == Self.measuredDeclaredLength)
        let length = Int(declared)

        // Field 51 writes 0x3C, and 0x3C reads back through field 51.
        let windowField = try #require(CGEventField(rawValue: Self.measuredWindowField))
        event.setIntegerValueField(windowField, value: 0x7E7F_8081)
        #expect(try RecordLayout.read(
            UInt32.self, at: RecordLayout.windowNumberOffset, from: record, length: length
        ) == 0x7E7F_8081)
        try RecordLayout.write(
            UInt32(0x1234_5678),
            at    : RecordLayout.windowNumberOffset,
            into  : record,
            length: length
        )
        #expect(event.getIntegerValueField(windowField) == 0x1234_5678)

        // Field 52 writes 0x40, and 0x40 reads back through field 52.
        let ownerField = try #require(CGEventField(rawValue: Self.measuredOwnerField))
        event.setIntegerValueField(ownerField, value: 0x8E8F_9091)
        #expect(try RecordLayout.read(
            UInt32.self, at: RecordLayout.ownerConnectionOffset, from: record, length: length
        ) == 0x8E8F_9091)
        try RecordLayout.write(
            UInt32(0x2233_4455),
            at    : RecordLayout.ownerConnectionOffset,
            into  : record,
            length: length
        )
        #expect(event.getIntegerValueField(ownerField) == 0x2233_4455)

        // CGEventSetWindowLocation writes exactly 0x20 and 0x28.
        let setWindowLocation = try #require(
            table.function(.setWindowLocation, as: SymbolABI.SetWindowLocation.self)
        )
        setWindowLocation(eventPointer, 11.5, 22.25)
        #expect(try RecordLayout.read(
            Double.self, at: RecordLayout.localPointXOffset, from: record, length: length
        ) == 11.5)
        #expect(try RecordLayout.read(
            Double.self, at: RecordLayout.localPointYOffset, from: record, length: length
        ) == 22.25)

        // And nothing public reads them back: the JSON's readback for 0x20 and
        // 0x28 is empty, which is why the setter is the only proof there is.
        let readers = (UInt32(0)..<256).filter { identifier in
            guard let field = CGEventField(rawValue: identifier) else { return false }
            let value = event.getDoubleValueField(field)
            return value == 11.5 || value == 22.25
        }
        #expect(readers.isEmpty, "public double fields \(readers) now read the window-local point")

        // The global location is not the window-local point.
        #expect(event.location != CGPoint(x: 11.5, y: 22.25))
    }

    @Test("the cross validation the Facilities run at start passes", .enabled(if: tierEnabled()))
    func crossValidationPasses() {
        let check = RecordLayout.crossValidate()
        #expect(check.declaredLength == Self.measuredDeclaredLength)
        #expect(check.windowNumberRoundTrip)
        #expect(check.ownerConnectionRoundTrip)
        #expect(check.windowLocationRoundTrip)
        #expect(check.passed, "\(check.failureReason ?? "no reason")")
    }

    @Test("the running build is the one the Ledger describes", .enabled(if: tierEnabled()))
    func buildIdentityMatchesLedger() throws {
        let build = BuildIdentity.current
        #expect(!build.osVersion.isEmpty)
        #expect(!build.productVersion.isEmpty)
        #expect(!build.hardwareModel.isEmpty)
        #expect(build.nanosecondsPerTick > 0)

        let ledger = try Ledger.bundled()
        let entry  = try #require(ledger.entry(for: build), "\(build.osVersion) is not in the Ledger")
        #expect(entry.productVersion == build.productVersion)
        #expect(
            entry.hardware.contains(build.hardwareModel),
            "\(build.hardwareModel) is not in the hardware list of \(build.osVersion)"
        )
    }

    /// The self checks are the part of the gate that has to hold here and now.
    /// The grants are not: a test process may well have none, and that is a
    /// `permissionMissing`, never an `unavailable`.
    @Test("no Facility is unavailable or unvalidated on this build", .enabled(if: tierEnabled()))
    func facilitiesAreReady() {
        for facility in Facility.all {
            #expect(
                FacilityGate.selfCheckFailure(for: facility) == nil,
                "\(facility.name) failed a self check"
            )
            let gate = FacilityGate.current(facility: facility)
            switch gate.readiness {
            case .validated:
                #expect(gate.mayAct)
                #expect(!gate.unvalidatedBuild)
            case .permissionMissing(let kind):
                #expect(!Permissions.preflight(kind))
                #expect(!gate.mayAct)
            case .unvalidated, .unavailable:
                Issue.record("\(facility.name) is \(gate.readiness) on this build")
            }
        }
    }
}
