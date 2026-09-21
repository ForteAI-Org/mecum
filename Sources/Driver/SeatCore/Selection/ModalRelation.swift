//
//  ModalRelation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// ModalScope is what a modal surface blocks. The scope is part of the relation
/// and not an afterthought: a sheet over one document and a modal that stops the
/// whole application lead to different targets remaining usable.
nonisolated package enum ModalScope: Sendable, Equatable, Hashable {

    /// It blocks exactly the window it names. A nested dialog blocks the dialog
    /// it was opened from, which in turn blocks the document, so closing the
    /// innermost one frees only the next.
    case window(WindowIdentity)

    /// It blocks every other surface of the assigned application.
    case application
}

/// ModalRelationClaim is a statement that one attested surface is modal, and
/// over what.
///
/// The provenance must carry `SelectionConclusion.modalRelation`. An attested
/// identity, a window level and a frame drawn over another window are not
/// evidence of modality, and a claim made on one of them is kept as a doubt
/// rather than dropped: a relation nobody could verify suspends the input and
/// must never be read as "there is no modal here".
nonisolated package struct ModalRelationClaim: Sendable, Equatable {

    package let modal     : WindowIdentity
    package let scope     : ModalScope
    package let provenance: SelectionProvenance

    package init(modal: WindowIdentity, scope: ModalScope, provenance: SelectionProvenance) {
        self.modal      = modal
        self.scope      = scope
        self.provenance = provenance
    }
}
