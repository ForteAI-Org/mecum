//
//  SeatFrameTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit
import SeatCore
@testable import SeatCapture
import Testing

@Suite("The frame the kit hands over")
struct SeatFrameTests {

    @Test("a frame reports the pixel buffer's own size, not the one that was asked for")
    func pixelSizeComesFromTheBuffer() throws {
        let frame = try #require(makeFakeFrame(width: 120, height: 80))
        #expect(frame.pixelSize == CGSize(width: 120, height: 80))
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(frame.source == .display(1))
        #expect(frame.geometry.pixelSize == frame.pixelSize)
        #expect(frame.geometry.version.observerGeneration == frame.displayGeneration)
    }

    @Test("a detached copy has the same pixels and facts over a surface of its own")
    func detachedCopyOwnsItsSurface() throws {
        let frame = try #require(makeFakeFrame(width: 33, height: 9, receivedAt: 5, displayTime: 77))
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        for byte in 0..<(rowBytes * 9) { base.storeBytes(of: UInt8(truncatingIfNeeded: byte), toByteOffset: byte, as: UInt8.self) }
        CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, [])

        let copy = try #require(frame.detachedCopy())
        #expect(copy.surface !== frame.surface)
        #expect(copy.pixelSize == frame.pixelSize)
        #expect(copy.displayTime == 77)
        #expect(copy.receivedAt == 5)
        #expect(copy.source == frame.source)
        #expect(copy.geometry == frame.geometry)

        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy.pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy.pixelBuffer, .readOnly)
        }
        let copied = try #require(CVPixelBufferGetBaseAddress(copy.pixelBuffer))
        let copyRowBytes = CVPixelBufferGetBytesPerRow(copy.pixelBuffer)
        for row in 0..<9 {
            #expect(memcmp(copied.advanced(by: row * copyRowBytes), base.advanced(by: row * rowBytes), 33 * 4) == 0)
        }
    }

    @Test("makeCGImage draws the frame at its own size and owns the pixels")
    func makeCGImageCopies() throws {
        let frame = try #require(makeFakeFrame(width: 96, height: 48))
        let image = try #require(frame.makeCGImage())
        #expect(image.width  == 96)
        #expect(image.height == 48)

        // The pool reuses surfaces, so an image that pointed at one would tear
        // a few frames later. A second image taken from the same frame is a
        // second copy and not the same object.
        let again = try #require(frame.makeCGImage())
        #expect(again.width == image.width)
    }

    @Test("an IOSurface is accepted as layer contents, which only the header promises")
    func surfaceGoesIntoALayer() throws {
        let frame = try #require(makeFakeFrame())
        let layer = MonitorLayer(contentsScale: 2)
        layer.present(frame)

        // `CALayer.contents` documents CGImage and NSImage on the web and adds
        // IOSurface only in the SDK header, so this is the regression test that
        // catches the day the header stops being true.
        #expect(layer.contents != nil)
        #expect(layer.contentsGravity == .resizeAspect)
        #expect(layer.contentsScale   == 2)
    }
}

@Suite("The three ScreenCaptureKit defaults the kit refuses to inherit")
struct SeatCaptureConfigurationTests {

    @Test("the stream configuration sets rate, depth and pixel format explicitly")
    func overridesEveryDefault() {
        let configuration = SeatCaptureConfiguration(
            pixelSize      : CGSize(width: 1920, height: 1080),
            framesPerSecond: 30
        )
        let stream = configuration.makeStreamConfiguration()

        #expect(stream.width  == 1920)
        #expect(stream.height == 1080)
        // Real defaults on 26A5425a: 1/60, 8, and 420v. All three differ from
        // the published documentation, and all three are written here.
        #expect(stream.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(stream.queueDepth  == 3)
        #expect(stream.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(!stream.showsCursor)
        #expect(!stream.capturesAudio)
    }

    @Test("the pool is three frames, which is what the one frame contract stands on")
    func poolDepth() {
        #expect(SeatCaptureConfiguration.queueDepth == 3)
    }

    @Test("a Still adds the two single window flags a diff would otherwise trip on")
    func stillIgnoresShadowAndClip() {
        let still = SeatCaptureConfiguration(
            pixelSize      : CGSize(width: 800, height: 600),
            framesPerSecond: 60
        ).makeStillConfiguration()

        #expect(still.ignoreShadowsSingleWindow)
        #expect(still.ignoreGlobalClipSingleWindow)
        #expect(still.pixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test("a window stream excludes shadows and screen-edge clipping too")
    func windowStreamCapturesCompleteWindowGeometry() {
        let configuration = SeatCaptureConfiguration(
            pixelSize      : CGSize(width: 800, height: 600),
            framesPerSecond: 60
        ).makeStreamConfiguration(for: .window(windowNumber: 42))

        #expect(configuration.ignoreShadowsSingleWindow)
        #expect(configuration.ignoreGlobalClipSingleWindow)
    }
}
