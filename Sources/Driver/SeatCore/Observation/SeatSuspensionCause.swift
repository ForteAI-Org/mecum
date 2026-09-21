//
//  SeatSuspensionCause.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

/// SeatSuspensionCause is one reason the agent may not act, in the vocabulary a
/// consumer sees.
///
/// It is a projection of the selection nucleus's own `SelectionSuspension`, which
/// stays internal to the package because its payloads carry nucleus values a
/// consumer has no use for and no way to construct. Projecting keeps the public
/// surface stable and keeps the nucleus free to name its facts precisely.
///
/// The causes are independent and are reported together. Resolving one says
/// nothing about the others: a fresh Frame does not resolve a modal doubt, and a
/// verified containment does not reopen the gate on its own.
nonisolated public enum SeatSuspensionCause: Sendable, Equatable {

    /// No application is assigned.
    case notAssigned

    /// No member surface is eligible and unblocked. Zero eligible targets is not
    /// the end of an assignment.
    case noEligibleTarget

    /// Several surfaces are equally plausible and their order was not observed,
    /// so the consumer is asked to choose rather than handed an invented recency.
    case explicitSelectionRequired(candidates: [WindowIdentity])

    /// A modal surface blocks the one that would otherwise be the target.
    case modalBlock(modal: WindowIdentity, blocked: WindowIdentity)

    /// A modal relation could not be established, with the doubt as text for a
    /// report. It suspends the input and grants no bypass.
    case modalRelationInDoubt(detail: String)

    /// A visibility reading did not decide.
    case visibilityUncertain(WindowIdentity)

    /// The selected surface was not in the last reading. An absence proves
    /// neither a closure nor a hiding.
    case selectedSurfaceAbsent(WindowIdentity)

    /// One sighting and no second agreeing reading.
    case selectedSurfaceNotVerified(WindowIdentity)

    /// The assignment's containment is not verified, with the blocks as text.
    /// The list is empty when no reading has been folded in yet.
    case containmentNotVerified(blocks: [String])

    /// No observation of the selected target is current.
    case observationMissing

    /// The observation was taken under an earlier selection.
    case observationSuperseded(observed: UInt64, current: UInt64)

    /// The observation is of another window.
    case observationIdentityMismatch(observed: WindowIdentity, selected: WindowIdentity)

    /// The window's frame is no longer the one the observation was taken at.
    case observationGeometryStale(WindowIdentity)

    /// The Monitor's fault also reaches the display or the capture the
    /// observation needs, so it closes the gate as well as the preview.
    case monitorSharedFault

    package init(_ suspension: SelectionSuspension) {
        switch suspension {
            case .notAssigned:
                self = .notAssigned
            case .noEligibleTarget:
                self = .noEligibleTarget
            case .explicitSelectionRequired(let candidates):
                self = .explicitSelectionRequired(candidates: candidates)
            case .modalBlock(let modal, let blocked):
                self = .modalBlock(modal: modal, blocked: blocked)
            case .modalRelationInDoubt(let doubt):
                self = .modalRelationInDoubt(detail: String(describing: doubt))
            case .visibilityUncertain(let surface):
                self = .visibilityUncertain(surface)
            case .selectedSurfaceAbsent(let surface):
                self = .selectedSurfaceAbsent(surface)
            case .selectedSurfaceNotVerified(let surface):
                self = .selectedSurfaceNotVerified(surface)
            case .containmentNotVerified(let blocks):
                self = .containmentNotVerified(blocks: blocks.map { String(describing: $0) })
            case .observationMissing:
                self = .observationMissing
            case .observationSuperseded(let observed, let current):
                self = .observationSuperseded(observed: observed, current: current)
            case .observationIdentityMismatch(let observed, let selected):
                self = .observationIdentityMismatch(observed: observed, selected: selected)
            case .observationGeometryStale(let surface):
                self = .observationGeometryStale(surface)
        }
    }
}
