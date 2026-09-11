//
//  RecordLayout.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// RecordLayout is the private SkyLight event record, described once. Every
/// offset here was measured on 26A5425a by writing with a setter and reading
/// the byte back; none of them is inherited from another project's source.
/// There is no fallback for a layout that moved: the Facility refuses.
///
/// The declared length at 0x04 is the only oracle the system offers for the
/// whole record, and the kit checks it every time it touches one.
nonisolated public enum RecordLayout {

    /// Where the record states its own length.
    public static let lengthOffset = 0x04

    /// The length the record declares on every build the kit has seen, from
    /// macOS 11 to macOS 27.
    public static let declaredLength: UInt32 = 0xF8

    /// What the kit allocates for a record it builds itself: 256 bytes for 248
    /// declared. yabai reached this number the expensive way, first a stack
    /// buffer that crashed on Sonoma arm64, then a heap buffer of exactly
    /// 0xF8, then 0x100 with no explanation in the commit. Eight bytes buy out
    /// of that entire history.
    public static let allocatedLength = 0x100

    /// Event type. The Preparation's activation record uses 0x0D, which is not
    /// a `CGEventType` at all; every other type the kit meets follows the rule
    /// in `typeByte(of:)`.
    public static let typeOffset = 0x08

    /// The byte the record carries at `typeOffset` for a CoreGraphics event,
    /// which is simply that event type's own raw value.
    ///
    /// The rule was read back out of records CoreGraphics built, one event type
    /// at a time, and it holds across the whole table: 0x01 and 0x02 for the
    /// left button down and up, **0x03 and 0x04 for the right one**, 0x0A and
    /// 0x0B for a key down and up, 0x16 for a scroll. So a caller that needs a
    /// type byte derives it and does not write a number down, and a build where
    /// the rule broke would fail the cross-validation instead of posting a
    /// record the window server reads as another kind of event.
    ///
    /// `nil` for a raw value that does not fit a byte, which no event type the
    /// kit builds reaches. The window server's own record types outside the
    /// public enumeration, such as the activation record's 0x0D, are not
    /// covered by this and are written as their own constants where they are
    /// used.
    public static func typeByte(of eventType: CGEventType) -> UInt8? {
        UInt8(exactly: eventType.rawValue)
    }

    /// Window-local point, x then y, as two `Double`s. Written through
    /// `CGEventSetWindowLocation`, never by hand: the setter is the only thing
    /// that proves the offset still is where it was.
    public static let localPointXOffset = 0x20
    public static let localPointYOffset = 0x28

    /// Event flags.
    public static let flagsOffset = 0x3A

    /// Target window number. Cross-validated against integer field 51.
    public static let windowNumberOffset = 0x3C

    /// Owning WindowServer connection. Cross-validated against field 52.
    public static let ownerConnectionOffset = 0x40

    /// The integer field id that reads and writes 0x3C. Outside the public
    /// enumeration, but `setIntegerValueField` is public and stable, which is
    /// why the kit writes the routed fields through it and leaves
    /// `SLEventRecordPointer` to the length check and the round trip.
    public static let windowNumberField: UInt32 = 51

    /// The integer field id that reads and writes 0x40.
    public static let ownerConnectionField: UInt32 = 52

    /// A zeroed buffer of `allocatedLength` with the declared length already in
    /// place, which is only the Preparation.
    public static func makeRecord() -> [UInt8] {
        var record = [UInt8](repeating: 0, count: allocatedLength)
        record.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: declaredLength, toByteOffset: lengthOffset, as: UInt32.self)
        }
        return record
    }

    /// The length the record claims, checked against the length the kit was
    /// built for. Throws rather than returning a flag, because every caller of
    /// this function is about to write into the record.
    public static func validateDeclaredLength(
        of record: UnsafeRawPointer,
        length   : Int = Int(declaredLength)
    ) throws -> UInt32 {
        let declared = try read(UInt32.self, at: lengthOffset, from: record, length: length)
        guard declared == declaredLength else {
            throw SystemFailure.unsupportedRecordLength(
                declared: declared,
                expected: declaredLength
            )
        }
        return declared
    }

    /// Reads a trivial value at an offset, with the bound checked first. This
    /// is the audited exception to the no-unsafe rule: the pointer comes from
    /// the system, so its length is checked and its offsets are bounded before
    /// any load.
    public static func read<Value>(
        _ type: Value.Type,
        at offset: Int,
        from record: UnsafeRawPointer,
        length: Int
    ) throws -> Value {
        try checkBounds(offset: offset, width: MemoryLayout<Value>.size, length: length)
        return record.loadUnaligned(fromByteOffset: offset, as: type)
    }

    /// Writes a trivial value at an offset, with the bound checked first.
    public static func write<Value>(
        _ value: Value,
        at offset: Int,
        into record: UnsafeMutableRawPointer,
        length: Int
    ) throws {
        try checkBounds(offset: offset, width: MemoryLayout<Value>.size, length: length)
        record.storeBytes(of: value, toByteOffset: offset, as: Value.self)
    }

    private static func checkBounds(offset: Int, width: Int, length: Int) throws {
        guard offset >= 0, width > 0, offset + width <= length else {
            throw SystemFailure.recordOffsetOutOfBounds(
                offset: offset,
                width : width,
                length: length
            )
        }
    }
}

/// RecordLayoutCheck is the outcome of the three round trips the kit runs
/// before it lets the Input Facility act. It is a value and not a throw because
/// the readiness gate needs the whole picture: which round trip failed is the
/// difference between a moved offset and a missing symbol.
nonisolated public struct RecordLayoutCheck: Sendable, Equatable {

    /// What the record declared at 0x04, or `nil` when no record was reachable.
    public let declaredLength: UInt32?

    /// Integer field 51 wrote 0x3C and 0x3C read back through field 51.
    public let windowNumberRoundTrip: Bool

    /// Integer field 52 wrote 0x40 and 0x40 read back through field 52.
    public let ownerConnectionRoundTrip: Bool

    /// `CGEventSetWindowLocation` wrote the two `Double`s at 0x20 and 0x28.
    public let windowLocationRoundTrip: Bool

    /// The first thing that went wrong, structured. `nil` when everything held.
    public let failure: SystemFailure?

    /// True only when the record has the declared length and all three round
    /// trips came back.
    public var passed: Bool {
        failure == nil
            && declaredLength == RecordLayout.declaredLength
            && windowNumberRoundTrip
            && ownerConnectionRoundTrip
            && windowLocationRoundTrip
    }

    public init(
        declaredLength          : UInt32?,
        windowNumberRoundTrip   : Bool,
        ownerConnectionRoundTrip: Bool,
        windowLocationRoundTrip : Bool,
        failure                 : SystemFailure?
    ) {
        self.declaredLength           = declaredLength
        self.windowNumberRoundTrip    = windowNumberRoundTrip
        self.ownerConnectionRoundTrip = ownerConnectionRoundTrip
        self.windowLocationRoundTrip  = windowLocationRoundTrip
        self.failure                  = failure
    }

    /// The reason string a Facility puts in `unavailable(reason:)`.
    public var failureReason: String? {
        if let failure { return "\(failure)" }
        guard !passed else { return nil }
        var missing: [String] = []
        if !windowNumberRoundTrip    { missing.append("0x3C") }
        if !ownerConnectionRoundTrip { missing.append("0x40") }
        if !windowLocationRoundTrip  { missing.append("0x20/0x28") }
        return "record offsets did not round trip: \(missing.joined(separator: ", "))"
    }
}
