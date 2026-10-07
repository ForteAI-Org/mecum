//
//  WindowServerReadingCache.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import Synchronization

/// WindowServerReadingCache keeps a stream receiver's two window server answers between frames:
/// whether the attested window still has its identity, and where it is.
///
/// ## Why it exists
///
/// A running window stream delivers about 29 complete frames a second on macOS 27 even while the
/// window does not change, and the receiver asked the window server twice for each of them: once
/// for identity and once for the rectangle a frame without geometry attachments is certified
/// from. Measured on 7 October 2026 that was about 14 ms a second for each question, and over the
/// whole run the rectangle never changed. Both answers are now reused until something says they
/// can have changed.
///
/// ## When an answer is read again
///
/// - after `refreshIntervalNanoseconds` since it was read;
/// - when the frame's pixel size or its scale attachments differ from the reading's;
/// - after `invalidate`, which the owner calls when it moved or resized the window, or when an
///   observation reports the window somewhere else.
///
/// The first frame of every receiver reads both, so a Still taken from a fresh stream is checked
/// exactly as before. A failed identity check is never kept: the receiver refuses every later
/// frame on it anyway.
///
/// ## What it does not weaken
///
/// The cache serves the receiver's per-frame bookkeeping only. A Frame handed to an observation is
/// attested again at the hand-over, against a fresh reading, by the observation path itself.
///
/// The lock is held only around the stored values; the window server is asked outside it, so a
/// slow answer never blocks `invalidate`.
nonisolated final class WindowServerReadingCache: Sendable {

    /// How long one answer is reused: once a second, the beat the seat's heartbeat already has.
    static let refreshIntervalNanoseconds: UInt64 = 1_000_000_000

    /// What a geometry reading was taken for. A frame of another size or scale is a frame of a
    /// window that may have changed shape, so its rectangle is read again.
    struct FrameShape: Equatable {
        var pixelSize   : CGSize
        var scaleFactor : Double?
        var contentScale: Double?
    }

    private struct Reading<Value> {
        var value : Value
        var readAt: UInt64
    }

    private struct State {
        var identityCheckedAt: UInt64?
        var geometry         : Reading<(rect: CGRect, shape: FrameShape)>?
    }

    private let state = Mutex(State())

    /// Forgets both answers, so the next frame reads them again.
    func invalidate() {
        state.withLock { $0 = State() }
    }

    /// Answers why the source is no longer the attested window, or nil, reading `check` only when
    /// the last successful check is older than the bound or was invalidated.
    func identityFailure(
        at now: UInt64,
        check : () -> CaptureFailure?
    ) -> CaptureFailure? {
        let isFresh = state.withLock { state in
            state.identityCheckedAt.map { now &- $0 < Self.refreshIntervalNanoseconds } ?? false
        }
        guard !isFresh else { return nil }
        if let failure = check() { return failure }
        state.withLock { $0.identityCheckedAt = now }
        return nil
    }

    /// The window server rectangle for a frame of `shape`, reading `read` only when there is no
    /// reading for that shape inside the bound. An empty answer is not kept, so the next frame
    /// asks again instead of being dropped for a whole bound.
    func screenRect(
        at now: UInt64,
        for shape: FrameShape,
        read  : () -> CGRect?
    ) -> CGRect? {
        let cached = state.withLock { state -> CGRect? in
            guard let reading = state.geometry,
                  reading.value.shape == shape,
                  now &- reading.readAt < Self.refreshIntervalNanoseconds
            else { return nil }
            return reading.value.rect
        }
        if let cached { return cached }
        guard let rect = read() else { return nil }
        state.withLock { $0.geometry = Reading(value: (rect, shape), readAt: now) }
        return rect
    }
}
