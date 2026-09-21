//
//  CaptureShapeStabilisation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/09/2026.
//

import CoreGraphics

/// The one rule that says when a running capture should be reshaped, and to
/// what. It is the policy `Monitor.followTargetShape` has always run, lifted
/// out of `MonitorConfiguration` so a consumer driving its own
/// `SeatCaptureStream` consumes the same rule instead of writing a second one.
///
/// It is deliberately about sizes alone: no stream, no quality rung, no
/// configuration. `MonitorConfiguration.following` adds the ladder's rebasing
/// on top of it, and a consumer with no ladder uses the answer as it is.
///
/// ## What the rule is
///
/// **Two agreeing readings are the settle budget.** A reading is the part of
/// the buffer the capture filled, taken on whatever beat the caller already
/// pays for, and one of them is never enough: a window moved onto the Virtual
/// Display is published shrinking from 1291 by 949 points to 136 by 190 over
/// 700 ms, and acting on a single reading reshapes the stream through every
/// intermediate shape of that animation.
///
/// **A difference inside the tolerance is arithmetic, not a band.** Two
/// roundings sit between a request and a delivery, and a reconfiguration is not
/// free, so chasing one pixel would trade an edge nobody can see for a hitch in
/// the picture everybody can.
nonisolated public enum CaptureShapeStabilisation {

    /// How far two sizes may sit apart and still count as the same size, in
    /// pixels of the delivered buffer.
    public static let contentPixelTolerance: CGFloat = 2

    /// Whether two sizes are the same size as far as this rule is concerned.
    public static func agree(_ one: CGSize, _ other: CGSize) -> Bool {
        abs(one.width  - other.width)  <= contentPixelTolerance
            && abs(one.height - other.height) <= contentPixelTolerance
    }

    /// The shape a stream running at `running` should be reshaped to, and nil
    /// when it should be left alone.
    ///
    /// `reading` is the newest measurement of what the capture is filling and
    /// `previousReading` the one before it. Nil comes back for a first reading,
    /// for a shape still moving between the two, for a reading no buffer could
    /// have, and for a settled shape the stream is already running.
    public static func settledShape(
        running        : CGSize,
        reading        : CGSize,
        previousReading: CGSize?
    ) -> CGSize? {

        guard let previousReading,
              agree(previousReading, reading),
              reading.width.isFinite,
              reading.height.isFinite,
              reading.width  >= 1,
              reading.height >= 1,
              !agree(running, reading)
        else { return nil }
        return reading
    }
}
