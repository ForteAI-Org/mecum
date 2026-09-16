//
//  ObservedContextMenu.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import Foundation

/// ObservedContextMenu is what a reading of an open contextual menu found, and
/// its three cases are three different facts rather than three shades of empty.
///
/// The distinction is the whole point of the type. A menu whose items can be
/// read and a menu that is on the screen and unreadable are not the same
/// situation for a caller: the first can be chosen from by title, the second
/// can only be chosen from by geometry or by a capture of the pixels, and a
/// caller told "no items" would plan as if there were no menu.
nonisolated public enum ObservedContextMenu: Sendable, Equatable {

    /// The window server shows no menu window of this process. Nothing is open.
    case notOpen

    /// The menu's items, in the order the target lists them.
    ///
    /// This is the AppKit answer. An `NSMenu` opened as a contextual menu
    /// appears in the tree as an `AXMenu` child of the **window** element, not
    /// of the application element, which is where a menu bar's menus live and
    /// where an earlier reading of this package looked.
    case items([ObservedMenuItem])

    /// A menu of this process is open, the window server says where, and the
    /// target exposes nothing about it.
    ///
    /// This is the Chromium answer, and it is not a failure of the reader: a
    /// Chromium contextual menu is absent from the accessibility tree for the
    /// whole time its window is on the screen, so what the caller has is a
    /// rectangle it cannot read. Choosing inside it means geometry, or a
    /// capture of those pixels and a decision made on them. The payload is the
    /// rectangle, so the caller at least has that.
    case drawnOutsideTheAccessibilityTree(frame: CGRect)
}

/// ObservedMenuItem is one row of a menu the target does expose: what it says,
/// whether it can be chosen, and where it is drawn.
///
/// The frame is in Quartz coordinates, which is what a caller turning a title
/// into a click needs, and it is `nil` for an item whose element answers no
/// position, such as a separator.
nonisolated public struct ObservedMenuItem: Sendable, Equatable {

    public let title      : String
    public let isEnabled  : Bool
    public let isSelected : Bool

    /// True when the item opens a submenu of its own, which a caller has to
    /// know before it treats a click on it as a choice.
    public let hasSubmenu : Bool

    public let frame      : CGRect?

    public init(
        title     : String,
        isEnabled : Bool,
        isSelected: Bool,
        hasSubmenu: Bool,
        frame     : CGRect?
    ) {
        self.title      = title
        self.isEnabled  = isEnabled
        self.isSelected = isSelected
        self.hasSubmenu = hasSubmenu
        self.frame      = frame
    }
}
