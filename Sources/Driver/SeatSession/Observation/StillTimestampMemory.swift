//
//  StillTimestampMemory.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import SeatCapture
import Synchronization

/// StillTimestampMemory remembers, for one display generation, that the one-shot Still of this
/// system came back without a display time, so the next request goes straight to the stream.
///
/// ## Why it exists
///
/// A request needs a Frame that carries WindowServer's display time. On a system whose one-shot
/// capture never attaches it, the one-shot Still is captured and thrown away on every request, and
/// the stream Still that follows is the one that is used. Remembering the miss removes the wasted
/// capture. The first request of a generation still tries the one-shot, so a system that does
/// attach the time keeps the fast path, and a Still that carries it never records a miss.
///
/// ## What stays true
///
/// The fallback is `SeatCaptureStream.timestampedStill`. It never used the observation barrier or
/// the one-shot's result: it starts a stream of its own and takes the first complete Frame with a
/// display time, so skipping the one-shot changes which Frame is returned by nothing but timing.
///
/// ## Scope and reset
///
/// The memory is one value per source, and a source is made for one display generation, so it is
/// per generation by construction. The generation is stored as well: a request that names another
/// generation tries the one-shot again and the old miss no longer applies. A new generation
/// is the only reset, because nothing else changes what the system attaches.
///
/// Calls may come from any task. A race between two first requests only costs one extra one-shot.
nonisolated final class StillTimestampMemory: Sendable {

    private let missingGeneration = Mutex<UInt64?>(nil)

    /// Whether the one-shot Still of `generation` is known not to carry a display time.
    func skipsOneShot(of generation: UInt64) -> Bool {
        missingGeneration.withLock { $0 == generation }
    }

    /// Records what the one-shot Still of `generation` carried: a miss is remembered for that
    /// generation, and a Still with a display time forgets a miss of the same generation.
    func record(_ still: SeatFrame, of generation: UInt64) {
        missingGeneration.withLock { remembered in
            if still.displayTime == nil {
                remembered = generation
            } else if remembered == generation {
                remembered = nil
            }
        }
    }

    /// Answers a Frame with a display time: the one-shot Still when it has one, else what
    /// `fallback` captures. `oneShot` is not called for a generation that missed already.
    ///
    /// `fallback` receives how many one-shot attempts were spent (0 or 1), for the deadline error
    /// it reports when the budget ran out in between. A thrown error from either closure
    /// is passed on and records nothing, so a failed one-shot does not look like a miss.
    func timestamped(
        generation: UInt64,
        oneShot   : () async throws -> SeatFrame,
        fallback  : (_ attemptsSpent: Int) async throws -> SeatFrame
    ) async throws -> SeatFrame {

        if skipsOneShot(of: generation) { return try await fallback(0) }
        let still = try await oneShot()
        record(still, of: generation)
        guard still.displayTime == nil else { return still }
        return try await fallback(1)
    }
}
