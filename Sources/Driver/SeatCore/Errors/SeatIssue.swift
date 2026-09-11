//
//  SeatIssue.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SeatIssue is a detected anomaly during a seat operation. A critical Issue
/// stops what it owns; a recoverable one suspends the work and retries inside a
/// bounded budget. The cases carry no prose: the consumer writes the sentence,
/// the kit reports the field.
public enum SeatIssue: String, Sendable, Equatable, CaseIterable {

    /// The seat's display, or the physical topology around it, is no longer the
    /// one the coordinates were taken in.
    case displayChanged

    /// The HID cursor fence is not active, so the physical cursor is no longer
    /// confined to the person's displays.
    case fenceUnavailable

    /// The target process is gone.
    case processUnavailable

    /// Process or Window ID of the target changed: a Window ID can be reused by
    /// another process, so identity is never one field alone.
    case identityChanged

    /// The target application became active in the User Seat. The person's
    /// choice wins: the seat waits instead of taking focus back.
    case targetActivated

    /// The target window is temporarily unreadable. Common during a Space or
    /// Stage Manager transition, hence recoverable.
    case windowUnavailable

    /// The target window was moved or resized, so the local points computed for
    /// it no longer land where they were meant to.
    case geometryChanged

    /// Two readings of the same window disagree and have to be reconfirmed
    /// before anything is posted.
    case snapshotChanged

    /// The physical cursor moved in a way the observed physical input does not
    /// explain.
    case cursorInterference

    /// An input was posted and its effect could not be established. It is never
    /// repeated: repeating it could duplicate a real action.
    case ambiguousEffect

    /// Recovery did not restore the seat inside its budget.
    case recoveryExhausted

    /// The preview stream of the virtual display is unavailable. The seat keeps
    /// working: only the human's view of it is missing.
    case monitorUnavailable

    /// Bringing the window on stage failed, so it stays a Stage Manager
    /// thumbnail and no input is sent to it.
    case windowStashed

    /// The Preparation was applied and the target refused to have it undone, so
    /// a window the person did not choose is left believing it is active and
    /// key inside its own process.
    ///
    /// It is reported and never thrown. The Command's events did go out, and
    /// handing the caller an error for a Command that was delivered is exactly
    /// how an action gets replayed twice, which is why a restore that fails is an
    /// Issue and not a thrown error. The next Preparation on that window resets
    /// the state, so the seat stays usable and only says it is degraded.
    case preparationNotRestored

    /// A contextual menu the kit opened in the target is still on screen after
    /// both of the levers that close one.
    ///
    /// Critical, and of everything the kit can leave behind it is the worst: an
    /// open menu is a modal tracking loop **inside somebody else's process**, so
    /// that application stops running its own loop until a person dismisses the
    /// menu by hand, and the person has no way of knowing where it came from.
    case contextMenuLeftOpen

    /// A critical Issue is terminal for its level; a recoverable one is
    /// answered by suspending or by a bounded recovery.
    public var isCritical: Bool {

        switch self {
            case .targetActivated, .windowUnavailable, .geometryChanged,
                 .snapshotChanged, .monitorUnavailable, .windowStashed,
                 .preparationNotRestored:
                false

            default: true
        }

    }

    /// Whose invariant the Issue broke. Section 5 of the spec derives the state
    /// transitions from this pair of properties and nothing else.
    public var level: SeatIssueLevel {
        
        switch self {
            case .displayChanged, .fenceUnavailable, .monitorUnavailable: .host
            case .windowStashed:                                          .window
            default:                                                      .seat
        }
        
    }
}
