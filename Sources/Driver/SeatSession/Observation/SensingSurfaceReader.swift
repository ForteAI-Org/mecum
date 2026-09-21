//
//  SensingSurfaceReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// SensingSurfaceReader is the shipped conformer: it reads the window server
/// through the seat's own sensing and says exactly what that evidence can carry.
///
/// ## Attested rows, unqualified enumeration
///
/// Each row's identity comes from the owning window server connection, so the
/// row provenance is `windowServerAttestedIdentity` and attribution works. The
/// **pass** is a different claim: an on-screen window list does not carry every
/// surface of an instance, a hidden or minimised window is simply missing from
/// it, so completeness is reported as incomplete. The containment coordinator
/// turns that into `inventoryNotQualified`, the selection reports
/// `containmentNotVerified`, and an observation is refused with those causes
/// named. That is the state of the evidence on this build, not a policy choice
/// of this type.
///
/// ## No selection claims at all
///
/// It attests no role, no parent, no modal relation, no visibility state and no
/// recency. Every source it could use is listed in `SelectionProvenance` as
/// unable to carry the corresponding conclusion: a window level is not a role,
/// an on-screen list is not a visibility state, and a raise this kit asked for is
/// not the application bringing a window forward. Returning an empty batch keeps
/// the surfaces ineligible with a named reason instead of guessing.
nonisolated package struct SensingSurfaceReader: AssignedSurfaceReading {

    private let sensing: any SeatSensing

    package init(sensing: any SeatSensing) {
        self.sensing = sensing
    }

    package func read(ownedBy processIDs: Set<Int32>) -> SurfaceInventoryReading {

        guard let surfaces = sensing.windowSurfaces(ownedBy: processIDs) else {
            return .unavailable(reason: "The window server list could not be read")
        }
        let rows = surfaces.map {
            SurfaceInventoryReading.Row(surface: $0, provenance: .windowServerAttestedIdentity)
        }
        return SurfaceInventoryReading(
            rows        : rows,
            completeness: .incomplete(
                reason: "The on-screen window list cannot establish that it carries "
                    + "every surface of the assigned instance"
            )
        )
    }

    package func selectionClaims(for reading: SurfaceInventoryReading) -> SelectionClaimBatch {
        .none
    }
}
