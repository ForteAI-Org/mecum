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
/// separate story. What it adds is the two claims no shipped adapter can make on
/// this build: that the enumeration is the whole of the instance's surfaces, and
/// what each surface is and whether it is visible.
///
/// Supplying those claims here proves the algorithms and proves nothing about
/// macOS. The shipped `SensingSurfaceReader` still reports an unqualified
/// enumeration and no selection facts, and that gap is what the seat refuses on.
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

    /// Per-surface overrides. Anything absent is a visible document.
    var roles       : [Int: SurfaceRole]       = [:]
    var visibilities: [Int: SurfaceVisibility] = [:]

    /// Parent relations, by child Window ID, for the dialog return.
    var parents: [Int: WindowIdentity] = [:]

    /// True to answer a failed pass, which must leave membership untouched.
    var readingFails = false

    init(sensing: FakeSensing) {
        self.sensing = sensing
    }

    func read(ownedBy processIDs: Set<Int32>) -> SurfaceInventoryReading {

        guard !readingFails else {
            return .unavailable(reason: "The controlled reader was asked to fail")
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
        return SurfaceInventoryReading(rows: rows, completeness: completeness)
    }

    func selectionClaims(for reading: SurfaceInventoryReading) -> SelectionClaimBatch {

        var batch = SelectionClaimBatch()
        for row in reading.rows {
            guard let identity = row.surface.reference.identity else { continue }
            batch.roles.append(
                SurfaceRoleClaim(
                    surface   : identity,
                    role      : roles[identity.windowNumber] ?? .document,
                    provenance: .qualifiedRoleAttestation
                )
            )
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
        }
        return batch
    }
}
