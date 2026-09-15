//
//  MonitorQuality.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// MonitorFrameRate is the three paces a Monitor runs at.
///
/// Three and not a free integer: each one has a measured cost behind it and the
/// 120 level has a precondition (a display that really runs at 120 Hz), so a
/// caller asking for 45 would be asking for a number nobody measured.
nonisolated public enum MonitorFrameRate: Int, Sendable, Equatable, CaseIterable, Comparable {

    case thirty           = 30
    case sixty            = 60
    case oneHundredTwenty = 120

    public static func < (lhs: MonitorFrameRate, rhs: MonitorFrameRate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The next slower pace, or nil at the floor.
    public var slower: MonitorFrameRate? {
        switch self {
        case .oneHundredTwenty: .sixty
        case .sixty           : .thirty
        case .thirty          : nil
        }
    }
}

/// MonitorQuality is one rung of the degradation ladder: a pace and a fraction
/// of the requested resolution.
///
/// The ladder gives up frames before it gives up pixels, and the measurement is
/// why: going from 960x540 to the full 1920x1080
/// backing size costs the zero-copy pipeline three points of CPU and nothing in
/// memory, while a frame rate halves the work per second. Sharpness is nearly
/// free, so it is the last thing to go.
nonisolated public struct MonitorQuality: Sendable, Equatable {

    public let frameRate: MonitorFrameRate

    /// The fraction of the configured output size the stream is asked for. The
    /// ladder only ever produces `1` and `Self.halfResolution`; a caller builds
    /// the top rung and the policy walks down from it.
    public let resolutionScale: Double

    /// The one resolution step there is. Half in each direction is a quarter of
    /// the pixels, which is a step worth taking; anything finer would cost a
    /// reconfiguration for a saving nobody can see.
    public static let halfResolution = 0.5

    public init(frameRate: MonitorFrameRate, resolutionScale: Double = 1) {
        self.frameRate       = frameRate
        self.resolutionScale = resolutionScale
    }

    /// The default of spec section 5: 60 fps at full resolution.
    public static let standard = MonitorQuality(frameRate: .sixty)

    /// The next rung down, or nil when there is nothing left to give up.
    ///
    /// Frames first, all the way down to 30, and only then the one resolution
    /// step. A Monitor at 30 fps and half resolution is the floor: below that
    /// the preview stops being something a person can follow, and the honest
    /// answer is to report the quality rather than keep cutting.
    public func degraded() -> MonitorQuality? {
        if let slower = frameRate.slower {
            return MonitorQuality(frameRate: slower, resolutionScale: resolutionScale)
        }
        guard resolutionScale > Self.halfResolution else { return nil }
        return MonitorQuality(frameRate: frameRate, resolutionScale: Self.halfResolution)
    }

    /// The output size this rung asks the stream for, given the size the
    /// consumer configured. Never smaller than one pixel in each direction.
    public func pixelSize(from configured: CGSize) -> CGSize {
        CGSize(
            width : max(1, (configured.width  * resolutionScale).rounded()),
            height: max(1, (configured.height * resolutionScale).rounded())
        )
    }
}

/// MonitorDegradationReason is why the Monitor gave something up, with the
/// number that decided it.
///
/// Coalescence is the primary signal and CPU the secondary one, in that order,
/// because coalescence is free to measure and is a direct observation of the
/// presenting side falling behind, while a CPU percentage is a second-hand
/// reading that arrives once a second from somebody else's heartbeat.
nonisolated public enum MonitorDegradationReason: Sendable, Equatable {

    /// The share of frames the newest-wins slot threw away, in 0...1.
    case coalescence(rate: Double)

    /// Percent of one core, as read by the consumer's heartbeat.
    case cpuCost(percent: Double)
}

/// MonitorQualityChange is the event of spec section 5,
/// `monitorQualityChanged(from:to:reason:)`, as a value.
///
/// It is returned by `Monitor.evaluate` rather than pushed through a stream of
/// its own: the caller that supplies the CPU reading is the caller that wants
/// the answer, and the seat turns it into a `SeatEvent` for everyone else.
nonisolated public struct MonitorQualityChange: Sendable, Equatable {

    public let from  : MonitorQuality
    public let to    : MonitorQuality
    public let reason: MonitorDegradationReason

    public init(from: MonitorQuality, to: MonitorQuality, reason: MonitorDegradationReason) {
        self.from   = from
        self.to     = to
        self.reason = reason
    }
}
