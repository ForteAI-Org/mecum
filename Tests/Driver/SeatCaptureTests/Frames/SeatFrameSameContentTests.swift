//
//  SeatFrameSameContentTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import SeatCore
@testable import SeatCapture
import Testing

@Suite("The byte-exact comparison of two frames")
struct SeatFrameSameContentTests {

    private static let window = FrameSourceIdentity.unverifiedWindow(windowNumber: 41)

    @Test("two frames with the same facts and the same bytes show the same content")
    func identicalFramesMatch() throws {
        let first  = try #require(makeFakeFrame(width: 33, height: 9, receivedAt: 1, source: Self.window))
        let second = try #require(makeFakeFrame(width: 33, height: 9, receivedAt: 2, displayTime: 9, source: Self.window))
        try paint(first, seed: 5)
        try paint(second, seed: 5)
        #expect(first.showsSameContent(as: second))
        #expect(first.showsSameContent(as: first))
    }

    @Test("one byte of difference anywhere is another content", arguments: [0, 545, 1187])
    func oneByteDiffers(offset: Int) throws {
        let first  = try #require(makeFakeFrame(width: 33, height: 9, source: Self.window))
        let second = try #require(makeFakeFrame(width: 33, height: 9, source: Self.window))
        try paint(first, seed: 5)
        try paint(second, seed: 5)
        try poke(second, at: offset)
        #expect(!first.showsSameContent(as: second))
        #expect(!second.showsSameContent(as: first))
    }

