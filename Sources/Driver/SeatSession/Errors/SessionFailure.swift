//
//  SessionFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
import SeatCore

/// AssignmentUse is what the seat is in the middle of when a handback of the
/// Assigned Application is refused. Every case is transient: the consumer waits
/// for the thing named to finish and asks again.
///
/// It is the window follow pass's stand down list minus the reasons that belong
/// to the follower. Ending an assignment underneath a Command is the same class
/// of hazard as moving a window underneath one, so the same facts refuse. The
/// person's own recent intent is not in it, because a handback moves nothing and
/// reads nothing of theirs. A contextual menu interaction is not in it either:
/// one is only ever opened under a Turn, and `turnHeld` is what answers while
/// that Turn is out.
nonisolated public enum AssignmentUse: String, Sendable, Equatable {

    /// The seat is being torn down, and the teardown ends the assignment itself.
    case seatTearingDown

    /// A Command is in flight. It is named before `turnHeld` because it is the
    /// more precise of the two facts about the same hold.
    case commandInFlight

    /// A Turn is out. The holder gives the seat back first: an assignment ended
    /// underneath a hold would leave that holder with input authority revoked
    /// halfway through its own exclusive use.
    case turnHeld

    /// An adoption is in flight, so a window of the instance is on its way in.
    case adoptionInFlight

    /// A window transfer is in flight, so a window is between two frames.
    case windowTransferInFlight

    /// A focus restore was requested and not yet verified.
    case focusRecoveryRestoring
}

