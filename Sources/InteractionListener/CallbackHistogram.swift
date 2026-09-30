import CoreGraphics
import Foundation

/// CallbackHistogram counts tap callback durations in log2 nanosecond buckets, with count and exact maximum.
/// A fixed-size value: recording neither allocates nor locks. Bucket k holds [2^(k-1), 2^k) ns, bucket 0 zero.
package struct CallbackHistogram: Sendable, Equatable {
    package private(set) var buckets = SIMD64<UInt64>()
    package private(set) var count: UInt64 = 0
    package private(set) var maximum: UInt64 = 0

    package init() {}

    package static func bucket(_ nanoseconds: UInt64) -> Int {
        min(63, UInt64.bitWidth - nanoseconds.leadingZeroBitCount)
    }

    package mutating func record(_ nanoseconds: UInt64) {
        let index = Self.bucket(nanoseconds)
        // Through a pointer: a dynamic SIMD subscript may copy the whole vector on every write.
        withUnsafeMutablePointer(to: &buckets) {
            $0.withMemoryRebound(to: UInt64.self, capacity: 64) { $0[index] &+= 1 }
        }
        count &+= 1
        if nanoseconds > maximum { maximum = nanoseconds }
    }

    /// Returns what was recorded and starts over.
    package mutating func take() -> CallbackHistogram {
        defer { self = CallbackHistogram() }
        return self
    }

    /// The duration in nanoseconds below which `fraction` of the samples fall, zero when empty.
    // ponytail: log2 buckets place a percentile in its octave and interpolate linearly inside it;
    // add sub-buckets per octave if a 5% comparison between two runs must be exact.
    package func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = max(1, min(count, UInt64((fraction * Double(count)).rounded(.up))))
        var below: UInt64 = 0
        for index in 0..<64 where buckets[index] > 0 {
            let inside = buckets[index]
            if below + inside >= rank {
                let lower = index == 0 ? 0 : Double(UInt64(1) << (index - 1))
                // The maximum's bucket spreads its samples up to the maximum, not to the bucket's end.
                let upper = min(Double(UInt64(1) << index), Double(maximum))
                return lower + (upper - lower) * Double(rank - below) / Double(inside)
            }
            below += inside
        }
        return Double(maximum)
    }

    /// One stderr line: `callback[<role>] <kind>: n 123 p50 4.1us p90 … p99 … max … (since last dump)`.
    package func line(role: String, kind: String, atStop: Bool = false) -> String {
        let head = "callback[\(role)] \(kind): n \(count)"
        let span = atStop ? "(since last dump, at stop)" : "(since last dump)"
        guard count > 0 else { return "\(head) \(span)" }
        func us(_ nanoseconds: Double) -> String { String(format: "%.1fus", nanoseconds / 1000) }
        return "\(head) p50 \(us(percentile(0.5))) p90 \(us(percentile(0.9))) "
            + "p99 \(us(percentile(0.99))) max \(us(Double(maximum))) \(span)"
    }
}

/// CallbackLatency is the tap thread's three histograms: callbacks that can produce an event (`input`),
/// every other callback (`pointer`: moves, drags, keys) and the scroll/hover timer's body (`timer`).
package struct CallbackLatency: Sendable, Equatable {
    package var input = CallbackHistogram()
    package var pointer = CallbackHistogram()
    package var timer = CallbackHistogram()

    package init() {}

    /// Records one tap callback under its kind, by the event type the tap passed.
    package mutating func record(_ type: CGEventType, _ nanoseconds: UInt64) {
        if type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel {
            input.record(nanoseconds)
        } else {
            pointer.record(nanoseconds)
        }
    }

    /// Returns what was recorded and starts over.
    package mutating func take() -> CallbackLatency {
        defer { self = CallbackLatency() }
        return self
    }

    /// One dump: the input, pointer and timer lines, newline separated, without a trailing newline.
    package func lines(role: String, atStop: Bool = false) -> String {
        [input.line(role: role, kind: "input", atStop: atStop), pointer.line(role: role, kind: "pointer", atStop: atStop),
         timer.line(role: role, kind: "timer", atStop: atStop)].joined(separator: "\n")
    }
}
