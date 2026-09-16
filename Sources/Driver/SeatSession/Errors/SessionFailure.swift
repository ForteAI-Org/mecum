//
//  SessionFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
import SeatCore

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
}
