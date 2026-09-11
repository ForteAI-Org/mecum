//
//  RecordLayoutTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import PrivateSymbols
import Testing

/// Synthetic buffers only: no `CGEvent` and no system record is touched here.
/// What is under test is the arithmetic and the bounds, so that the host tier
/// can run the same reads against the real record and blame the system rather
/// than the code when they disagree.
@Suite("Record layout on synthetic buffers")
struct RecordLayoutTests {

    /// The measured map. These constants are the only place the
    /// numbers exist, and this test is what makes a typo in one of them loud.
    @Test("the offsets are the ones the probe measured on 26A5425a")
    func measuredMap() {
        #expect(RecordLayout.lengthOffset          == 0x04)
        #expect(RecordLayout.declaredLength        == 0xF8)   // 248 in the JSON
        #expect(RecordLayout.allocatedLength       == 0x100)  // 256, the yabai lesson
        #expect(RecordLayout.typeOffset            == 0x08)
        #expect(RecordLayout.localPointXOffset     == 0x20)
        #expect(RecordLayout.localPointYOffset     == 0x28)
        #expect(RecordLayout.flagsOffset           == 0x3A)
        #expect(RecordLayout.windowNumberOffset    == 0x3C)
        #expect(RecordLayout.ownerConnectionOffset == 0x40)
        #expect(RecordLayout.windowNumberField     == 51)
        #expect(RecordLayout.ownerConnectionField  == 52)
    }

    /// The rule at 0x08, written once and asserted across the table rather than
    /// as two numbers in whichever file needed them.
    ///
    /// The values on the right are the ones read back out of records
    /// CoreGraphics built. Nothing here derives them from the enumeration a
    /// second time: that would assert the rule against itself.
    @Test("the type byte is the event type's raw value, for the whole table")
    func theTypeByteRule() {
        #expect(RecordLayout.typeByte(of: .leftMouseDown)   == 0x01)
        #expect(RecordLayout.typeByte(of: .leftMouseUp)     == 0x02)
        #expect(RecordLayout.typeByte(of: .rightMouseDown)  == 0x03)
        #expect(RecordLayout.typeByte(of: .rightMouseUp)    == 0x04)
        #expect(RecordLayout.typeByte(of: .mouseMoved)      == 0x05)
        #expect(RecordLayout.typeByte(of: .leftMouseDragged) == 0x06)
        #expect(RecordLayout.typeByte(of: .keyDown)         == 0x0A)
        #expect(RecordLayout.typeByte(of: .keyUp)           == 0x0B)
        #expect(RecordLayout.typeByte(of: .scrollWheel)     == 0x16)
    }

    @Test("a record the kit builds is 256 bytes long and declares 248")
    func allocatedRecord() throws {
        var record = RecordLayout.makeRecord()
        #expect(record.count == 0x100)
        try record.withUnsafeMutableBytes { bytes in
            let base = try #require(bytes.baseAddress)
            #expect(try RecordLayout.validateDeclaredLength(of: base, length: bytes.count) == 0xF8)
            // Everything but the length is zero, including the eight bytes past
            // the declared end.
            #expect(bytes.dropFirst(0x08).allSatisfy { $0 == 0 })
        }
    }

