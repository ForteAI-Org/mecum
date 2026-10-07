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
                self = .containmentNotVerified(blocks: blocks.map(\.clause))
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

nonisolated private extension ContainmentBlock {

    /// The block as a clause a person can act on. It used to be the case and
    /// its payload as Swift prints them, which reached the agent as
    /// "surfaceOutsideSeat(windowNumber: 38030)" for a dialog left open on the
    /// person's screen, and the agent read that as a missing capability.
    var clause: String {
        switch self {
            case .notAssigned:
                "no application is assigned"
            case .readingUnavailable(let reason):
                "the application's windows could not be read (\(reason))"
            case .inventoryNotQualified(let reason):
                "the reading may not list every window of the application (\(reason))"
            case .attributionUncertain(let number, let doubt):
                "window \(number) may belong to the application and could not be attributed: "
                    + doubt.clause
            case .surfaceUnverified(let number):
                "window \(number) was seen once and no second reading confirmed it yet"
            case .surfaceOutsideSeat(let number):
                "window \(number) of the application is open on the person's screen, outside the "
                    + "seat, until the seat takes it in"
            case .surfaceAbsent(let number):
                "window \(number) was not in the last reading"
            case .attemptSpent(let number):
                "the one attempt to move window \(number) into the seat has been used"
            case .effectRefused(let number, let refusal):
                "window \(number) could not be moved into the seat: " + refusal.clause
            case .destinationUnusable(let number):
                "there is no place inside the seat for window \(number)"
            case .surfaceDeadlineExpired(let number, let elapsed):
                "window \(number) was not contained within \(Self.seconds(elapsed)) s"
            case .handoverDeadlineExpired(let elapsed):
                "the application's windows were not all contained within \(Self.seconds(elapsed)) s "
                    + "of the handover"
            case .surfaceStalled(let number, let total, let qualified):
                "window \(number) has waited \(Self.seconds(total)) s, of which only "
                    + "\(Self.seconds(qualified)) s could be read"
            case .handoverStalled(let total, let qualified):
                "the handover has waited \(Self.seconds(total)) s, of which only "
                    + "\(Self.seconds(qualified)) s could be read"
        }
    }

    /// Nanoseconds as seconds to one decimal.
    static func seconds(_ nanoseconds: UInt64) -> Double {
        (Double(nanoseconds) / 100_000_000).rounded() / 10
    }
}

nonisolated private extension AttributionDoubt {

    var clause: String {
        switch self {
            case .identityNotAttested          : "it has no attested window identity"
            case .relationNotVerifiable        : "its relation rests on evidence that cannot carry it"
            case .sharedServiceSurfaceNotNamed : "it belongs to a shared service that did not name it"
        }
    }
}

nonisolated private extension EffectRefusal {

    var clause: String {
        switch self {
            case .adapterNotQualified          : "no way to move it is qualified on this build"
            case .surfaceNotAttributed         : "it is not attributed to the application"
            case .destinationUnusable(let why) : "there is no place for it (\(why))"
            case .identityNotAttested          : "its identity is not attested"
        }
    }
}
