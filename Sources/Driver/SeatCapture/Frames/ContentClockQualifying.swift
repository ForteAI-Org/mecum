//
//  ContentClockQualifying.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import SeatCore

/// ContentClockQualifying answers how old the **content** of a sample is on the
/// caller's monotonic clock, or says that it cannot.
///
/// The role exists because a Frame carries three different times and none of
/// them is the answer on its own. `receivedAt` is when the kit's callback ran,
/// which is a fact about delivery. `presentationTime` comes from the sample
/// buffer on its own timeline. `displayTime` is an optional attachment. Relating
/// any of them to the caller's clock is a native question that has to be
/// qualified with a real oracle, and a conformer that cannot must answer
/// `unknown` rather than subtract two numbers that happen to be `UInt64`.
///
/// A conformer is borrowed for the call, is free of state that the caller has to
/// manage, and must be safe to invoke from the main actor.
nonisolated public protocol ContentClockQualifying: Sendable {

    /// True only when an oracle relates the sample clock to the caller's. It is
    /// reported separately so a consumer can tell "no measurement was possible"
    /// from "the measurement said the content is old".
    var isQualified: Bool { get }

    /// The age of the sample's content at `now`, on the caller's monotonic
    /// clock, or why it is not known.
    func contentAge(of frame: SeatFrame, atNanoseconds now: UInt64) -> FrameContentAge
}

/// UnqualifiedContentClock is the shipped conformer, and it answers unknown for
/// every sample.
///
/// That is the honest state of this system: no traced oracle relates
/// ScreenCaptureKit's sample clock to `mach_absolute_time` here, so a Frame's
/// content age cannot be established and the finite age limit cannot be
/// evaluated. Every Command carrying such an observation is refused before any
/// effect, with `frameAgeUnknown`. Replacing this type with one that subtracts
/// `receivedAt` would not qualify the capability, it would only hide the gap.
nonisolated public struct UnqualifiedContentClock: ContentClockQualifying {

    public init() {}

    public var isQualified: Bool { false }

    public func contentAge(of frame: SeatFrame, atNanoseconds now: UInt64) -> FrameContentAge {
        .unknown(.clockNotQualified)
    }
}
