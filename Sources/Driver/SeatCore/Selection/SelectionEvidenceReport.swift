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
/// and no adapter on this build produces any of those provenances. That fact is
/// what makes the algorithms exercisable offline and the native path inactive,
/// so a reader of the code has to be able to see it without running anything.
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

        /// The adapter producing that provenance on this build. Nil everywhere,
        /// which is the point of the row.
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

    /// The conclusions no adapter on this build can produce evidence for. Every
    /// conclusion is in it, and each one blocks the activation of the adapter
    /// that would depend on it.
    package var conclusionsWithoutNativeProvider: [SelectionConclusion] {
        rows.filter { $0.nativeProvider == nil }.map(\.conclusion)
    }

    /// The state of this build: the policy is exercised offline against written
    /// evidence, and no native proof of any selection signal has been run.
    package static let current = SelectionEvidenceReport(rows: [
        Row(
            conclusion        : .surfaceRole,
            acceptedProvenance: .qualifiedRoleAttestation,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written role claims decide eligibility. Nothing here reads a role "
                + "from a running application, and a window level is not a role."
        ),
        Row(
            conclusion        : .parentRelation,
            acceptedProvenance: .qualifiedParentAttestation,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written parent claims decide the return of a closing dialog. No "
                + "parentage is derived from titles, levels or coinciding frames."
        ),
        Row(
            conclusion        : .modalRelation,
            acceptedProvenance: .qualifiedModalAttestation,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written modal claims decide precedence and blocking. General "
                + "coverage of modal relations on macOS is not established here."
        ),
        Row(
            conclusion        : .frontOrder,
            acceptedProvenance: .qualifiedFrontOrderAttestation,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written instants order the qualified events. The order of the "
                + "calls, the member order and the Window IDs are never an order."
        ),
        Row(
            conclusion        : .raiseProvenance,
            acceptedProvenance: .qualifiedRaiseAttribution,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written raise origins keep the kit's own placements out of the "
                + "recency. Telling them apart on a real system is not shown."
        ),
        Row(
            conclusion        : .visibilityState,
            acceptedProvenance: .qualifiedVisibilityAttestation,
            nativeProvider    : nil,
            nativeVerdict     : .notRun,
            offlineScope      : "Written visibility states separate established hiding and "
                + "minimising from an uncertain reading and from an absence."
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
