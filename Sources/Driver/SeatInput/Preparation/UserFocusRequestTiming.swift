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
}
