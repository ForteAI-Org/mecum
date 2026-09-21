//
//  SurfaceAttributionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

@testable import SeatCore
import Testing

/// Which surfaces belong to an assigned application, decided from the evidence
/// each row carries. No process is inspected and no relation is discovered here:
/// the claims are handed in, exactly as a qualified adapter would have to.
@Suite("Attributing a surface to an assigned application")
struct SurfaceAttributionTests {

    typealias Fixture = AssignmentFixtures

    static func attributor(_ claims: [HelperRelationClaim] = []) -> SurfaceAttributor {
        SurfaceAttributor(instance: Fixture.target, claims: claims)
    }

    // MARK: The instance's own windows

    @Test("A window of the assigned lifetime is the application's own")
    func ownWindowIsAttributed() {
        let surface = Fixture.surface(11, at: Fixture.outside)
        #expect(Self.attributor().attribution(of: surface) == .assignedInstance)
    }

    @Test("A window of the same PID from another lifetime is not the assignment's")
    func reusedProcessIdentifierIsUnrelated() {
        let surface = Fixture.surface(11, at: Fixture.outside, of: Fixture.restart)
        #expect(Self.attributor().attribution(of: surface) == .unrelated)
    }

    @Test(
        "A row identified only by a PID or by a title is uncertain, whatever its numbers say",
        arguments: [EvidenceProvenance.processIdentifier, .windowTitle, .onScreenWindowList, .allWindowList]
    )
    func unattestedProvenanceIsUncertain(_ provenance: EvidenceProvenance) {
        let surface = Fixture.surface(11, at: Fixture.outside)
        #expect(
            Self.attributor().attribution(of: surface, provenance: provenance)
                == .uncertain(.identityNotAttested)
        )
    }

    @Test("A compatibility reference with no attested identity is uncertain")
    func unverifiedReferenceIsUncertain() {
        let row = Fixture.unattestedRow(11, at: Fixture.outside)
        #expect(
            Self.attributor().attribution(of: row.surface, provenance: row.provenance)
                == .uncertain(.identityNotAttested)
        )
    }

    // MARK: Helpers

    @Test("A dedicated helper process is attributed whole")
    func dedicatedHelperIsAttributed() {
        let claim = HelperRelationClaim(
            surface   : Fixture.identity(31, of: Fixture.helper),
            serves    : Fixture.target,
            relation  : .dedicatedProcess,
            provenance: .helperRelationAttestation
        )
        let attributor = Self.attributor([claim])

        #expect(
            attributor.attribution(of: Fixture.surface(31, at: Fixture.outside, of: Fixture.helper))
                == .helperSurface(.dedicatedProcess)
        )
        // Another surface of the same dedicated process comes with it.
        #expect(
            attributor.attribution(of: Fixture.surface(32, at: Fixture.outside, of: Fixture.helper))
                == .helperSurface(.dedicatedProcess)
        )
    }

    @Test("A shared service gives up exactly the surface the relation names")
    func sharedServiceGivesUpOneSurface() {
        let claim = HelperRelationClaim(
            surface   : Fixture.identity(41, of: Fixture.helper),
            serves    : Fixture.target,
            relation  : .sharedServiceSurface(windowNumber: 41),
            provenance: .helperRelationAttestation
        )
        let attributor = Self.attributor([claim])

        #expect(
            attributor.attribution(of: Fixture.surface(41, at: Fixture.outside, of: Fixture.helper))
                == .helperSurface(.sharedServiceSurface(windowNumber: 41))
        )
        #expect(
            attributor.attribution(of: Fixture.surface(42, at: Fixture.outside, of: Fixture.helper))
                == .uncertain(.sharedServiceSurfaceNotNamed)
        )
    }

    @Test("A relation claimed on a PID cannot be verified, so its surfaces are uncertain")
    func unqualifiedClaimRaisesADoubt() {
        let claim = HelperRelationClaim(
            surface   : Fixture.identity(51, of: Fixture.helper),
            serves    : Fixture.target,
            relation  : .dedicatedProcess,
            provenance: .processIdentifier
        )
        #expect(
            Self.attributor([claim])
                .attribution(of: Fixture.surface(51, at: Fixture.outside, of: Fixture.helper))
                == .uncertain(.relationNotVerifiable)
        )
    }

    @Test("A claim that serves another instance attributes nothing here")
    func claimForAnotherInstanceIsIgnored() {
        let claim = HelperRelationClaim(
            surface   : Fixture.identity(61, of: Fixture.helper),
            serves    : Fixture.stranger,
            relation  : .dedicatedProcess,
            provenance: .helperRelationAttestation
        )
        #expect(
            Self.attributor([claim])
                .attribution(of: Fixture.surface(61, at: Fixture.outside, of: Fixture.helper))
                == .unrelated
        )
    }

    @Test("Somebody else's window is nobody's business here")
    func strangerIsUnrelated() {
        #expect(
            Self.attributor().attribution(of: Fixture.surface(71, at: Fixture.outside, of: Fixture.stranger))
                == .unrelated
        )
    }

    @Test("A whole reading keeps its uncertain rows instead of filtering them away")
    func attributedReadingKeepsDoubts() {
        let reading = Fixture.reading([
            Fixture.row(11, at: Fixture.outside),
            Fixture.unattestedRow(12, at: Fixture.outside),
            Fixture.row(71, at: Fixture.outside, of: Fixture.stranger),
        ])
        let attributed = Self.attributor().attributed(reading)

        #expect(attributed.map(\.attribution) == [
            .assignedInstance,
            .uncertain(.identityNotAttested),
            .unrelated,
        ])
    }
}
