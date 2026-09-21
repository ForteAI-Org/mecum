//
//  MonitorLayerTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatCapture
import Testing

/// The rectangle the preview draws, which is the whole of what stops a frame
/// the capture did not fill from putting black on the person's monitor.
@Suite("What the monitor layer draws of a frame")
struct MonitorLayerTests {

    /// Measured on a window moved onto the Virtual Display: the window server
    /// publishes it shrinking while the window's own body stays 1291 by 949, so
    /// the stream's fixed buffer holds a small picture and black around it.
    static func geometry(
        content: CGRect,
        pixels : CGSize,
        scale  : CGFloat = 1,
        screen : CGRect  = CGRect(x: 2146, y: 1228, width: 1291, height: 949)
    ) -> FrameGeometryObservation {
        FrameGeometryObservation(
            source              : .display(1),
            screenRect          : screen,
            contentRectInSurface: content,
            scaleFactor         : scale,
            contentScale        : 1,
            pixelSize           : pixels,
            version             : GeometryObservationVersion(observerGeneration: 1, sequence: 1),
            capturesFullWindow  : false
        )
    }

    @Test("a frame that fills its buffer is drawn whole")
    func aFullFrameIsDrawnWhole() {
        let whole = MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 0, y: 0, width: 1291, height: 949),
            pixels : CGSize(width: 1291, height: 949)
        ))
        #expect(whole == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("a picture smaller than its buffer is drawn without the black around it")
    func aPartialFrameIsCropped() {
        // The stream was started for the full window and the window server is
        // publishing the shrink: 136 by 190 inside a buffer of 1291 by 949.
        let rect = MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 0, y: 0, width: 136, height: 190),
            pixels : CGSize(width: 1291, height: 949)
        ))
        #expect(abs(rect.width  - 136 / 1291.0) < 0.000_001)
        #expect(abs(rect.height - 190 / 949.0)  < 0.000_001)
        #expect(rect.origin == .zero)
    }

    @Test("the content rectangle is in points, so the surface it is measured against is too")
    func theRectangleIsNormalisedInPoints() {
        // A Retina source: 2596 by 1898 pixels is 1298 by 949 points, so a
        // content rectangle 649 points wide is half of it and not a quarter.
        let rect = MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 0, y: 0, width: 649, height: 949),
            pixels : CGSize(width: 2596, height: 1898),
            scale  : 2,
            screen : CGRect(x: 0, y: 0, width: 649, height: 949)
        ))
        #expect(abs(rect.width - 0.5) < 0.000_001)
        #expect(abs(rect.height - 1) < 0.000_001)
    }

    @Test("an offset picture is drawn where it is, not from the corner")
    func anOffsetPictureKeepsItsOrigin() {
        let rect = MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 100, y: 50, width: 400, height: 300),
            pixels : CGSize(width: 1000, height: 600)
        ))
        #expect(abs(rect.minX - 0.1) < 0.000_001)
        #expect(abs(rect.minY - 50 / 600.0) < 0.000_001)
    }

    @Test("a geometry the transform rules refuse is drawn whole rather than guessed at")
    func anInvalidGeometryFallsBack() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 0, y: 0, width: 2000, height: 949),
            pixels : CGSize(width: 1291, height: 949)
        )) == whole)
        #expect(MonitorLayer.contentsRect(of: Self.geometry(
            content: CGRect(x: 0, y: 0, width: 0, height: 0),
            pixels : CGSize(width: 1291, height: 949)
        )) == whole)
    }
}
