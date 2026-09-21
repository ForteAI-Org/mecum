//
//  SurfaceParentClaim.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SurfaceParentClaim is a statement that one attested surface belongs to
/// another: the dialog of a document, the transient menu of the window it was
/// opened from.
///
/// It is a separate claim from the role and from the modal relation because it
/// is a separate conclusion. A window can be a dialog without anybody knowing
/// whose, and a surface can block another without being its child. The
/// provenance must carry `SelectionConclusion.parentRelation`: an attested
/// identity says which window this is and nothing about whose it is.
///
/// The nucleus uses the parent for exactly one decision, the return when a
/// dialog closes, and it never uses it to move, raise or admit anything.
nonisolated package struct SurfaceParentClaim: Sendable, Equatable {

    package let child     : WindowIdentity
    package let parent    : WindowIdentity
    package let provenance: SelectionProvenance

    package init(child: WindowIdentity, parent: WindowIdentity, provenance: SelectionProvenance) {
        self.child      = child
        self.parent     = parent
        self.provenance = provenance
    }
}