/// SessionFailure is how `SeatHost` and `AgentSeat` refuse. Structured cases
/// with the fields a report needs, no prose: the sentence for the person is the
/// consumer's, and the consumer is the one that knows the language.
///
/// A `SeatIssue` is not in here on purpose. An Issue is something detected
/// about the seat and it travels on the event stream and inside
/// `SeatInterruption`; a `SessionFailure` is a refusal of something the caller
/// asked for.
nonisolated public enum SessionFailure: Error, Sendable, Equatable {

    /// A Command was sent without holding the seat.
    case turnRequired

    /// The seat is not in a state that accepts Commands. There is no queue
    /// inside `send`: waiting would post events against coordinates taken
    /// before the wait, so the answer is the state and the caller decides.
    case seatNotReady(SeatState)

    /// The host already has its seat. v1 is one seat per host and one host per
    /// process; the model admits `n` and this is where that shows.
    case seatLimitReached

    /// The host is not in a state that can create or run a seat.
    case hostNotReady(SeatHostState)

    /// `release` was asked for a Turn that is not the one out.
    case turnNotHeld(generation: UInt64)

    /// `release` was refused because Commands posted under this Turn are still
    /// unconfirmed. This is the anti-replay invariant at the safe point: an
    /// unconfirmed Command is `unknown`, and handing the seat to the next
    /// holder with an `unknown` in the past would let it act on a state nobody
    /// established.
    case unconfirmedCommands(count: Int)

    /// `release` was refused because this Turn is still holding keys down on a
    /// target process. It is the same invariant one step further: a held key is
    /// real state inside somebody else's application, and handing the seat to
    /// the next holder with a key still down would make that key the next
    /// holder's problem without the next holder ever knowing.
    ///
    /// The holder releases what it pressed and calls `release` again. The kit
    /// does not post the missing key ups itself, for the same reason it never
    /// replays a Command: what to release and in what order is the holder's
    /// knowledge, not a guess the seat can make safely.
    case keysStillHeld(count: Int)

    /// `confirm` was given a Receipt that is not the oldest unconfirmed one.
    ///
    /// A Turn is exclusive, so the Commands under it are strictly ordered and
    /// so are their confirmations. Out of order means the caller lost track of
    /// which Command it is answering about, and guessing which one it meant is
    /// exactly how an effect gets attributed to the wrong action.
    case receiptOutOfOrder

    /// `confirm` was given a Receipt with nothing pending.
    case nothingToConfirm

    /// The window is not one this seat adopted.
    case windowNotAdopted(windowNumber: Int)

    /// `releaseAssignedApplication` was asked for while nothing was assigned.
    ///
    /// A second handback is a refusal and not a silent success, for the same
    /// reason `AssignmentLifecycle.release` answers nil rather than nothing: a
    /// consumer that believes it gave an application back has to be told when it
    /// did not, and a seat that was never entrusted with one has nothing to give.
    case applicationNotAssigned

    /// `releaseAssignedApplication` was refused because the seat is in the
    /// middle of something the assignment is the authority for.
    case assignmentStillInUse(AssignmentUse)

    /// `releaseAssignedApplication` was refused because a return owed by an
    /// earlier assignment is still unverified. It is
    /// `SeatCoherentState.outstandingReturns` read as a refusal.
    ///
    /// Stacking a second obligation on the first would bury it: the pending
    /// surfaces are held by Window ID, and a number the window server handed out
    /// again keeps the older entry rather than replacing it. So the older
    /// obligation is finished first.
    case returnsStillOutstanding(windowNumbers: [Int])

    /// `releaseAssignedApplication` was refused because the seat still holds
    /// windows of the assigned instance: its own Adopted Windows, a failed move
    /// whose restoration is still owed, or a surface the assignment still counts
    /// as a member.
    ///
    /// Giving the application back first would strand them. The assignment is
    /// what entrusts their return, and the return obligation a handback leaves
    /// behind cannot be completed after the assignment has ended. So the
    /// consumer releases each window with `release(_:_:)` and asks again.
    case assignedWindowsStillHeld(windowNumbers: [Int])

    /// A wait that needs the caller to be turning its own AppKit event loop
    /// ran out of time. A virtual display only makes progress while
    /// `NSApplication` pumps (ADR 0007), so a caller that cannot pump gets a
    /// named timeout instead of a display that never appears.
    case pumpTimedOut(seconds: Double)

    /// The host's start could not bring both the display and the fence up, and
    /// took back whatever came up. The step is atomic by contract.
    case startNotAtomic(SeatIssue)

    /// A contextual menu of the target is already on screen, so the right click
    /// was not posted. It would have reached the open menu's tracking loop
    /// instead of the view, and the menu that answered would not be the one
    /// this call opened.
    case contextMenuAlreadyOpen(processID: Int32)

    /// The right click went out and the window server never showed a menu
    /// window of the target inside the deadline. Nothing is retried and nothing
    /// is assumed: an action that cannot see its own menu has no menu.
    case contextMenuNeverOpened(windowNumber: Int, within: Duration)

    /// **The loudest failure the seat has.** A contextual menu the kit opened
    /// is still on screen after the Preparation cycle and after an Escape, so
    /// somebody else's application is left running a modal tracking loop that
    /// the person did not ask for and cannot see the cause of. It arrives on
    /// the event stream too, as `SeatIssue.contextMenuLeftOpen`.
    case contextMenuNotClosed(menuWindowNumber: Int, processID: Int32)

    /// The window is in native macOS fullscreen and this host was not
    /// configured to transfer one. It is the default: the experiment is opt in,
    /// and the ordinary path is left exactly as it was before MW-03.
    ///
    /// Not a degradation and not a retry: a caller that wants this behaviour
    /// turns `transfersFullScreenWindows` on and reads what it costs.
    case fullScreenTransferDisabled(windowNumber: Int)

    /// Nothing the seat has established says what draws the surface this
    /// Command is addressed to, so no measured recipe covers it and nothing was
    /// posted. It is the explicit `unknown` of `SurfaceInputClassification`,
    /// and it exists because the alternative was a universal default that
    /// addressed a native panel's recipe to a web view and the other way round.
    case surfaceFamilyUnclassified(windowNumber: Int)

    /// The window is larger than the Virtual Display and the adaptation that
    /// would make it fit did not take: the application either refused the size
    /// or has a minimum of its own above the display. It is the one refusal
    /// left after the seat has tried, and it names both sizes because what a
    /// caller does about it depends on the difference.
    ///
    /// What the window is owed is unaffected: nothing was recorded, and a
    /// window whose adaptation did take is adopted at the new size and still
    /// returned to the frame it was found at.
    case windowDoesNotFit(windowNumber: Int, size: CGSize, bounds: CGSize)
}
