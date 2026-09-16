//
//  SIMDByteComparison.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import Foundation

/// SIMDByteComparison performs exact equality over two bounded byte regions.
///
/// The comparison uses unaligned vector loads only while a complete vector is
/// available, then checks the remaining bytes without reading past either
/// region. Exact equality, rather than a hash, is required for layout cache
/// identity because one changed source byte must invalidate the translated
/// keyboard rows.
nonisolated package enum SIMDByteComparison {

    /// Compares every byte in two `Data` values without assuming alignment.
    package static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { lhsBytes in
            rhs.withUnsafeBytes { rhsBytes in
                equal(lhsBytes, rhsBytes)
            }
        }
    }

    /// Compares two borrowed buffers. Neither buffer is retained after return.
    package static func equal(
        _ lhs: UnsafeRawBufferPointer,
        _ rhs: UnsafeRawBufferPointer
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard lhs.count > 0 else { return true }
        guard let lhsBase = lhs.baseAddress, let rhsBase = rhs.baseAddress else { return false }

        var offset = 0
        while lhs.count - offset >= 64 {
            let lhs0 = lhsBase.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let rhs0 = rhsBase.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let lhs1 = lhsBase.loadUnaligned(fromByteOffset: offset + 16, as: SIMD16<UInt8>.self)
            let rhs1 = rhsBase.loadUnaligned(fromByteOffset: offset + 16, as: SIMD16<UInt8>.self)
            let lhs2 = lhsBase.loadUnaligned(fromByteOffset: offset + 32, as: SIMD16<UInt8>.self)
            let rhs2 = rhsBase.loadUnaligned(fromByteOffset: offset + 32, as: SIMD16<UInt8>.self)
            let lhs3 = lhsBase.loadUnaligned(fromByteOffset: offset + 48, as: SIMD16<UInt8>.self)
            let rhs3 = rhsBase.loadUnaligned(fromByteOffset: offset + 48, as: SIMD16<UInt8>.self)
            let differences = (lhs0 ^ rhs0) | (lhs1 ^ rhs1) | (lhs2 ^ rhs2) | (lhs3 ^ rhs3)
            guard differences.max() == 0 else { return false }
            offset += 64
        }
        while lhs.count - offset >= 16 {
            let lhsVector  = lhsBase.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let rhsVector  = rhsBase.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let difference = lhsVector ^ rhsVector
            guard difference.max() == 0 else { return false }
            offset += 16
        }
        while offset < lhs.count {
            guard lhsBase.load(fromByteOffset: offset, as: UInt8.self)
                    == rhsBase.load(fromByteOffset: offset, as: UInt8.self)
            else {
                return false
            }
            offset += 1
        }
        return true
    }
}
