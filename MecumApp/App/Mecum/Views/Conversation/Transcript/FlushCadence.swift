//
//  FlushCadence.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// FlushCadence is how long the transcript lets updates to a conversation
/// accumulate before it reads and shows them together (§12.3).
///
/// It starts at 40 ms, inside the spec's 30 to 60. Under main-thread pressure
/// it stretches: after an apply that held the main actor for `d`, the next
/// wait is `4 d`, so applying takes at most about a fifth of the main thread,
/// up to `ceiling`. A quick apply brings it back to 40 ms. A value type,
/// owned by `TranscriptController` on the main actor.
nonisolated struct FlushCadence: Sendable, Equatable {

    static let floor  : Duration = .milliseconds(40)
    static let ceiling: Duration = .milliseconds(250)

    private(set) var interval = FlushCadence.floor

    /// Adapts the next wait to how long the last apply held the main actor.
    mutating func record(applyDuration: Duration) {
        interval = min(Self.ceiling, max(Self.floor, applyDuration * 4))
    }
}
