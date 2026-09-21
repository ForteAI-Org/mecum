//
//  SensingSurfaceReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Dispatch
import SeatCore

/// SensingSurfaceReader is the shipped conformer. It first asks the cross-checked
/// AX and WindowServer adapter for a complete inventory and qualified role and
/// visibility claims. When either native source is unavailable it falls back to
/// the existing on-screen reading and keeps completeness unqualified.
///
/// ## Attested rows, conservative enumeration
///
/// Each row's identity comes from the owning window server connection, so the
/// row provenance is `windowServerAttestedIdentity` and attribution works. The
/// **pass** is a different claim. `AXWindows` positively scopes the application
/// windows, and the pass is complete only when WindowServer `.optionAll`
/// independently attests every window in that scope for the assigned process
/// lifetimes. Same-process WindowServer surfaces outside AX scope are ignored;
/// a missing counterpart or duplicate returns the joined subset as incomplete.
/// A source that cannot be read takes the on-screen fallback. Both failures
/// leave the gate closed.
///
/// ## Selection claims
///
/// AX role/subrole supplies document, dialog and interactive-panel roles. AX
/// minimisation, application hiding and the WindowServer on-screen bit supply
/// visibility. AX modality and AXWindow supply modal scope and parentage. A
/// unique AX focused window, falling back to a unique main window, supplies the
/// application-local current target. The transition filter turns that state into
/// recency only when it first appears, reappears, or actually changes, so a poll
/// cannot cancel the consumer's standing explicit choice.
nonisolated package struct SensingSurfaceReader: AssignedSurfaceReading {

    private let sensing: any SeatSensing
    private let targetTransitions: ApplicationTargetTransitionFilter

    package init(sensing: any SeatSensing) {
        self.sensing = sensing
        self.targetTransitions = ApplicationTargetTransitionFilter()
    }

    package func snapshot(ownedBy processIDs: Set<Int32>) -> AssignedSurfaceSnapshot {

        let nativeFailure: CrossCheckedSurfaceReadFailure
        let retained = targetTransitions.retainedIdentities(ownedBy: processIDs)
        switch CrossCheckedSurfaceReader.snapshot(ownedBy: processIDs, retaining: retained) {
            case .success(let native):
                return targetTransitions.filter(native, at: DispatchTime.now().uptimeNanoseconds)
            case .failure(let failure):
                nativeFailure = failure
        }

        guard let surfaces = sensing.windowSurfaces(ownedBy: processIDs) else {
            return AssignedSurfaceSnapshot(
                inventory: .unavailable(
                    reason: "The native cross-check was unavailable: \(nativeFailure). "
                        + "The window server fallback list could not be read"
                )
            )
        }
        let rows = surfaces.map {
            SurfaceInventoryReading.Row(surface: $0, provenance: .windowServerAttestedIdentity)
        }
        return AssignedSurfaceSnapshot(
            inventory: SurfaceInventoryReading(
                rows        : rows,
                completeness: .incomplete(
                    reason: "The native cross-check was unavailable: \(nativeFailure). "
                        + "The on-screen window list cannot establish that it carries every "
                        + "surface of the assigned instance"
                )
            )
        )
    }
}
