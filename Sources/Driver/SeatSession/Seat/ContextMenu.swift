//
//  ContextMenu.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// ContextMenu is the menu the window server saw open: its own window, owned by
/// the target process, drawn at the pop up menu level, on screen.
///
/// It is a window and not a list of items, and that is the honest shape rather
/// than a limitation of this type. A contextual menu is absent from the
/// target's accessibility tree while it is up, so what the seat can prove
/// exists is a rectangle at a level, and reading what is written inside it is a
/// separate question with a separate answer per family: `TargetReader` answers
/// it for AppKit and says plainly that it cannot for Chromium.
///
/// The frame is the window server's, because a menu window has no other
/// reading: the target publishes nothing about it and no element describes it.
public struct ContextMenu: Sendable, Equatable {

    /// The **menu's** window, not the target's: same process, its own Window ID,
    /// and the identity an event has to be routed to in order to land on an
    /// item.
    public let window: WindowReference

    /// How long after the right click went out the window server first showed
    /// it. Measured between 43 and 97 ms on a native target and about 314 ms on
    /// a browser, which is why the deadline is not tight.
    public let appearedAfter: Duration

    /// Where the menu is drawn, in Quartz coordinates.
    public var frame: CGRect { window.frame }

    public init(window: WindowReference, appearedAfter: Duration) {
        self.window        = window
        self.appearedAfter = appearedAfter
    }
}

/// ContextMenuReceipt is what one whole menu interaction did: the click that
/// opened it, the click that chose inside it, and **how it was closed**, which
/// is the field this type exists for.
///
/// There is no case in which a menu was left open: that outcome is a thrown
/// `SessionFailure.contextMenuNotClosed` and a `SeatIssue.contextMenuLeftOpen`,
/// never a receipt somebody might not read.
public struct ContextMenuReceipt: Sendable, Equatable {

    /// Which of the three things ended the menu.
    public enum Closure: String, Sendable, Equatable {

        /// The item click closed it, which is what choosing an item does.
        case chosenItem

        /// It was gone before any lever was pulled and no item had been chosen,
        /// so the target dismissed it on its own. It is a real ending and not a
        /// tidy name for an unknown one: an application switch does exactly
        /// this, and so does a target that decided its menu was stale.
        case dismissedItself

        /// The Preparation cycle closed it: applied and restored with no event
        /// in between, and it is the restore that does it. 50 ms measured.
        case preparationCycle

        /// The second net. An Escape routed to the process, which reaches
        /// whatever holds the key inside it, and while a menu is tracking that
        /// is the menu.
        case escapeKey
    }

    public let menu       : ContextMenu
    public let opening    : InputReceipt
    public let chosenPoint: CGPoint?
    public let choosing   : InputReceipt?
    public let closedBy   : Closure

    public init(
        menu       : ContextMenu,
        opening    : InputReceipt,
        chosenPoint: CGPoint?,
        choosing   : InputReceipt?,
        closedBy   : Closure
    ) {
        self.menu        = menu
        self.opening     = opening
        self.chosenPoint = chosenPoint
        self.choosing    = choosing
        self.closedBy    = closedBy
    }
}
