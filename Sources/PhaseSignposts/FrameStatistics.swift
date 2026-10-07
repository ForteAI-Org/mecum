//
//  FrameStatistics.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

#if MECUM_PHASES
import Darwin
import os

/// FrameStatistics counts the callbacks of one capture stream and says so once a second, as one
/// `frames.second` signpost event, until the stream is gone.
///
/// It counts every callback by `SCFrameStatus` (and how many carried a display time), which
/// attachments were present, how many carried dirty rectangles, and the time the callback spent
/// in its own steps. While an input is recent (`FrameProbe.markInput`) and the frames are hashed,
/// each frame is reported on its own as `frame.afterInput`, with the microseconds since the input.
/// The cost of the counting is one lock per frame; the hash is the only heavy part and is opt-in.
public final class FrameStatistics: Sendable {

    private static let statusNames = [
        "complete", "idle", "blank", "suspended", "started", "stopped", "nostatus", "other",
    ]

    private struct Second {
        var frames          = [Int](repeating: 0, count: 8)
        var withDisplayTime = [Int](repeating: 0, count: 8)
        var attached        = 0
        var screenRect      = 0
        var contentRect     = 0
        var scaleFactor     = 0
        var contentScale    = 0
        var dirtyFrames     = 0
        var dirtyRects      = 0
        var hashed          = 0
        var callbacks       = 0
        var callbackTicks: UInt64 = 0
        var sourceTicks  : UInt64 = 0
        var initTicks    : UInt64 = 0
        var initFailures    = 0
    }

    private struct State {
        var second = Second()
        var lastHash: UInt64?
        var counters: (@Sendable () -> (produced: Int, coalesced: Int, stale: Int))?
    }

    private let id = FrameProbe.makeStreamID()
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {
        FrameProbe.register(self)
    }

    deinit {
        PhaseInterval.event("stream.end", "stream=\(id)")
    }

    /// Says what this stream is, once, in `key=value` words, and gives it a way to read the
    /// stream's own produced, coalesced and stale counts.
    public func begin(
        description: String,
        counters   : @escaping @Sendable () -> (produced: Int, coalesced: Int, stale: Int)
    ) {
        state.withLock { $0.counters = counters }
        PhaseInterval.event("stream.begin", "stream=\(id) \(description)")
    }

    /// Counts one callback, whatever its status, at `ticks` (the callback's own entry time).
    public func record(_ sample: FrameSample, at ticks: UInt64) {
        let slot = sample.status.map { (0...5).contains($0) ? $0 : 7 } ?? 6
        let changed: Bool? = state.withLock { state in
            state.second.frames[slot] += 1
            if sample.hasDisplayTime { state.second.withDisplayTime[slot] += 1 }
            if sample.hasAttachment { state.second.attached += 1 }
            if sample.hasScreenRect { state.second.screenRect += 1 }
            if sample.hasContentRect { state.second.contentRect += 1 }
            if sample.hasScaleFactor { state.second.scaleFactor += 1 }
            if sample.hasContentScale { state.second.contentScale += 1 }
            if sample.dirtyRectCount > 0 {
                state.second.dirtyFrames += 1
                state.second.dirtyRects += sample.dirtyRectCount
            }
            guard let hash = sample.contentHash else { return nil }
            state.second.hashed += 1
            defer { state.lastHash = hash }
            return state.lastHash.map { $0 != hash }
        }
        guard let microseconds = FrameProbe.microsecondsSinceInput(at: ticks),
              let hash = sample.contentHash
        else { return }
        let verdict = changed.map { $0 ? "1" : "0" } ?? "u"
        PhaseInterval.event(
            "frame.afterInput",
            "stream=\(id) dtUs=\(microseconds) status=\(sample.status ?? -1) "
                + "displayTime=\(sample.hasDisplayTime ? 1 : 0) dirty=\(sample.dirtyRectCount) "
                + "hash=\(String(hash, radix: 16)) changed=\(verdict)"
        )
    }

    /// Adds the time one delivered frame's callback spent: in total, in the source identity
    /// check, and in building the `SeatFrame`, all in mach ticks.
    public func addCosts(callback: UInt64, source: UInt64, frameInit: UInt64) {
        state.withLock {
            $0.second.callbacks += 1
            $0.second.callbackTicks &+= callback
            $0.second.sourceTicks &+= source
            $0.second.initTicks &+= frameInit
        }
    }

    /// Counts a sample that gave no `SeatFrame`.
    public func noteInitFailure() {
        state.withLock { $0.second.initFailures += 1 }
    }

    func flush() {
        let (second, counters) = state.withLock { state in
            defer { state.second = Second() }
            return (state.second, state.counters)
        }
        let counts = counters?() ?? (produced: 0, coalesced: 0, stale: 0)
        var words = ["stream=\(id)"]
        for (index, name) in Self.statusNames.enumerated() {
            words.append("\(name)=\(second.frames[index])")
            words.append("\(name)_dt=\(second.withDisplayTime[index])")
        }
        words += [
            "attached=\(second.attached)", "screenRect=\(second.screenRect)",
            "contentRect=\(second.contentRect)", "scaleFactor=\(second.scaleFactor)",
            "contentScale=\(second.contentScale)", "dirtyFrames=\(second.dirtyFrames)",
            "dirtyRects=\(second.dirtyRects)", "hashed=\(second.hashed)",
            "callbacks=\(second.callbacks)",
            "callbackUs=\(FrameProbe.nanoseconds(ofTicks: second.callbackTicks) / 1000)",
            "sourceUs=\(FrameProbe.nanoseconds(ofTicks: second.sourceTicks) / 1000)",
            "initUs=\(FrameProbe.nanoseconds(ofTicks: second.initTicks) / 1000)",
            "initFailures=\(second.initFailures)", "produced=\(counts.produced)",
            "coalesced=\(counts.coalesced)", "stale=\(counts.stale)",
        ]
        PhaseInterval.event("frames.second", words.joined(separator: " "))
    }
}
#endif
