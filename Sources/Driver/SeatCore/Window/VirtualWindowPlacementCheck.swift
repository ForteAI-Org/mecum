//
//  VirtualWindowPlacementCheck.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// PlacementFailure is one reason a window is not correctly placed on the
/// virtual display. The set is deliberately fine grained: "the window moved"
/// and "the two readings disagree" are answered differently, and a report that
/// only knew "placement rejected" could not tell them apart.
public enum PlacementFailure: String, Sendable, Equatable {

    /// The observed reading no longer names the original process and Window ID.
    case identityChanged

    /// The observed frame is not entirely inside the virtual display.
    case frameOutsideDisplay

    /// The window's original size was not preserved by the move.
    case sizeChanged

    /// The window server does not confirm the original process and Window ID.
    case windowServerIdentityChanged

    /// The window server frame is not entirely inside the virtual display.
    case windowServerFrameOutsideDisplay

    /// The observed frame and the window server frame do not agree.
    case readingsDisagree

    /// No window server geometry is available for the Window ID.
    case windowServerReadingMissing

    /// The target application became active.
    case targetActivated

    /// The target application is frontmost in the User Seat.
    case targetFrontmost

    /// The person's frontmost application is not the one the placement started
    /// with.
    case userApplicationChanged

    /// The target window is not behind the person's application.
    case targetNotBehindUserApp
}

/// VirtualWindowPlacementCheck decides whether a window really is where the
/// seat put it. It compares identity, geometry and the User Seat, and it takes
/// two independent readings, the consumer's observation and the window server,
/// because one of them alone is not evidence: applications update their own
/// geometry and the window server's at different moments.
///
/// It knows nothing about the window's contents. The number and order of a
/// window's controls change during layout and used to produce false negatives,
/// so the check never looks at them.
public enum VirtualWindowPlacementCheck {

    /// The tolerance for a placement comparison. Larger than the 0.5 pt used
    /// for a stability reading: a move through the accessibility API lands on
    /// integral points, and the window server rounds.
    public static let placementTolerance: CGFloat = 2

    /// failures returns every reason the placement is not acceptable, empty
    /// when it is. `allowsUserActivity` relaxes only the User Seat rules, for a
    /// loop that runs while the person keeps working: it never relaxes identity
    /// or geometry.
    public static func failures(
        original          : WindowReference,
        current           : WindowReference,
        currentIsActive   : Bool = false,
        server            : WindowReference?,
        displayBounds     : CGRect,
        expectedUserPID   : Int32?,
        currentUserPID    : Int32?,
        targetBehindUser  : Bool?,
        allowsUserActivity: Bool = false
    ) -> [PlacementFailure] {
        var failures: [PlacementFailure] = []
        if !current.hasSameIdentity(as: original) {
            failures.append(.identityChanged)
        }
        if !rectangleIsUsable(current.frame) || !rectangleIsUsable(displayBounds)
            || !displayBounds.contains(current.frame) {
            failures.append(.frameOutsideDisplay)
        }
        if !rectangleIsUsable(original.frame)
            || abs(current.frame.width  - original.frame.width)  > placementTolerance
            || abs(current.frame.height - original.frame.height) > placementTolerance {
            failures.append(.sizeChanged)
        }
        if let server {
            if !server.hasSameIdentity(as: original) {
                failures.append(.windowServerIdentityChanged)
            }
            if !rectangleIsUsable(server.frame) || !rectangleIsUsable(displayBounds)
                || !displayBounds.contains(server.frame) {
                failures.append(.windowServerFrameOutsideDisplay)
            }
            if !framesMatch(current.frame, server.frame) {
                failures.append(.readingsDisagree)
            }
        } else {
            failures.append(.windowServerReadingMissing)
        }
        if currentIsActive {
            failures.append(.targetActivated)
        }
        if currentUserPID == original.processID {
            failures.append(.targetFrontmost)
        } else if !allowsUserActivity && (expectedUserPID == nil || currentUserPID != expectedUserPID) {
            failures.append(.userApplicationChanged)
        }
        // The global window order spans displays and changes with Stage
        // Manager. Inside the loop, containment on the virtual display counts.
        if !allowsUserActivity && targetBehindUser != true {
            failures.append(.targetNotBehindUserApp)
        }
        return failures
    }

    /// framesMatch is the placement comparison: both rectangles must be usable
    /// readings and agree within `placementTolerance`. Two readings taken while
    /// the window is moving do not match, which is the point.
    public static func framesMatch(
        _ lhs    : CGRect,
        _ rhs    : CGRect,
        tolerance: CGFloat = placementTolerance
    ) -> Bool {
        rectangleIsUsable(lhs) && rectangleIsUsable(rhs)
            && rectanglesMatch(lhs, rhs, tolerance: tolerance)
    }
}
