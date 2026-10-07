//
//  FrameProbe.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

#if MECUM_PHASES
import CoreGraphics
import Darwin
import Dispatch
import os

/// FrameProbe holds what a frame measurement shares across streams: the instant of the last
/// input, the geometry queries of frames that arrive without attachments, and the one-second
/// clock every `FrameStatistics` is flushed by.
///
/// Compiled only under `MECUM_PHASES`, like the rest of this module. Nothing here changes what a
/// stream does: it reads, counts and emits signpost events.
public enum FrameProbe {

    /// Whether every frame's pixels are hashed, set by the environment of the measured process.
    /// It is off for the CPU measurements, since reading the surface would be part of the cost.
    public static let hashesFrames = getenv("MECUM_PHASE_FRAME_HASH") != nil

    /// How long after an input the frames are reported one by one, in microseconds.
    static let inputWindowMicroseconds: UInt64 = 2_000_000

    private static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()

    private struct GeometryQueries {
        var count = 0
        var ticks: UInt64 = 0
        var rectChanges = 0
        var lastRect: CGRect?
    }

    private struct WeakStatistics: @unchecked Sendable {
        weak var value: FrameStatistics?
    }

    private static let lastInputTicks = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private static let geometry = OSAllocatedUnfairLock(initialState: GeometryQueries())
    private static let registry = OSAllocatedUnfairLock<[WeakStatistics]>(initialState: [])
    private static let nextStreamID = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private static let ticker: any DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.forte.Mecum.phases.frames", qos: .utility)
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { tick() }
        timer.resume()
        return timer
    }()

    public static func nanoseconds(ofTicks ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Marks the end of an input's delivery: the zero of every `frame.afterInput` event.
    public static func markInput() {
        lastInputTicks.withLock { $0 = mach_absolute_time() }
        PhaseInterval.event("input", "")
    }

    /// Records one window server query made to give a frame without attachments its geometry.
    /// `screenRect` is what the query answered, so a changing window shows as rectangle changes.
    public static func noteGeometryQuery(ticks: UInt64, screenRect: CGRect?) {
        geometry.withLock { state in
            state.count += 1
            state.ticks &+= ticks
            if let screenRect, state.lastRect != screenRect {
                if state.lastRect != nil { state.rectChanges += 1 }
                state.lastRect = screenRect
            }
        }
    }

    static func makeStreamID() -> UInt64 {
        nextStreamID.withLock { id in
            id += 1
            return id
        }
    }

    static func register(_ statistics: FrameStatistics) {
        registry.withLock { entries in
            entries.removeAll { $0.value == nil }
            entries.append(WeakStatistics(value: statistics))
        }
        _ = ticker
    }

    /// Microseconds from the last input to `ticks`, or nil outside the reported window.
    static func microsecondsSinceInput(at ticks: UInt64) -> UInt64? {
        let input = lastInputTicks.withLock { $0 }
        guard input != 0, ticks >= input else { return nil }
        let microseconds = nanoseconds(ofTicks: ticks - input) / 1000
        return microseconds <= inputWindowMicroseconds ? microseconds : nil
    }

    private static func tick() {
        let live = registry.withLock { $0.compactMap(\.value) }
        for statistics in live { statistics.flush() }
        let queries = geometry.withLock { state in
            defer { state.count = 0; state.ticks = 0 }
            return state
        }
        PhaseInterval.event(
            "geometry.second",
            "queries=\(queries.count) queryUs=\(nanoseconds(ofTicks: queries.ticks) / 1000) "
                + "rectChanges=\(queries.rectChanges)"
        )
    }
}
#endif