    @Test("a record that declares another length is refused")
    func wrongDeclaredLength() throws {
        var record = [UInt8](repeating: 0, count: RecordLayout.allocatedLength)
        record.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt32(0xF0), toByteOffset: RecordLayout.lengthOffset, as: UInt32.self)
        }
        try record.withUnsafeMutableBytes { bytes in
            let base = try #require(bytes.baseAddress)
            #expect(throws: SystemFailure.unsupportedRecordLength(declared: 0xF0, expected: 0xF8)) {
                try RecordLayout.validateDeclaredLength(of: base, length: bytes.count)
            }
        }
    }

    @Test("the routed fields write and read back where the probe found them")
    func routedFieldsRoundTrip() throws {
        var record = RecordLayout.makeRecord()
        try record.withUnsafeMutableBytes { bytes in
            let base = try #require(bytes.baseAddress)
            let length = bytes.count

            try RecordLayout.write(
                UInt32(0x7E7F_8081),
                at    : RecordLayout.windowNumberOffset,
                into  : base,
                length: length
            )
            try RecordLayout.write(
                UInt32(0x8E8F_9091),
                at    : RecordLayout.ownerConnectionOffset,
                into  : base,
                length: length
            )
            try RecordLayout.write(
                55.5,
                at    : RecordLayout.localPointXOffset,
                into  : base,
                length: length
            )
            try RecordLayout.write(
                66.25,
                at    : RecordLayout.localPointYOffset,
                into  : base,
                length: length
            )

            #expect(try RecordLayout.read(
                UInt32.self, at: RecordLayout.windowNumberOffset, from: base, length: length
            ) == 0x7E7F_8081)
            #expect(try RecordLayout.read(
                UInt32.self, at: RecordLayout.ownerConnectionOffset, from: base, length: length
            ) == 0x8E8F_9091)
            #expect(try RecordLayout.read(
                Double.self, at: RecordLayout.localPointXOffset, from: base, length: length
            ) == 55.5)
            #expect(try RecordLayout.read(
                Double.self, at: RecordLayout.localPointYOffset, from: base, length: length
            ) == 66.25)

            // The declared length is untouched by the writes: the guard the
            // Facility re-runs on every record still holds.
            #expect(try RecordLayout.validateDeclaredLength(of: base, length: length) == 0xF8)
        }
    }

    @Test("the window number is written little endian, as the WindowServer reads it")
    func littleEndianWindowNumber() throws {
        var record = RecordLayout.makeRecord()
        try record.withUnsafeMutableBytes { bytes in
            let base = try #require(bytes.baseAddress)
            try RecordLayout.write(
                UInt32(0x7E7F_8081),
                at    : RecordLayout.windowNumberOffset,
                into  : base,
                length: bytes.count
            )
        }
        #expect(Array(record[0x3C..<0x40]) == [0x81, 0x80, 0x7F, 0x7E])
    }

    @Test("a read or write past the record throws instead of scribbling")
    func boundsAreChecked() throws {
        var record = [UInt8](repeating: 0, count: Int(RecordLayout.declaredLength))
        try record.withUnsafeMutableBytes { bytes in
            let base = try #require(bytes.baseAddress)
            let length = bytes.count

            #expect(throws: SystemFailure.recordOffsetOutOfBounds(offset: 0xF6, width: 4, length: 0xF8)) {
                try RecordLayout.write(UInt32(1), at: 0xF6, into: base, length: length)
            }
            #expect(throws: SystemFailure.recordOffsetOutOfBounds(offset: -1, width: 4, length: 0xF8)) {
                try RecordLayout.write(UInt32(1), at: -1, into: base, length: length)
            }
            #expect(throws: SystemFailure.recordOffsetOutOfBounds(offset: 0xF1, width: 8, length: 0xF8)) {
                _ = try RecordLayout.read(Double.self, at: 0xF1, from: base, length: length)
            }
            // The last aligned word inside the record is legal.
            #expect(throws: Never.self) {
                try RecordLayout.write(UInt32(1), at: 0xF4, into: base, length: length)
            }
        }
    }

    @Test("a check with a short record cannot pass")
    func checkNeedsTheDeclaredLength() {
        let short = RecordLayoutCheck(
            declaredLength          : 0xF0,
            windowNumberRoundTrip   : true,
            ownerConnectionRoundTrip: true,
            windowLocationRoundTrip : true,
            failure                 : nil
        )
        #expect(!short.passed)
    }

    @Test("a check names the offsets that did not come back")
    func checkNamesTheOffsets() {
        let partial = RecordLayoutCheck(
            declaredLength          : 0xF8,
            windowNumberRoundTrip   : true,
            ownerConnectionRoundTrip: false,
            windowLocationRoundTrip : false,
            failure                 : nil
        )
        #expect(!partial.passed)
        #expect(partial.failureReason == "record offsets did not round trip: 0x40, 0x20/0x28")

        let whole = RecordLayoutCheck(
            declaredLength          : 0xF8,
            windowNumberRoundTrip   : true,
            ownerConnectionRoundTrip: true,
            windowLocationRoundTrip : true,
            failure                 : nil
        )
        #expect(whole.passed)
        #expect(whole.failureReason == nil)
    }

    @Test("a structured failure wins over the derived sentence")
    func checkKeepsTheStructuredFailure() {
        let broken = RecordLayoutCheck(
            declaredLength          : nil,
            windowNumberRoundTrip   : false,
            ownerConnectionRoundTrip: false,
            windowLocationRoundTrip : false,
            failure                 : .eventRecordUnavailable
        )
        #expect(!broken.passed)
        #expect(broken.failureReason == "eventRecordUnavailable")
    }
}
