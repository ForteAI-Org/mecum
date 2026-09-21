//
//  ContentClockQualifying.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import Darwin
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

/// Converts ScreenCaptureKit's WindowServer display timestamp from Mach absolute
/// ticks into the nanosecond uptime clock used by `DispatchTime`.
///
/// The SDK contract for `SCStreamFrameInfoDisplayTime` names Mach absolute time,
/// and `DispatchTime.uptimeNanoseconds` is that same clock after the conversion
/// described by `mach_timebase_info`. Missing, zero, overflowing or future
/// timestamps remain explicit refusals.
nonisolated public struct MachAbsoluteContentClock: ContentClockQualifying {

    private let numerator  : UInt64
    private let denominator: UInt64

    public init() {
        var timebase = mach_timebase_info_data_t()
        let status = mach_timebase_info(&timebase)
        if status == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 {
            numerator   = UInt64(timebase.numer)
            denominator = UInt64(timebase.denom)
        } else {
            numerator   = 0
            denominator = 0
        }
    }

    package init(numerator: UInt32, denominator: UInt32) {
        self.numerator   = UInt64(numerator)
        self.denominator = UInt64(denominator)
    }

    public var isQualified: Bool { numerator > 0 && denominator > 0 }

    public func contentAge(of frame: SeatFrame, atNanoseconds now: UInt64) -> FrameContentAge {
        guard isQualified else { return .unknown(.clockNotQualified) }
        guard let displayTime = frame.displayTime else { return .unknown(.timestampMissing) }
        guard let displayedAt = displayTimeNanoseconds(fromMachTicks: displayTime)
        else {
            return .unknown(.timestampMalformed)
        }
        guard displayedAt <= now else {
            return .unknown(.timestampNotMonotonic)
        }
        return .qualified(nanoseconds: now - displayedAt)
    }

    /// Dividing first keeps ordinary long uptimes out of the overflowing
    /// intermediate `ticks * numerator` while retaining the fractional part.
    package func displayTimeNanoseconds(fromMachTicks ticks: UInt64) -> UInt64? {
        guard isQualified, ticks > 0 else { return nil }
        let whole = ticks / denominator
        let remainder = ticks % denominator
        let (wholeNanoseconds, wholeOverflow) = whole.multipliedReportingOverflow(by: numerator)
        guard !wholeOverflow else { return nil }
        let (fractionProduct, fractionOverflow) = remainder.multipliedReportingOverflow(by: numerator)
        guard !fractionOverflow else { return nil }
        let fractionNanoseconds = fractionProduct / denominator
        let (nanoseconds, sumOverflow) = wholeNanoseconds.addingReportingOverflow(fractionNanoseconds)
        return sumOverflow ? nil : nanoseconds
    }
}

/// UnqualifiedContentClock is the shipped conformer, and it answers unknown for
/// every sample.
///
/// It remains the default for a caller that composes no oracle. Production seats
/// explicitly compose `MachAbsoluteContentClock`; substituting callback arrival
/// time is still forbidden because it measures delivery rather than content.
nonisolated public struct UnqualifiedContentClock: ContentClockQualifying {

    public init() {}

    public var isQualified: Bool { false }

    public func contentAge(of frame: SeatFrame, atNanoseconds now: UInt64) -> FrameContentAge {
        .unknown(.clockNotQualified)
    }
}
