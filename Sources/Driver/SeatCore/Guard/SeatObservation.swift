//
//  SeatObservation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// SeatObservation is what the seat saw around one action: what changed in the
/// User Seat while the Command was in flight. It is evidence, not a verdict.
/// A frontmost change does not prove who caused it, so the kit hands the
/// consumer the fields and attributes nothing.
///
/// The seat fills this in; a driver that only posts events returns `nil` rather
/// than an observation it never made.
public struct SeatObservation: Sendable, Equatable {

    /// The person's frontmost application changed during the action.
    public let frontmostApplicationChanged: Bool

    /// The active Space changed during the action.
    public let activeSpaceChanged: Bool

    /// The main display changed during the action, which invalidates every
    /// Quartz coordinate taken before it.
    public let mainDisplayChanged: Bool

    /// The largest distance the physical cursor moved from its baseline while
    /// the action ran.
    public let maximumCursorDistance: CGFloat

    /// The global window order changed. Stage Manager alone changes it, so this
    /// is diagnostic rather than an anomaly.
    public let windowOrderChanged: Bool

    /// The target window came in front of the person's application, which the
    /// seat must never cause.
    public let targetMovedAheadOfUserApp: Bool

    /// The cursor audit for the action's marker, when one was running.
    public let cursorAudit: CursorMotionAudit.Result?

    public init(
        frontmostApplicationChanged: Bool = false,
        activeSpaceChanged         : Bool = false,
        mainDisplayChanged         : Bool = false,
        maximumCursorDistance      : CGFloat = 0,
        windowOrderChanged         : Bool = false,
        targetMovedAheadOfUserApp  : Bool = false,
        cursorAudit                : CursorMotionAudit.Result? = nil
    ) {
        self.frontmostApplicationChanged = frontmostApplicationChanged
        self.activeSpaceChanged          = activeSpaceChanged
        self.mainDisplayChanged          = mainDisplayChanged
        self.maximumCursorDistance       = maximumCursorDistance
        self.windowOrderChanged          = windowOrderChanged
        self.targetMovedAheadOfUserApp   = targetMovedAheadOfUserApp
        self.cursorAudit                 = cursorAudit
    }

    /// merging joins two observations of the same interval, which a consumer
    /// that sent several Commands under one hold needs in order to judge the
    /// whole action instead of only its last Command.
    ///
    /// Every flag is a "something happened" and joins with `or`; the distance
    /// takes the larger. The audit is the exception and takes the **worse** of
    /// the two: an audit that failed is the answer for the interval, and one
    /// that passed cannot un-fail it.
    public func merging(_ other: SeatObservation) -> SeatObservation {
        SeatObservation(
            frontmostApplicationChanged: frontmostApplicationChanged || other.frontmostApplicationChanged,
            activeSpaceChanged         : activeSpaceChanged          || other.activeSpaceChanged,
            mainDisplayChanged         : mainDisplayChanged          || other.mainDisplayChanged,
            maximumCursorDistance      : max(maximumCursorDistance, other.maximumCursorDistance),
            windowOrderChanged         : windowOrderChanged          || other.windowOrderChanged,
            targetMovedAheadOfUserApp  : targetMovedAheadOfUserApp   || other.targetMovedAheadOfUserApp,
            cursorAudit                : Self.worseAudit(cursorAudit, other.cursorAudit)
        )
    }

    /// The audit that decides the interval: a failing one wins over a passing
    /// one, and a present one wins over none.
    private static func worseAudit(
        _ lhs: CursorMotionAudit.Result?,
        _ rhs: CursorMotionAudit.Result?
    ) -> CursorMotionAudit.Result? {

        switch (lhs, rhs) {
            case (nil, nil):              nil
            case (let left?, nil):        left
            case (nil, let right?):       right
            case (let left?, let right?): left.passed ? right : left
        }

    }
}
