//
//  SelectionEvidence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SelectionConclusion names one question the selection nucleus has to answer
/// from evidence, kept separate from every other question.
///
/// The set exists because evidence quality is specific to a conclusion. An
/// attested `WindowIdentity` establishes which window a row is about and nothing
/// else: it does not say whether the window is a dialog, whose child it is, what
/// it blocks, where it stands in the application's order, or who raised it. A
/// single "is this attested" flag would let one proof travel to a conclusion it
/// was never evidence for, which is the mistake this enum makes impossible.
nonisolated package enum SelectionConclusion: String, Sendable, Equatable, CaseIterable {

    /// Whether the surface is a document, a dialog, an interactive panel, a
    /// tooltip, a decoration or a contextual menu.
    case surfaceRole

    /// Which window a transient or a dialog belongs to.
    case parentRelation

    /// That the surface is modal and what its scope is.
    case modalRelation

    /// The relative order of appearances, reappearances and returns to the front
    /// inside the assigned application.
    case frontOrder

    /// Where a return to the front came from, which is the one fact that
    /// separates the application raising a window from the kit raising it while
    /// containing or preparing.
    case raiseProvenance

    /// Whether the surface is visible and interactive, established hidden or
    /// established minimised.
    case visibilityState

    /// That a surface of another process serves this assigned application. It is
    /// the assignment nucleus's conclusion, carried by
    /// `EvidenceProvenance.helperRelationAttestation`, and it is listed here so
    /// that the evidence report covers it too.
    case helperRelation
}

/// SelectionProvenance names where a fact used by the selection nucleus came
/// from, and which conclusion that source can carry.
///
/// The qualified cases name evidence shapes accepted by the nucleus. The
/// shipped cross-checked reader produces role, parent, modal, visibility and
/// application-local current-window claims. A controlled test double may
/// produce every shape to exercise the algorithms offline, but that alone never
/// qualifies a native capability.
///
/// The unqualified cases are listed rather than omitted because they are the
/// ones that keep being offered as proof of a selection fact: the window level,
/// the global focus of the application, a comparison of two frames, the order of
/// the members by Window ID, and a raise the kit itself asked for.
nonisolated package enum SelectionProvenance: String, Sendable, Equatable, CaseIterable {

    /// A role read through an adapter qualified to name roles.
    case qualifiedRoleAttestation

    /// A parent relation attested by a qualified adapter rather than inferred
    /// from a title, a level or a coinciding frame.
    case qualifiedParentAttestation

    /// A modal relation and its scope, attested by a qualified adapter.
    case qualifiedModalAttestation

    /// A relative order of surfaces inside one application, from an adapter
    /// qualified to claim that the order it reports is the application's. The
    /// native reader derives this only from a unique AX focused or main window,
    /// never from Window IDs or the WindowServer list order.
    case qualifiedFrontOrderAttestation

    /// The origin of a raise, from an adapter qualified to tell an application's
    /// own current-window state from the placements this kit asks for. AX main
    /// and focused-window state is application semantic state; a WindowServer
    /// placement issued by this kit does not manufacture it.
    case qualifiedRaiseAttribution

    /// A visibility state, hidden and minimised included, from an adapter
    /// qualified to establish them rather than infer them from an absence.
    case qualifiedVisibilityAttestation

    /// A `WindowIdentity` resolved through the owning WindowServer connection.
    /// It attests which window this is, and no selection conclusion at all.
    case windowServerAttestedIdentity

    /// The window server's on-screen list. A hidden or minimised window is
    /// absent from it, so it establishes no visibility state and no order.
    case onScreenWindowList

    /// `kCGWindowLayer`. Qt secondary windows were measured at levels 3 and 4 on
    /// this build, so a level is not a role.
    case windowLevel

    /// A window title, which the application writes.
    case windowTitle

    /// A process identifier, with nothing binding it to a process lifetime.
    case processIdentifier

    /// The order of the members of an inventory, which is Window ID order. It is
    /// not a chronology and never was.
    case memberOrderByWindowID

    /// A comparison of two frame readings. It establishes that geometry settled,
    /// which is a different fact from a window coming forward.
    case geometryComparison

    /// The application being frontmost in the User Seat. The global focus does
    /// not decide the target.
    case globalApplicationFocus

    /// A placement this kit asked for while containing, staging or preparing.
    case kitIssuedPlacement

    /// Answers whether this source can carry that conclusion, and nothing wider.
    package func attests(_ conclusion: SelectionConclusion) -> Bool {
        switch self {
            case .qualifiedRoleAttestation:       conclusion == .surfaceRole
            case .qualifiedParentAttestation:     conclusion == .parentRelation
            case .qualifiedModalAttestation:      conclusion == .modalRelation
            case .qualifiedFrontOrderAttestation: conclusion == .frontOrder
            case .qualifiedRaiseAttribution:      conclusion == .raiseProvenance
            case .qualifiedVisibilityAttestation: conclusion == .visibilityState
            case .windowServerAttestedIdentity,
                 .onScreenWindowList,
                 .windowLevel,
                 .windowTitle,
                 .processIdentifier,
                 .memberOrderByWindowID,
                 .geometryComparison,
                 .globalApplicationFocus,
                 .kitIssuedPlacement:             false
        }
    }

    /// True for a shape that carries some selection conclusion.
    package var isQualifiedShape: Bool {
        SelectionConclusion.allCases.contains { attests($0) }
    }
}
