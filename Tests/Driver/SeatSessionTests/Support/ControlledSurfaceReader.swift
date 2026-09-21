//
//  ControlledSurfaceReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
@testable import SeatSession

/// A surface reader whose evidence is qualified by construction, for exercising
/// the production composition offline.
///
/// It reads the same fake window server the seat reads, so membership,
/// verification and containment follow the readings a test sets up rather than a
/// separate story. It can write every completeness, role and visibility case
/// directly, including cases the shipped adapter would have to read through AX
/// and WindowServer.
///
/// Supplying those claims here proves the algorithms and proves nothing about
/// macOS. Native coverage remains the Live tier's job.
final class ControlledSurfaceReader: AssignedSurfaceReading, @unchecked Sendable {

    private let sensing: FakeSensing

    /// The window numbers this reader enumerates. Defaults to every window the
    /// fake window server can answer for.
    var windowNumbers: [Int]?

    /// What the pass claims about its own completeness. A test that wants the
    /// shipped answer sets an incomplete one and watches the gate close.
    var completeness: InventoryCompleteness = .complete(
        provenance: .qualifiedSurfaceEnumeration
    )

    /// Per-reading answers consumed before `completeness`, for a transient
    /// native gap that a bounded readiness reread can resolve.
    var completenessReadings: [InventoryCompleteness] = []

    /// Per-surface overrides. Anything absent is a visible document.
    var roles       : [Int: SurfaceRole]       = [:]
    var visibilities: [Int: SurfaceVisibility] = [:]

    /// Surfaces the pass claims no role for at all, which is not a role it
    /// refuses: it is the window the native reader would not answer for, such
    /// as one with nothing in it yet, and the nucleus holds it as `roleNotRead`.
    var rolesNotRead: Set<Int> = []

    /// Parent relations, by child Window ID, for the dialog return.
    var parents: [Int: WindowIdentity] = [:]

    /// Qualified modal scopes and application-local recency events supplied by
    /// the test scenario.
    var modals : [Int: ModalScope] = [:]
    var recency: [RecencyClaim] = []

    /// True to answer a failed pass, which must leave membership untouched.
    var readingFails = false

    /// Surfaces the application has stopped scoping, as the native reader
    /// reports them once their grace has passed.
    var withdrawn: [WindowIdentity] = []

    /// Surfaces the window server was asked for by identity and answered no row
    /// for at all, which is the one positive proof of closure a reading makes.
    var destroyed: [WindowIdentity] = []

    /// Ancestors the top accessibility level no longer shows, each with the
    /// child that attests it, as the native reader keeps them.
    var obscured: [WindowIdentity: WindowIdentity] = [:]

    /// How many passes were asked of this reader, which is how a test sees that
    /// a bounded rediscovery really took one more reading.
    private(set) var passes = 0

    init(sensing: FakeSensing) {
        self.sensing = sensing
    }

    func snapshot(ownedBy processIDs: Set<Int32>) -> AssignedSurfaceSnapshot {

        passes += 1

        guard !readingFails else {
            return AssignedSurfaceSnapshot(
                inventory: .unavailable(reason: "The controlled reader was asked to fail")
            )
        }
        let numbers = windowNumbers ?? sensing.knownWindowNumbers
        let rows = numbers.compactMap { number -> SurfaceInventoryReading.Row? in
            guard let reference = sensing.windowGeometry(of: number),
                  processIDs.contains(reference.processID)
            else { return nil }
            return SurfaceInventoryReading.Row(
                surface   : WindowSurface(reference: reference, level: 0, isVisible: true),
                provenance: .windowServerAttestedIdentity
            )
        }
        let currentCompleteness = completenessReadings.isEmpty
            ? completeness
            : completenessReadings.removeFirst()
        let reading = SurfaceInventoryReading(rows: rows, completeness: currentCompleteness)

        var batch = SelectionClaimBatch()
        for row in reading.rows {
            guard let identity = row.surface.reference.identity else { continue }
            if !rolesNotRead.contains(identity.windowNumber) {
                batch.roles.append(
                    SurfaceRoleClaim(
                        surface   : identity,
                        role      : roles[identity.windowNumber] ?? .document,
                        provenance: .qualifiedRoleAttestation
                    )
                )
            }
            batch.visibilities.append(
                SurfaceVisibilityClaim(
                    surface   : identity,
                    state     : visibilities[identity.windowNumber] ?? .visibleInteractive,
                    provenance: .qualifiedVisibilityAttestation
                )
            )
            if let parent = parents[identity.windowNumber] {
                batch.parents.append(
                    SurfaceParentClaim(
                        child     : identity,
                        parent    : parent,
                        provenance: .qualifiedParentAttestation
                    )
                )
            }
            if let scope = modals[identity.windowNumber] {
                batch.modals.append(
                    ModalRelationClaim(
                        modal     : identity,
                        scope     : scope,
                        provenance: .qualifiedModalAttestation
                    )
                )
            }
        }
        batch.recency = recency

        var retained: [WindowIdentity: RetainedSurfaceDisposition] = [:]
        for identity in withdrawn { retained[identity] = .withdrawn }
        for identity in destroyed { retained[identity] = .destroyed }
        for (ancestor, child) in obscured { retained[ancestor] = .obscuredByChild(child) }

        return AssignedSurfaceSnapshot(
            inventory: reading,
            claims   : batch,
            retained : retained
        )
    }
}
