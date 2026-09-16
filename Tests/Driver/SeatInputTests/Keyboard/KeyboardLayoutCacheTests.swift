//
//  KeyboardLayoutCacheTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
@testable import SeatInput
import Testing

@Suite("SIMD byte comparison")
struct SIMDByteComparisonTests {

    @Test(
        "equal buffers around every vector boundary compare exactly",
        arguments: [0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128]
    )
    func vectorBoundaries(length: Int) {
        let bytes = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 29) })

        #expect(SIMDByteComparison.equal(bytes, bytes))
    }

    @Test(
        "a late mismatch is found around every vector boundary",
        arguments: [1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128]
    )
    func lateMismatch(length: Int) {
        let lhs = Data(repeating: 0x5a, count: length)
        var rhs = lhs
        rhs[length - 1] = 0xa5

        #expect(!SIMDByteComparison.equal(lhs, rhs))
    }

    @Test("unaligned borrowed slices use the same exact comparison")
    func unalignedSlices() {
        var lhs = [UInt8](repeating: 0, count: 70)
        var rhs = [UInt8](repeating: 0, count: 71)
        for index in 0..<65 {
            let value = UInt8(truncatingIfNeeded: index &* 17)
            lhs[index + 1] = value
            rhs[index + 2] = value
        }

        lhs.withUnsafeBytes { lhsStorage in
            rhs.withUnsafeBytes { rhsStorage in
                let lhsSlice = UnsafeRawBufferPointer(
                    start: lhsStorage.baseAddress?.advanced(by: 1),
                    count: 65
                )
                let rhsSlice = UnsafeRawBufferPointer(
                    start: rhsStorage.baseAddress?.advanced(by: 2),
                    count: 65
                )
                #expect(SIMDByteComparison.equal(lhsSlice, rhsSlice))
            }
        }
    }

    @Test("embedded zeros and Unicode bytes remain ordinary bytes")
    func embeddedZerosAndUnicode() {
        let unicode = Array("aé⌨️漢字".utf8)
        let lhs = Data([0, 0xff, 0] + unicode + [0, 0x80, 0])
        var rhs = lhs

        #expect(SIMDByteComparison.equal(lhs, rhs))
        rhs[rhs.index(before: rhs.endIndex)] = 1
        #expect(!SIMDByteComparison.equal(lhs, rhs))
    }

    @Test("different lengths and two empty buffers are handled without a load")
    func emptyAndLengthMismatch() {
        #expect(SIMDByteComparison.equal(Data(), Data()))
        #expect(!SIMDByteComparison.equal(Data([1]), Data([1, 2])))
    }
}

@Suite("Keyboard layout cache")
struct KeyboardLayoutCacheTests {

    @Test("an unchanged source reuses translation and keeps its generation")
    func unchangedSourceIsReused() {
        var cache        = KeyboardLayoutCache()
        var translations = 0
        let source = Self.source(id: "test.same", bytes: [1, 2, 3], keyboardType: 42)

        let first = cache.layout(for: source) { _, _ in
            translations += 1
            return Self.rows
        }
        let second = cache.layout(for: source) { _, _ in
            translations += 1
            return Self.rows
        }

        #expect(translations == 1)
        #expect(first == second)
        #expect(first?.generation == 1)
    }

    @Test("id, exact source bytes, keyboard type and table version invalidate the cache")
    func completeSourceIdentityInvalidates() {
        var cache        = KeyboardLayoutCache()
        var translations = 0
        let sources = [
            Self.source(id: "test.one", bytes: [1, 2], keyboardType: 40),
            Self.source(id: "test.two", bytes: [1, 2], keyboardType: 40),
            Self.source(id: "test.two", bytes: [1, 3], keyboardType: 40),
            Self.source(id: "test.two", bytes: [1, 3], keyboardType: 41),
            Self.source(
                id          : "test.two",
                bytes       : [1, 3],
                keyboardType: 41,
                tableVersion: KeyNames.version + 1
            ),
        ]

        let layouts = sources.compactMap { source in
            cache.layout(for: source) { _, _ in
                translations += 1
                return Self.rows
            }
        }

        #expect(translations == sources.count)
        #expect(layouts.map(\.generation) == [1, 2, 3, 4, 5])
    }

    @Test("a non-ASCII same-id edit invalidates even when translated rows agree")
    func sourceBytesDefineGeneration() {
        var cache        = KeyboardLayoutCache()
        var translations = 0
        let firstSource = Self.source(
            id          : "test.custom",
            bytes       : Array("layout-é".utf8),
            keyboardType: 42
        )
        let editedSource = Self.source(
            id          : "test.custom",
            bytes       : Array("layout-è".utf8),
            keyboardType: 42
        )

        let first = cache.layout(for: firstSource) { _, _ in
            translations += 1
            return Self.rows
        }
        let edited = cache.layout(for: editedSource) { _, _ in
            translations += 1
            return Self.rows
        }

        #expect(translations == 2)
        #expect(first?.generation == 1)
        #expect(edited?.generation == 2)
    }

    @Test("an unavailable source clears reuse and never returns the stale layout")
    func unavailableSourceClearsReuse() {
        var cache        = KeyboardLayoutCache()
        var translations = 0
        let source = Self.source(id: "test.available", bytes: [1], keyboardType: 42)

        let first = cache.layout(for: source) { _, _ in
            translations += 1
            return Self.rows
        }
        let unavailable = cache.layout(for: nil) { _, _ in
            translations += 1
            return Self.rows
        }
        let restored = cache.layout(for: source) { _, _ in
            translations += 1
            return Self.rows
        }

        #expect(first?.generation == 1)
        #expect(unavailable == nil)
        #expect(restored?.generation == 2)
        #expect(translations == 2)
    }

    @Test("a present but untranslatable source clears reuse")
    func untranslatableSourceClearsReuse() {
        var cache        = KeyboardLayoutCache()
        var translations = 0
        let valid   = Self.source(id: "test.valid", bytes: [1], keyboardType: 42)
        let invalid = Self.source(id: "test.invalid", bytes: [2], keyboardType: 42)

        let first = cache.layout(for: valid) { _, _ in
            translations += 1
            return Self.rows
        }
        let refused = cache.layout(for: invalid) { _, _ in
            translations += 1
            return [:]
        }
        let restored = cache.layout(for: valid) { _, _ in
            translations += 1
            return Self.rows
        }

        #expect(first?.generation == 1)
        #expect(refused == nil)
        #expect(restored?.generation == 2)
        #expect(translations == 3)
    }

    private static let rows: KeyboardLayoutCache.Rows = [
        []: [CGKeyCode(0): "a"],
        .shift: [CGKeyCode(0): "A"],
        .command: [CGKeyCode(0): "a"],
        [.command, .shift]: [CGKeyCode(0): "A"],
    ]

    private static func source(
        id          : String,
        bytes       : [UInt8],
        keyboardType: UInt32,
        tableVersion: Int = KeyNames.version
    ) -> KeyboardLayoutSource {
        KeyboardLayoutSource(
            inputSourceID: id,
            layoutData   : Data(bytes),
            keyboardType : keyboardType,
            tableVersion : tableVersion
        )
    }
}
