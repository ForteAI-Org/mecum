//
//  BrainClock.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation

/// BrainClock is the one rule between the brain's `Date`s and the living memory's `INTEGER`
/// millisecond columns. A `Date` has sub-millisecond precision and the columns do not, so the
/// clock a caller hands a projection is quantized once, at the boundary, to its canonical
/// millisecond instant: the nearest millisecond, ties away from zero. Every `Date` inside a stored
/// brain is canonical, and for a canonical instant the two conversions are exact inverses, which
/// is what lets a stored projection equal a pure brain run on the same canonical clock. The
/// quantization moves the 600 s tick and the 365-day backstop by at most half a millisecond on the
/// clock's own axis; it changes no threshold.
///
/// Representable instants are those within `range` (about 35,700 years either side of 1970),
/// where the exactness above is proven; an instant outside it, or one that is not a finite
/// number, is a typed error, never clamped or wrapped. No round trip is claimed for an arbitrary
/// sub-millisecond `Date`: `canonical` is the quantization, `date(milliseconds(of:))`.
public enum BrainClock {

    /// Problem is why an instant could not be converted.
    public enum Problem: Error, Sendable, Equatable {

        /// The date's seconds are NaN or infinite.
        case notFinite

        /// The date lies outside `range`; the value is its seconds since 1970.
        case dateOutOfRange(seconds: Double)

        /// A stored millisecond value lies outside `range`.
        case millisecondsOutOfRange(Int64)
    }

    /// The milliseconds a projection represents: `Double(ms)` is exact and, for a canonical
    /// instant, `milliseconds(of: date(ms)) == ms` (the product's rounding error stays under half
    /// a millisecond up to 2^50).
    public static let range: ClosedRange<Int64> = -(1 << 50)...(1 << 50)

    /// The canonical millisecond instant of a date: the nearest millisecond, ties away from zero.
    public static func milliseconds(of date: Date) throws -> Int64 {
        let scaled = date.timeIntervalSince1970 * 1000
        guard scaled.isFinite else { throw Problem.notFinite }
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound) else {
            throw Problem.dateOutOfRange(seconds: date.timeIntervalSince1970)
        }
        return Int64(rounded)
    }

    /// The canonical `Date` of a stored millisecond value.
    public static func date(_ milliseconds: Int64) throws -> Date {
        guard range.contains(milliseconds) else { throw Problem.millisecondsOutOfRange(milliseconds) }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// The date quantized to its canonical millisecond instant: what a projection runs on.
    public static func canonical(_ date: Date) throws -> Date {
        try self.date(try milliseconds(of: date))
    }
}
