//
//  ScopedSurfaceReadingTests.swift
//  AgentSeatKit
//

import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import Testing
@testable import WindowPlacement

@Suite("Scoped WindowServer failure evidence")
struct ScopedSurfaceReadingTests {

    private func gate(
        failure   : String? = nil,
        permission: PermissionKind? = nil
    ) throws -> FacilityGate {
        let ledger = try Ledger(data: Data(#"{"schema_version":1,"builds":{}}"#.utf8))
        return FacilityGate.evaluate(
            facility         : .windowIdentity,
            build            : BuildIdentity(osVersion: "unknown", productVersion: "27", hardwareModel: "test"),
            ledger           : ledger,
            selfCheckFailure : failure,
            missingPermission: permission
        )
    }

    private func row(
        _ number : Int,
        processID: Int32 = 42,
        bounds   : CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100)
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: processID),
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowLayer as String: NSNumber(value: 3),
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: NSNumber(value: 1)
        ]
        if let bounds { row[kCGWindowBounds as String] = bounds.dictionaryRepresentation }
        return row
    }

    private func reference(
        processID: Int32,
        number   : Int,
        frame    : CGRect
    ) -> WindowReference {
        WindowReference(
            identity: WindowIdentity(
                process: ProcessIdentity(
                    processID         : processID,
                    serialNumberHigh  : 0,
                    serialNumberLow   : 1
                ),
                windowNumber     : number,
                ownerConnectionID: 9
            ),
            frame: frame
        )
    }

    @Test("failed self checks and missing permissions never read or attest a list")
    func refusedBeforeReading() throws {
        for gate in [try gate(failure: "unresolved primitive"), try gate(permission: .accessibility)] {
            var read = false
            var attested = false
            let result = WindowServerProbe.readSurfaces(
                matching : [42: [7]],
                gate     : gate,
                read     : { _ in read = true; return [] },
                attesting: { _, _, _ in attested = true; return nil }
            )
            #expect(throws: WindowServerProbe.SurfaceReadFailure.facilityUnavailable(gate.readiness)) {
                try result.get()
            }
            #expect(!read)
            #expect(!attested)
        }
    }

    @Test("unvalidated builds read only the requested IDs without an opt in")
    func unvalidatedReading() throws {
        var ids: Set<CGWindowID> = []
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7, 8]],
            gate     : try gate(),
            read     : { ids = Set($0); return [] },
            attesting: { _, _, _ in nil }
        )
        #expect(try result.get().isEmpty)
        #expect(ids == [7, 8])
    }

    @Test("list failure is distinct from successful absence")
    func listFailure() throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in nil },
            attesting: { _, _, _ in nil }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.listUnavailable) { try result.get() }
    }

    @Test("invalid geometry and a failed identity name their Window ID")
    func invalidPresentRows() throws {
        let invalid = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7, bounds: nil)] },
            attesting: { _, _, _ in nil }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.invalidGeometry(windowNumber: 7)) {
            try invalid.get()
        }
        let unattested = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7)] },
            attesting: { _, _, _ in nil }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.identityUnavailable(windowNumber: 7)) {
            try unattested.get()
        }
    }

    @Test("a present row preserves independently attested identity, geometry and visibility")
    func attestedPresentRow() throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7)] },
            attesting: { reference(processID: $0, number: $1, frame: $2) }
        )
        let surfaces = try result.get()
        let surface = try #require(surfaces.first)
        #expect(surfaces.count == 1)
        #expect(surface.reference.processID == 42)
        #expect(surface.reference.windowNumber == 7)
        #expect(surface.reference.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(surface.level == 3)
        #expect(surface.isVisible)
    }

    @Test(
        "non-finite or negative geometry fails before ownership attestation",
        arguments: [
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: -1, height: 100)
        ]
    )
    func invalidDimensions(_ bounds: CGRect) throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7, bounds: bounds)] },
            attesting: { _, _, _ in
                Issue.record("invalid geometry reached attestation")
                return nil
            }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.invalidGeometry(windowNumber: 7)) {
            try result.get()
        }
    }

    @Test("one rejected row fails the complete reading instead of returning a partial inventory")
    func partialAttestationFails() throws {
        var attested: [Int] = []
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7, 8]],
            gate     : try gate(),
            read     : { _ in [row(7), row(8)] },
            attesting: { processID, number, frame in
                attested.append(number)
                guard number == 7 else { return nil }
                return reference(processID: processID, number: number, frame: frame)
            }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.identityUnavailable(windowNumber: 8)) {
            try result.get()
        }
        #expect(attested == [7, 8])
    }

    @Test("an attestation contradicting the requested row is refused", arguments: ["process", "number", "frame"])
    func contradictoryAttestation(_ field: String) throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7)] },
            attesting: { processID, number, frame in
                reference(
                    processID: field == "process" ? 43 : processID,
                    number   : field == "number" ? 8 : number,
                    frame    : field == "frame" ? frame.offsetBy(dx: 1, dy: 0) : frame
                )
            }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.identityUnavailable(windowNumber: 7)) {
            try result.get()
        }
    }

    @Test("a recycled Window ID owned by another process is absent from the requested inventory")
    func changedOwnerIsAbsent() throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(7, processID: 43)] },
            attesting: { _, _, _ in
                Issue.record("another process reached attestation")
                return nil
            }
        )
        #expect(try result.get().isEmpty)
    }

    @Test("an invalid requested ID refuses rather than silently shrinking the scope", arguments: [0, -1, Int(UInt32.max) + 1])
    func invalidRequestedID(_ number: Int) throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [number]],
            gate     : try gate(),
            read     : { _ in Issue.record("invalid scope reached WindowServer"); return [] },
            attesting: { _, _, _ in nil }
        )
        #expect(throws: WindowServerProbe.SurfaceReadFailure.invalidWindowNumber(number)) { try result.get() }
    }

    @Test("unrequested rows cannot become inventory members")
    func unrelatedRow() throws {
        let result = WindowServerProbe.readSurfaces(
            matching : [42: [7]],
            gate     : try gate(),
            read     : { _ in [row(9)] },
            attesting: { _, _, _ in Issue.record("unrequested row reached attestation"); return nil }
        )
        #expect(try result.get().isEmpty)
    }
}
