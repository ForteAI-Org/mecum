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

    /// The tolerance for a placement comparison between two readings of the
    /// same window taken from the **same** source. Larger than the 0.5 pt used
    /// for a stability reading: a move through the accessibility API lands on
    /// integral points, and the window server rounds.
    ///
    /// It is the safety number: it answers "did the window move or resize
    /// under us between two readings", so it stays this tight. A comparison
    /// that spans two sources is a different question and takes
    /// `crossSourceTolerance`.
    public static let placementTolerance: CGFloat = 2

    /// The tolerance for a comparison between two readings of the same window
    /// taken from **different** sources: an application's own accessibility
    /// body against the window server's rectangle. It has to absorb a
    /// systematic per-application offset from shadows, frame insets and
    /// rounding, which `placementTolerance` must never absorb.
    ///
    /// Calibrated against one application's measured offset. MarkEdit, twice
    /// on two launches with different Window IDs, reports a body of 885 by 448
    /// pt where the window server publishes 888 by 448 at 2 pt less x: 3 pt of
    /// width, 2 pt of origin, 0 pt of height and y, bit-identical on both
    /// launches, so it is the offset and not a window that had not settled.
    /// 4 is that 3 plus the one point of window server rounding that already
    /// makes `placementTolerance` 2 instead of 0.5.
    ///
    /// A second application with a larger offset is not a reason to widen this
    /// again. It is a reason to record both frames at adoption and compare
    /// server with server, which is what `AgentSeat`'s return path now does
    /// and which needs no cross-source tolerance at all.
    public static let crossSourceTolerance: CGFloat = 4

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
            // The one comparison here that spans two sources: the observation
            // is the application's, the other reading is the server's.
            if !framesMatch(current.frame, server.frame, tolerance: crossSourceTolerance) {
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
    ///
    /// A caller comparing two sources passes `crossSourceTolerance` instead.
    /// The default is the same-source number on purpose: a site that needs the
    /// wider one has to say so and be classifiable by grep.
    public static func framesMatch(
        _ lhs    : CGRect,
        _ rhs    : CGRect,
        tolerance: CGFloat = placementTolerance
    ) -> Bool {
        rectangleIsUsable(lhs) && rectangleIsUsable(rhs)
            && rectanglesMatch(lhs, rhs, tolerance: tolerance)
    }

    /// sizesMatchAcrossSources answers one question and it is not "did the
    /// window resize": it is "is this the same window at full size, or a Stage
    /// Manager thumbnail", asked of a window server size against the size the
    /// application's own accessibility body reports.
    ///
    /// The thumbnail has no fixed size: measured at 90 by 97 points and, on
    /// Finder, at 120 by 121. Both readings are real and neither is a constant,
    /// which is exactly why the question is asked against the window's own size
    /// and never against a literal. At either reading an ordinary window leaves
    /// a factor of ten of headroom and `crossSourceTolerance` is nowhere near
    /// loose enough to confuse the two. It is the one place the kit compares
    /// two sources and cannot avoid it: a stashed window has no full-size
    /// window server reading to compare with, which is the whole reason it is
    /// being staged.
    public static func sizesMatchAcrossSources(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        framesMatch(
            CGRect(origin: .zero, size: lhs),
            CGRect(origin: .zero, size: rhs),
            tolerance: crossSourceTolerance
        )
    }

    /// The largest share of a window's own size a Stage Manager thumbnail is
    /// read at. Measured: a 1291 by 949 pt window published to the window
    /// server as 164 by 180, which is 13% of its width and 19% of its height,
    /// and thumbnails of 90 by 97 and 120 by 121 points on windows an order of
    /// magnitude larger. Half is far above every one of those readings and far
    /// below any resize a person performs, and it is a share rather than a
    /// number of points because the thumbnail has no fixed size.
    public static let thumbnailSizeShare: CGFloat = 0.5

    /// True when a window server size is the Stage Manager thumbnail of a
    /// window whose own size is `fullSize`, rather than the same window read at
    /// another size.
    ///
    /// The question `sizesMatchAcrossSources` answers is "is this the window at
    /// full size", and its negation used to be treated as "the window is
    /// stashed". They are not the same fact: a window a person resizes by 20 to
    /// 100 points is neither at the size the seat took it in at nor a
    /// thumbnail, and calling it stashed refused every Command on a window that
    /// was on stage the whole time. Being a thumbnail is a positive reading, so
    /// it is asked positively, and both dimensions have to shrink: a window
    /// that lost half its width alone is a window somebody resized.
    public static func sizeReadsAsThumbnail(_ serverSize: CGSize, fullSize: CGSize) -> Bool {
        guard rectangleIsUsable(CGRect(origin: .zero, size: serverSize)),
              rectangleIsUsable(CGRect(origin: .zero, size: fullSize)),
              fullSize.width > 0, fullSize.height > 0
        else { return false }
        return serverSize.width  <= fullSize.width  * thumbnailSizeShare
            && serverSize.height <= fullSize.height * thumbnailSizeShare
    }
}
