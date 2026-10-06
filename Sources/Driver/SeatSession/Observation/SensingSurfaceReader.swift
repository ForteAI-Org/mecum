//
//  SensingSurfaceReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Dispatch
import OSLog
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
///
/// ## The one remembered reading
///
/// This reader owns the `AccessibilityWindowNumberCache` the pass reads window
/// identity through, which is what keeps it per seat rather than process wide.
/// It holds one fact, the Window ID behind an accessibility element, and that
/// type's documentation carries the argument for why that fact cannot change.
/// This reader supplies the other half of it: a pass that did not qualify
/// empties the cache, because a remembered Window ID that stopped belonging to
/// its element can reach a reading only as a window WindowServer would not
/// attest, and that is what an unqualified pass reports. So the cache never
/// outlives a pass it could have spoiled, and the pass after it is uncached.
nonisolated package struct SensingSurfaceReader: AssignedSurfaceReading {

    private static let observationLog = Logger(
        subsystem: "dev.forte.AgentSeatKit",
        category : "Observation"
    )

    /// One complete native pass: the assigned processes, the identities the
    /// previous pass retained, and the cache the identity reads go through.
    package typealias NativeSurfacePass = @Sendable (
        Set<Int32>,
        Set<WindowIdentity>,
        AccessibilityWindowNumberCache
    ) -> Result<AssignedSurfaceSnapshot, CrossCheckedSurfaceReadFailure>

    private let sensing: any SeatSensing
    private let targetTransitions: ApplicationTargetTransitionFilter
    private let windowNumbers: AccessibilityWindowNumberCache
    private let nativePass: NativeSurfacePass

    /// The shipped reader takes the real cross-check. `nativePass` exists for
    /// the Unit tier alone: the fallback branch below is reached only when a
    /// native source is unreadable, and an offline test cannot make AX or the
    /// window server refuse.
    package init(
        sensing   : any SeatSensing,
        nativePass: @escaping NativeSurfacePass =
            CrossCheckedSurfaceReader.snapshot(ownedBy:retaining:windowNumbers:)
    ) {
        self.sensing = sensing
        self.targetTransitions = ApplicationTargetTransitionFilter()
        self.windowNumbers = AccessibilityWindowNumberCache()
        self.nativePass = nativePass
    }

    package func snapshot(ownedBy processIDs: Set<Int32>) -> AssignedSurfaceSnapshot {

        let nativeFailure: CrossCheckedSurfaceReadFailure
        let retained = targetTransitions.retainedIdentities(ownedBy: processIDs)
        if !retained.isEmpty {
            let requested = String(describing: retained.map(\.windowNumber).sorted())
            Self.observationLog.notice(
                "[known-missing] requesting named WindowServer rows=\(requested, privacy: .public)"
            )
        }
        switch nativePass(processIDs, retained, windowNumbers) {
            case .success(let native):
                if !retained.isEmpty {
                    let rows = String(describing: native.inventory.rows.map(\.surface.reference.windowNumber).sorted())
                    let destroyed = String(describing: native.destroyedByWindowServer.map(\.windowNumber).sorted())
                    let withdrawn = String(describing: native.withdrawnByApplication.map(\.windowNumber).sorted())
                    Self.observationLog.notice(
                        "[known-missing] named reply qualified=\(native.inventory.completeness.isQualified, privacy: .public) rows=\(rows, privacy: .public) destroyed=\(destroyed, privacy: .public) withdrawn=\(withdrawn, privacy: .public)"
                    )
                }
                // A remembered Window ID that no longer belongs to its element
                // can only surface here, as a window nothing attested.
                if !native.inventory.completeness.isQualified { windowNumbers.removeAll() }
                return targetTransitions.filter(native, at: DispatchTime.now().uptimeNanoseconds)
            case .failure(let failure):
                windowNumbers.removeAll()
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
        let fallback = AssignedSurfaceSnapshot(
            inventory: SurfaceInventoryReading(
                rows        : rows,
                completeness: .incomplete(
                    reason: "The native cross-check was unavailable: \(nativeFailure). "
                        + "The on-screen window list cannot establish that it carries every "
                        + "surface of the assigned instance"
                )
            )
        )
        // The fallback has incomplete membership, but each row it does carry
        // still has a WindowServer-attested full identity.  Let the same
        // transition filter retain it for the next native pass: otherwise an
        // auxiliary window adopted from this fallback vanishes before any
        // exact request ever names it, leaving containment to wait on a raw
        // absence forever.  An entirely unavailable fallback returns above,
        // because it supplies no identity that may safely be retained.
        return targetTransitions.filter(
            fallback,
            at: DispatchTime.now().uptimeNanoseconds
        )
    }
}
