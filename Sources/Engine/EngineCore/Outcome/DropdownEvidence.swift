//
//  DropdownEvidence.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import PerceptionCore

/// DropdownEvidence is what one dropdown selection proved, as values a higher layer compares
/// instead of parsing the outcome's sentence: the control it resolved, the value read there
/// before the menu opened, the item requested, the value read there after the menu closed, and
/// the application and window it happened in.
///
/// It exists only once an item was chosen in the menu and the menu closed. It holds no image,
/// coordinate, or session, process, or window number, so every field describes the application
/// rather than this run of it. `bundleID` is the application's own identifier; a caller that only
/// has a process fallback does not attach evidence.
public struct DropdownEvidence: Sendable, Equatable, Codable {

    /// The application's bundle identifier.
    public let bundleID: String

    /// The title of the adopted window the control belongs to, as the Seat reports it.
    public let windowTitle: String

    /// The label of the control the request resolved to, as read before the menu opened.
    public let control: String

    /// The control's accessibility role when one was known.
    public let controlRole: String?

    /// The scene section holding the control when the scene named one.
    public let section: String?

    /// The control's value before the menu opened. A dropdown read from pixels displays its value
    /// as its label, so this equals `control` unless the scene carried a separate value.
    public let valueBefore: String

    /// The item the caller asked for.
    public let requestedItem: String

    /// The value read back at the control after the menu closed.
    public let readback: DropdownReadback

    /// Whether choosing the item is what closed the menu, rather than a dismissal the Seat
    /// forced or the application performed on its own. The readback, not this, proves the value.
    public let menuClosedByChoice: Bool

    public init(
        bundleID          : String,
        windowTitle       : String,
        control           : String,
        controlRole       : String?,
        section           : String?,
        valueBefore       : String,
        requestedItem     : String,
        readback          : DropdownReadback,
        menuClosedByChoice: Bool
    ) {
        self.bundleID           = bundleID
        self.windowTitle        = windowTitle
        self.control            = control
        self.controlRole        = controlRole
        self.section            = section
        self.valueBefore        = valueBefore
        self.requestedItem      = requestedItem
        self.readback           = readback
        self.menuClosedByChoice = menuClosedByChoice
    }

    /// Change is what the selection did to the control's value.
    public enum Change: String, Sendable, Equatable, Codable {
        /// The control read another value before and reads the requested item after.
        case changed
        /// The control already read the requested item before; it still does. Nothing changed.
        case alreadySet
        /// The after-close reading does not show the requested item.
        case unverified
    }

    /// What the selection did, from the before value and the readback alone.
    public var change: Change {
        guard isVerified else { return .unverified }
        return LabelText.normalize(valueBefore) == LabelText.normalize(requestedItem) ? .alreadySet : .changed
    }

    /// Whether the control reads the requested item after the menu closed.
    public var isVerified: Bool { readback.reads(requestedItem) }
}
