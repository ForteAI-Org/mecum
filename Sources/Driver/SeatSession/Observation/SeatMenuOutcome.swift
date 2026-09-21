//
//  SeatMenuOutcome.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// SeatMenuCleanup is what happened when the kit closed the interaction it
/// opened. Closing is the kit's obligation and never the consumer's, so this is
/// reported on every path, including the ones that failed earlier.
nonisolated public enum SeatMenuCleanup: Sendable, Equatable {

    /// The menu is gone and the window server says so, with the lever that did
    /// it. A chosen item dismissing the menu is one of them.
    case verifiedClosed(ContextMenuReceipt.Closure)

    /// Every lever was pulled inside the cleanup budget and the menu is still
    /// there, or could not be read. It is an explicit failure with the input
    /// suspended, never a success: a modal loop left running inside another
    /// process is the worst outcome this path has.
    case notVerified(reason: String)
}

/// SeatMenuOutcome is the whole result of one scoped menu interaction.
///
/// ## Why the budgets are reported
///
/// The interaction has 180 s from the start of its opening, including the
/// captures, the waits and any Vision the consumer ran inside it, and nothing
/// renews it: not a submenu, not a new observation, not a late callback. Its
/// cleanup has a separate 2 s measured from the end, the error or the expiry.
/// `interactionExpired` says the first budget passed, which revokes the context
/// at once, and the cleanup still runs on its own budget afterwards.
///
/// ## What it does not claim
///
/// It does not claim the chosen item did anything inside the target: what a menu
/// command does is the consumer's question, answered on the consumer's next
/// observation. It does not claim that a cancelled Swift task ended a native
/// call either, which is why an unverified close is reported rather than
/// assumed.
nonisolated public struct SeatMenuOutcome: Sendable, Equatable {

    /// The menu the window server showed, with how long after the opening click
    /// it appeared.
    public let menu: ContextMenu

    /// The Receipt of the click that opened it. Delivery, never effect.
    public let opening: InputReceipt

    /// Every Receipt the interaction posted inside the menu, in order. They are
    /// preserved when a later one is refused: what went out, went out.
    public let insideMenu: [InputReceipt]

    /// True when the 180 s budget passed before the interaction ended. The
    /// context was revoked at that moment and no semantic Command was admitted
    /// afterwards.
    public let interactionExpired: Bool

    public let cleanup: SeatMenuCleanup

    package init(
        menu              : ContextMenu,
        opening           : InputReceipt,
        insideMenu        : [InputReceipt],
        interactionExpired: Bool,
        cleanup           : SeatMenuCleanup
    ) {
        self.menu               = menu
        self.opening            = opening
        self.insideMenu         = insideMenu
        self.interactionExpired = interactionExpired
        self.cleanup            = cleanup
    }
}
