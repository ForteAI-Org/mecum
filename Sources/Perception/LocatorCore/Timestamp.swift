import Foundation

/// Time source for descriptor timestamps (`created`, `lastVerified`).
///
/// The on-disk format is millisecond-precision ISO-8601. A raw `Date()` carries finer-than-ms
/// precision, so it would not survive an encode→decode round-trip exactly. Producing timestamps via
/// ``now()`` (millisecond-quantized) makes the in-memory value equal to the persisted value, so
/// `load(save(d)) == d` holds and self-heal can compare/verify timestamps reliably.
public enum LocatorTime {
    /// Current time, quantized to whole milliseconds.
    public static func now() -> Date { quantized(Date()) }

    /// Quantize a date to whole-millisecond precision (the storage granularity).
    public static func quantized(_ date: Date) -> Date {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
