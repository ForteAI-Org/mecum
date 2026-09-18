//
//  UserFocusRequestTiming.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// Monotonic durations of the private request, kept separate from observation.
nonisolated package struct UserFocusRequestTiming: Sendable, Equatable {
    package init() {}

    package var ownerLookupNanoseconds: UInt64 = 0
    package var psnLookupNanoseconds: UInt64 = 0
    package var activationNanoseconds: UInt64 = 0
    package var firstKeyNanoseconds: UInt64 = 0
    package var secondKeyNanoseconds: UInt64 = 0

    /// Entry to exit of the whole `UserFocusRestorer.restore` call, guard, reset
    /// and final work included, recorded on a normal return and on a throw.
    /// `nil` means the call was not made or not measured; `0` is a measured
    /// duration at or below the clock's resolution, not a missing value.
    package var restoreCallNanoseconds: UInt64?

    /// Cost of one monotonic clock read taken inside the measured window, so the
    /// instrumentation overhead is reported instead of being subtracted from it.
    package var restoreCallControlNanoseconds: UInt64?
}