    @Test("another window or another size is another content, whatever the bytes")
    func identityAndSizeDiffer() throws {
        let first = try #require(makeFakeFrame(width: 16, height: 8, source: Self.window))
        let other = try #require(makeFakeFrame(
            width : 16,
            height: 8,
            source: .unverifiedWindow(windowNumber: 42)
        ))
        let larger = try #require(makeFakeFrame(width: 16, height: 9, source: Self.window))
        #expect(!first.showsSameContent(as: other))
        #expect(!first.showsSameContent(as: larger))
    }

    @Test("another rectangle on screen, another content rectangle or another scale is another content")
    func geometryDiffers() throws {
        let first = try #require(makeFakeFrame(width: 16, height: 8, source: Self.window))
        let moved = try reframed(first) { $0.screenRect = $0.screenRect.offsetBy(dx: 1, dy: 0) }
        let cropped = try reframed(first) { $0.contentRectInSurface = $0.contentRectInSurface.insetBy(dx: 1, dy: 0) }
        let rescaled = try reframed(first) { $0.scaleFactor = 2 }
        let resampled = try reframed(first) { $0.contentScale = 0.5 }
        #expect(first.showsSameContent(as: try reframed(first) { _ in }))
        #expect(!first.showsSameContent(as: moved))
        #expect(!first.showsSameContent(as: cropped))
        #expect(!first.showsSameContent(as: rescaled))
        #expect(!first.showsSameContent(as: resampled))
    }

    @Test("a pixel format other than 32BGRA is never compared")
    func otherFormatDiffers() throws {
        let first = try #require(makeFakeFrame(width: 16, height: 8, source: Self.window))
        var unmanaged: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 16, 8, kCVPixelFormatType_32ARGB, attributes, &unmanaged) == kCVReturnSuccess)
        let argb = try #require(unmanaged)
        let other = SeatFrame(
            surface          : first.surface,
            pixelBuffer      : argb,
            presentationTime : first.presentationTime,
            receivedAt       : first.receivedAt,
            displayGeneration: first.displayGeneration,
            source           : first.source,
            geometry         : first.geometry
        )
        #expect(!first.showsSameContent(as: other))
        #expect(!other.showsSameContent(as: first))
    }

    @Test("a bitmap that cannot be read is never the same, and padded rows compare by their used bytes")
    func unreadableAndPaddedRows() {
        var first  = [UInt8](repeating: 1, count: 24)
        var second = [UInt8](repeating: 1, count: 32)
        first.withUnsafeBytes { a in
            second.withUnsafeMutableBytes { b in
                // Rows of 8 used bytes, padded to 12 and to 16; the padding differs and does not count.
                for row in 0..<2 { b[row * 16 + 12] = 9 }
                #expect(SeatFrame.sameRows(a.baseAddress, bytesPerRow: 12, UnsafeRawPointer(b.baseAddress),
                                           bytesPerRow: 16, usedBytesPerRow: 8, rows: 2))
                b[16 + 3] = 2
                #expect(!SeatFrame.sameRows(a.baseAddress, bytesPerRow: 12, UnsafeRawPointer(b.baseAddress),
                                            bytesPerRow: 16, usedBytesPerRow: 8, rows: 2))
                #expect(!SeatFrame.sameRows(nil, bytesPerRow: 12, UnsafeRawPointer(b.baseAddress),
                                            bytesPerRow: 16, usedBytesPerRow: 8, rows: 2))
                #expect(!SeatFrame.sameRows(a.baseAddress, bytesPerRow: 12, nil,
                                            bytesPerRow: 16, usedBytesPerRow: 8, rows: 2))
                #expect(!SeatFrame.sameRows(a.baseAddress, bytesPerRow: 12, UnsafeRawPointer(b.baseAddress),
                                            bytesPerRow: 16, usedBytesPerRow: 13, rows: 2))
            }
        }
    }

    private func paint(_ frame: SeatFrame, seed: Int) throws {
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer))
        let count = CVPixelBufferGetBytesPerRow(frame.pixelBuffer) * CVPixelBufferGetHeight(frame.pixelBuffer)
        for byte in 0..<count {
            base.storeBytes(of: UInt8(truncatingIfNeeded: byte * seed), toByteOffset: byte, as: UInt8.self)
        }
    }

    /// Changes the pixel byte `usedByte`, counted over the used bytes of each row, never the padding.
    private func poke(_ frame: SeatFrame, at usedByte: Int) throws {
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer))
        let usedBytesPerRow = CVPixelBufferGetWidth(frame.pixelBuffer) * 4
        let offset = usedByte / usedBytesPerRow * CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
            + usedByte % usedBytesPerRow
        let byte = base.load(fromByteOffset: offset, as: UInt8.self)
        base.storeBytes(of: byte &+ 1, toByteOffset: offset, as: UInt8.self)
    }

    /// The same frame and bytes, with one geometry fact changed.
    private func reframed(_ frame: SeatFrame, _ change: (inout Facts) -> Void) throws -> SeatFrame {
        var facts = Facts(frame.geometry)
        change(&facts)
        return SeatFrame(
            surface          : frame.surface,
            pixelBuffer      : frame.pixelBuffer,
            presentationTime : frame.presentationTime,
            receivedAt       : frame.receivedAt,
            displayGeneration: frame.displayGeneration,
            source           : frame.source,
            geometry         : FrameGeometryObservation(
                source              : frame.geometry.source,
                screenRect          : facts.screenRect,
                contentRectInSurface: facts.contentRectInSurface,
                scaleFactor         : facts.scaleFactor,
                contentScale        : facts.contentScale,
                pixelSize           : frame.geometry.pixelSize,
                version             : GeometryObservationVersion(observerGeneration: 9, sequence: 9),
                capturesFullWindow  : frame.geometry.capturesFullWindow
            )
        )
    }

    private struct Facts {
        var screenRect          : CGRect
        var contentRectInSurface: CGRect
        var scaleFactor         : CGFloat
        var contentScale        : CGFloat

        init(_ geometry: FrameGeometryObservation) {
            screenRect           = geometry.screenRect
            contentRectInSurface = geometry.contentRectInSurface
            scaleFactor          = geometry.scaleFactor
            contentScale         = geometry.contentScale
        }
    }
}
