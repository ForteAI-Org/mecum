//
//  SurfaceEvidence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// EvidenceQuality is what a piece of evidence is allowed to decide. It exists
/// so that "where did this fact come from" is a field and not a convention: a
/// reader that only knew the fact could not tell a window server attestation
/// from a PID somebody typed.
nonisolated package enum EvidenceQuality: String, Sendable, Equatable {

    /// Established through a chain the kit can re-verify. Only this quality may
    /// attribute a surface to an assigned application.
    case attested

    /// A real reading that cannot carry the conclusion on its own. It may raise
    /// a doubt and may never resolve one.
    case indicative

    /// Not evidence at all for this question, whatever it is evidence of.
    case unqualified

    package var authorisesAttribution: Bool { self == .attested }
}

/// EvidenceProvenance names where a fact about a surface came from, and maps to
/// the quality that source can support.
///
/// The unqualified cases are listed rather than omitted because they are the
/// ones that keep being offered as proof: a PID, a window title, or the absence
/// of an error from a call nobody verified.
///
/// The two attested cases name adapters that are **not** qualified on this
/// build. Nothing in the shipped package produces them: they are the shape the
/// nucleus will accept once a qualification exists, and the shape a controlled
/// test double supplies to exercise the algorithms offline. A unit suite that
/// hands one in has proved the algorithm, never the native capability.
nonisolated package enum EvidenceProvenance: String, Sendable, Equatable, CaseIterable {

    /// A `WindowIdentity` resolved through the owning WindowServer connection
    /// and the documented PID mapping.
    case windowServerAttestedIdentity

    /// An enumeration of every surface of one instance, by an adapter qualified
    /// to claim that the enumeration is whole.
    case qualifiedSurfaceEnumeration

    /// A relation between a helper surface and one assigned application or
    /// window, attested by a qualified adapter rather than inferred.
    case helperRelationAttestation

    /// The window server's on-screen list. It is a real reading and it is not
    /// complete: a hidden or minimised window is absent from it.
    case onScreenWindowList

    /// The window server's list including off-screen rows. Still not a proof of
    /// completeness for one application's surfaces.
    case allWindowList

    /// A process identifier, with nothing binding it to a process lifetime.
    case processIdentifier

    /// A window title, which the application writes.
    case windowTitle

    package var quality: EvidenceQuality {
        switch self {
            case .windowServerAttestedIdentity,
                 .qualifiedSurfaceEnumeration,
                 .helperRelationAttestation:   .attested
            case .onScreenWindowList,
                 .allWindowList:               .indicative
            case .processIdentifier,
                 .windowTitle:                 .unqualified
        }
    }
}

/// InventoryCompleteness says whether a reading of an application's surfaces can
/// be treated as the whole of them, and separates the two ways it cannot.
///
/// A failed read and an incomplete read are different facts and the kit answers
/// them differently: a failed read changes nothing at all, while an incomplete
/// one still carries the surfaces it did see and keeps the input gate closed.
nonisolated package enum InventoryCompleteness: Sendable, Equatable {

    /// Every surface of the application is in this reading, on evidence that can
    /// support that claim.
    case complete(provenance: EvidenceProvenance)

    /// The reading succeeded and does not carry every surface, or carries them
    /// on evidence that cannot establish completeness.
    case incomplete(reason: String)

    /// The reading failed. It is not an empty application.
    case unavailable(reason: String)

    /// True only for a complete reading whose provenance can support the claim.
    /// An on-screen window list is a real reading and answers false here, which
    /// is why a unit suite cannot certify inventory completeness.
    package var isQualified: Bool {
        guard case .complete(let provenance) = self else { return false }
        return provenance.quality.authorisesAttribution
    }

    /// True when nothing was read. The caller must leave its state untouched.
    package var isReadFailure: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Why this reading cannot be treated as the whole of the application, in
    /// terms a consumer can act on, and nil when it can.
    package var unqualifiedReason: String? {
        switch self {
            case .complete(let provenance):
                guard !provenance.quality.authorisesAttribution else { return nil }
                return "The reading claims completeness on \(provenance.rawValue), "
                    + "which cannot carry it"

            case .incomplete(let reason):  return reason
            case .unavailable(let reason): return reason
        }
    }
}

/// SurfaceInventoryReading is one pass over the surfaces that may belong to an
/// assigned application, with the provenance of each row and the completeness of
/// the pass itself.
///
/// It carries readings and no conclusions. Attribution is `SurfaceAttributor`'s
/// and containment is the coordinator's, so a reading can be built by a test
/// double or by a native adapter without either of them deciding anything.
nonisolated package struct SurfaceInventoryReading: Sendable, Equatable {

    /// One row of the reading: the surface as the window server answered it and
    /// where that row came from.
    nonisolated package struct Row: Sendable, Equatable {

        package let surface   : WindowSurface
        package let provenance: EvidenceProvenance

        /// True for a window its application ordered out: accessibility no
        /// longer lists it and the window server still attests it, off screen.
        package let isOrderedOut: Bool

        package init(surface: WindowSurface, provenance: EvidenceProvenance, isOrderedOut: Bool = false) {
            self.surface      = surface
            self.provenance   = provenance
            self.isOrderedOut = isOrderedOut
        }
    }

    package let rows        : [Row]
    package let completeness: InventoryCompleteness

    package init(rows: [Row], completeness: InventoryCompleteness) {
        self.rows         = rows
        self.completeness = completeness
    }

    /// The reading that failed, which is not an application with no windows.
    package static func unavailable(reason: String) -> SurfaceInventoryReading {
        SurfaceInventoryReading(rows: [], completeness: .unavailable(reason: reason))
    }
}
