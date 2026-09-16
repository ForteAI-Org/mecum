//
//  ObservedWindow.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore

/// ObservedWindow is one out of process reading of a window: its
/// identity, its geometry and the accessibility hierarchy behind it, reduced to
/// value types the caller can keep.
///
/// It reads and returns, nothing more. There is no element list here and no
/// action: which nodes are candidates, what each one accepts and what any of it
/// means are the caller's, derived from the role. The kit's own actuation takes
/// a `WindowReference` and a point, and no Facility can reach this type.
nonisolated public struct ObservedWindow: Sendable {

    public let processID          : Int32
    public let applicationName    : String
    public let windowTitle        : String
    public let windowNumber       : Int
    public let windowFrame        : CGRect
    public let windowOrder        : Int?
    public let applicationIsActive: Bool
    public let windowIsFocused    : Bool

    /// The WindowServer-attested identity that turns this observation into an
    /// input reference. It is nil only on values built through the compatibility
    /// initializer rather than returned by `WindowReader`.
    public let windowIdentity     : WindowIdentity?

    /// Identity, server geometry, display scale and local observation version
    /// read with this snapshot. It is nil on compatibility values, whenever
    /// AX and WindowServer disagree on the frame, or when the window spans
    /// displays, so those values cannot authorize coordinates.
    public let geometryObservation: WindowGeometryObservation?

    /// The whole hierarchy, flat and in the order it was walked:
    /// `parentNodeID` rebuilds the shape.
    public let axTree            : [AXElementNode]

    /// Whether an acquisition limit cut the walk short. A truncated reading
    /// answers fewer questions than a complete one, and the difference matters
    /// to whoever plans on it.
    public let axTreeWasTruncated: Bool

    /// A fingerprint of the whole tree: it changes when any part of the window
    /// changes state, including when the node that was acted on exposes no
    /// value of its own.
    public let signature         : Int

    /// Why the walk stopped early, when it did.
    public let axTreeLimitReason : String?

    public init(
        processID          : Int32,
        applicationName    : String,
        windowTitle        : String,
        windowNumber       : Int,
        windowFrame        : CGRect,
        windowOrder        : Int?,
        applicationIsActive: Bool,
        windowIsFocused    : Bool,
        axTree             : [AXElementNode],
        axTreeWasTruncated : Bool,
        signature          : Int,
        axTreeLimitReason  : String? = nil,
        windowIdentity     : WindowIdentity? = nil,
        geometryObservation: WindowGeometryObservation? = nil
    ) {
        self.processID           = processID
        self.applicationName     = applicationName
        self.windowTitle         = windowTitle
        self.windowNumber        = windowNumber
        self.windowFrame         = windowFrame
        self.windowOrder         = windowOrder
        self.applicationIsActive = applicationIsActive
        self.windowIsFocused     = windowIsFocused
        self.windowIdentity      = windowIdentity
        self.geometryObservation = geometryObservation
        self.axTree              = axTree
        self.axTreeWasTruncated  = axTreeWasTruncated
        self.signature           = signature
        self.axTreeLimitReason   = axTreeLimitReason
    }

    /// The coordinate-driver reference for this observation. A value returned
    /// by `WindowReader` is attested; a manually constructed legacy observation
    /// remains unverified and the driver will refuse it.
    public var reference: WindowReference {
        guard let windowIdentity else {
            return WindowReference(
                processID   : processID,
                windowNumber: windowNumber,
                frame       : windowFrame
            )
        }
        return WindowReference(identity: windowIdentity, frame: windowFrame)
    }

    /// The window local point, measured from the top left corner, of a point on
    /// screen: the second half of what an `InputLocation` carries.
    public func pointInWindowFromTop(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - windowFrame.minX,
            y: screenPoint.y - windowFrame.minY
        )
    }
}

/// AXElementNode is one node of an observed hierarchy, flat and serializable.
///
/// Every field is something accessibility answered. Nothing here is a verdict:
/// no category, no list of actions, no "this one is a candidate", because all
/// three are read off the role and reading the role is where the kit stops. It
/// holds no `AXUIElement`, so a caller can keep a whole tree without keeping
/// the target's accessibility handles alive.
nonisolated public struct AXElementNode: Sendable {

    public let nodeID           : Int
    public let parentNodeID     : Int?
    public let depth            : Int
    public let role             : String
    public let title            : String
    public let description      : String
    public let value            : String
    public let help             : String
    public let placeholder      : String
    public let identifier       : String
    public let frame            : CGRect?
    public let isEnabled        : Bool?
    public let isSelected       : Bool?
    public let isExpanded       : Bool?
    public let isFocused        : Bool?
    public let selectedText     : String

    /// The node's own selected range, when it tracks one. `nil` is the answer
    /// for every node that is not text: it is not the same as an empty range.
    public let selectedRange    : NSRange?

    /// Where the node's text begins and ends, for a node that can say where its
    /// own characters are. Both are `nil` when it cannot, and both are read
    /// (`AXBoundsForRange`), never guessed from the frame.
    public let textStartPoint   : CGPoint?
    public let textEndPoint     : CGPoint?

    /// Attributes the provider answered an error for while still exposing role,
    /// children and value. Reported, because a partial read is not a lost
    /// subtree and the difference matters to whoever plans on it.
    public let attributeWarnings: [String]

    public init(
        nodeID           : Int,
        parentNodeID     : Int?,
        depth            : Int,
        role             : String,
        title            : String    = "",
        description      : String    = "",
        value            : String    = "",
        help             : String    = "",
        placeholder      : String    = "",
        identifier       : String    = "",
        frame            : CGRect?   = nil,
        isEnabled        : Bool?     = nil,
        isSelected       : Bool?     = nil,
        isExpanded       : Bool?     = nil,
        isFocused        : Bool?     = nil,
        selectedText     : String    = "",
        selectedRange    : NSRange?  = nil,
        textStartPoint   : CGPoint?  = nil,
        textEndPoint     : CGPoint?  = nil,
        attributeWarnings: [String]  = []
    ) {
        self.nodeID            = nodeID
        self.parentNodeID      = parentNodeID
        self.depth             = depth
        self.role              = role
        self.title             = title
        self.description       = description
        self.value             = value
        self.help              = help
        self.placeholder       = placeholder
        self.identifier        = identifier
        self.frame             = frame
        self.isEnabled         = isEnabled
        self.isSelected        = isSelected
        self.isExpanded        = isExpanded
        self.isFocused         = isFocused
        self.selectedText      = selectedText
        self.selectedRange     = selectedRange
        self.textStartPoint    = textStartPoint
        self.textEndPoint      = textEndPoint
        self.attributeWarnings = attributeWarnings
    }

    /// The role without its `AX` prefix, for a caller that prints it.
    public var readableRole: String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}
