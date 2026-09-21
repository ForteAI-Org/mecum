//
//  SelectionEvidenceReport.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// EvidenceVerdict is what a body of evidence established, with the four
/// outcomes kept apart that a single boolean would merge.
///
/// `notSupported` and `inconclusive` are not a passing result in disguise: a
/// required case that was not qualified blocks whatever depends on it, and a
/// proof that was never run is reported as never run.
nonisolated package enum EvidenceVerdict: String, Sendable, Equatable {

    case passed
    case failed

    /// The capability is absent on this build, established as absent.
    case notSupported

    /// The evidence was collected and does not decide the question.
    case inconclusive

    /// The proof was not performed. Nothing may be concluded from it.
    case notRun
}

/// SelectionEvidenceReport separates what the offline suites establish about the
/// selection policy from what has been qualified about the native signals the
/// policy would need on a real system. The two are reported side by side and
/// never summed.
///
/// ## Why the report is a value in the sources
///
/// The nucleus accepts a conclusion only from a provenance that can carry it,
/// and the report names which shipped adapter produces each provenance. Provider
/// presence is not a Live verdict, so a reader of the code can distinguish an
/// implemented path from one exercised against real applications.
///
/// ## What it does not say
///
/// No row claims a macOS capability. A controlled double that hands in a
/// qualified provenance proves the algorithm downstream of the signal; it is not
/// a qualification of the signal, and the native verdicts stay `notRun` until a
/// separate qualification step produces them.
nonisolated package struct SelectionEvidenceReport: Sendable, Equatable {

    /// One conclusion, the shape that would carry it, what exists natively, and
    /// what the offline suites can and cannot reach.
    nonisolated package struct Row: Sendable, Equatable {

        package let conclusion: SelectionConclusion

        /// The provenance the nucleus accepts for this conclusion, nil when the
        /// conclusion belongs to another nucleus.
        package let acceptedProvenance: SelectionProvenance?

        /// The adapter producing that provenance on this build, or nil when the
        /// build still has no native source for it.
        package let nativeProvider: String?

        package let nativeVerdict: EvidenceVerdict

        /// What a controlled, offline suite establishes about this conclusion,
        /// stated so that it cannot be read as a native result.
        package let offlineScope: String

        package init(
            conclusion        : SelectionConclusion,
            acceptedProvenance: SelectionProvenance?,
            nativeProvider    : String?,
            nativeVerdict     : EvidenceVerdict,
            offlineScope      : String
        ) {
            self.conclusion         = conclusion
            self.acceptedProvenance = acceptedProvenance
            self.nativeProvider     = nativeProvider
            self.nativeVerdict      = nativeVerdict
            self.offlineScope       = offlineScope
        }
    }

    package let rows: [Row]

    package init(rows: [Row]) {
        self.rows = rows
    }

    package func row(for conclusion: SelectionConclusion) -> Row? {
        rows.first { $0.conclusion == conclusion }
    }

    /// The conclusions no adapter on this build can produce evidence for.
    package var conclusionsWithoutNativeProvider: [SelectionConclusion] {
        rows.filter { $0.nativeProvider == nil }.map(\.conclusion)
    }

    /// The state of this build. `CrossCheckedSurfaceReader` provides AX role,
    /// parentage, modality, visibility and the unique focused/main application
    /// window joined to an attested WindowServer identity. The transition filter
    /// turns only changes in that current-window state into recency. Their Live
    /// matrix is deliberately still `notRun`.
    package static let current = SelectionEvidenceReport(rows: [
        Row(
            conclusion        : .surfaceRole,
            acceptedProvenance: .qualifiedRoleAttestation,
            nativeProvider    : "CrossCheckedSurfaceReader",
            nativeVerdict     : .notRun,
            offlineScope      : "AXRole and AXSubrole are joined to the exact WindowServer identity; "
                + "unknown subroles remain unread instead of being inferred from a level."
        ),
        Row(
            conclusion        : .parentRelation,
            acceptedProvenance: .qualifiedParentAttestation,
            nativeProvider    : "CrossCheckedSurfaceReader",
            nativeVerdict     : .notRun,
            offlineScope      : "AXWindow binds sheets and drawers to their containing attested "
                + "window; ordinary top-level self references are discarded."
        ),
        Row(
            conclusion        : .modalRelation,
            acceptedProvenance: .qualifiedModalAttestation,
            nativeProvider    : "CrossCheckedSurfaceReader",
            nativeVerdict     : .notRun,
            offlineScope      : "AXModal uses window scope when an AX parent is attested and application "
                + "scope otherwise. An unreadable modal attribute suspends input."
        ),
        Row(
            conclusion        : .frontOrder,
            acceptedProvenance: .qualifiedFrontOrderAttestation,
            nativeProvider    : "CrossCheckedSurfaceReader + ApplicationTargetTransitionFilter",
            nativeVerdict     : .notRun,
            offlineScope      : "A unique AX focused window, falling back to a unique AX main window, "
                + "supplies application-local order only after every AX-scoped window is attested."
        ),
        Row(
            conclusion        : .raiseProvenance,
            acceptedProvenance: .qualifiedRaiseAttribution,
            nativeProvider    : "CrossCheckedSurfaceReader + ApplicationTargetTransitionFilter",
            nativeVerdict     : .notRun,
            offlineScope      : "AX focused/main state is application semantic state, not WindowServer "
                + "member order or a placement issued by the kit."
        ),
        Row(
            conclusion        : .visibilityState,
            acceptedProvenance: .qualifiedVisibilityAttestation,
            nativeProvider    : "CrossCheckedSurfaceReader",
            nativeVerdict     : .notRun,
            offlineScope      : "AXMinimized, application hiding and the WindowServer on-screen state "
                + "separate visible, hidden, minimised and uncertain readings."
        ),
        Row(
            conclusion        : .helperRelation,
            acceptedProvenance: nil,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Attribution stays the assignment nucleus's, on its own attested "
                + "helper claims. The selection adds no parentage to a helper surface."
        ),
    ])
}
