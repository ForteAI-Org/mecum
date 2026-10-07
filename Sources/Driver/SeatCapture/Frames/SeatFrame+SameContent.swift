//
//  SeatFrame+SameContent.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import CoreVideo
import Darwin
import SeatCore

nonisolated extension SeatFrame {

    /// showsSameContent answers true only when `other` is this Frame's picture again: the same
    /// source identity, the same pixel size, the same rectangle on screen and in the surface, the
    /// same scales, and equal pixel bytes (ADR 0034).
    ///
    /// It is an exact comparison, never a hash: a change of any one byte answers false, so a
    /// consumer that reuses what it read from `other` cannot miss a change that reached the pixels.
    /// It cannot see a change that drew nothing. Times, display generation and geometry version
    /// are not compared, since two observations of one unchanged window differ in all three. Any
    /// doubt answers false: a pixel format other than the 32BGRA the kit asks for, or a buffer
    /// that cannot be locked or has no base address. Both buffers are locked read-only for the
    /// call and nothing is retained. A 1 to 4 MB window costs one `memcmp` per row.
    package func showsSameContent(as other: SeatFrame) -> Bool {
        guard source == other.source,
              pixelSize == other.pixelSize,
              geometry.pixelSize == other.geometry.pixelSize,
              geometry.screenRect == other.geometry.screenRect,
              geometry.sourceWindowFrame == other.geometry.sourceWindowFrame,
              geometry.contentRectInSurface == other.geometry.contentRectInSurface,
              geometry.scaleFactor == other.geometry.scaleFactor,
              geometry.contentScale == other.geometry.contentScale,
              geometry.capturesFullWindow == other.geometry.capturesFullWindow,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(other.pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return false }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(other.pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(other.pixelBuffer, .readOnly) }

        return Self.sameRows(
            CVPixelBufferGetBaseAddress(pixelBuffer).map { UnsafeRawPointer($0) },
            bytesPerRow     : CVPixelBufferGetBytesPerRow(pixelBuffer),
            CVPixelBufferGetBaseAddress(other.pixelBuffer).map { UnsafeRawPointer($0) },
            bytesPerRow     : CVPixelBufferGetBytesPerRow(other.pixelBuffer),
            usedBytesPerRow : CVPixelBufferGetWidth(pixelBuffer) * 4,
            rows            : CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    /// sameRows compares the first `usedBytesPerRow` bytes of `rows` rows of two bitmaps whose
    /// rows may be padded differently. A missing base address, or a row wider than either
    /// bitmap's row, is a bitmap that cannot be read and answers false.
    static func sameRows(
        _ first             : UnsafeRawPointer?,
        bytesPerRow firstRow: Int,
        _ second            : UnsafeRawPointer?,
        bytesPerRow secondRow: Int,
        usedBytesPerRow     : Int,
        rows                : Int
    ) -> Bool {
        guard let first, let second, usedBytesPerRow > 0, rows > 0,
              usedBytesPerRow <= firstRow, usedBytesPerRow <= secondRow
        else { return false }
        if firstRow == secondRow, firstRow == usedBytesPerRow {
            return memcmp(first, second, usedBytesPerRow * rows) == 0
        }
        for row in 0..<rows
        where memcmp(first.advanced(by: row * firstRow), second.advanced(by: row * secondRow), usedBytesPerRow) != 0 {
            return false
        }
        return true
    }
}
