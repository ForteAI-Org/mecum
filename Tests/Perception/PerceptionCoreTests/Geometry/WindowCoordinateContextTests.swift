//
//  WindowCoordinateContextTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

@Suite("Window coordinate context")
struct WindowCoordinateContextTests {

    // Window origin (100, 50) points, Retina scale 2, captured image 800 by 600 pixels.
    private let context = WindowCoordinateContext(
        windowOrigin  : CGPoint(x: 100, y: 50),
        backingScale  : 2.0,
        imagePixelSize: CGSize(width: 800, height: 600)
    )

    @Test("global point to image pixel, by hand")
    func globalToPixel() {
        #expect(context.imagePixel(fromGlobalPoint: CGPoint(x: 150, y: 100)) == CGPoint(x: 100, y: 100))
    }

    @Test("points and pixels round trip")
    func roundTrip() {
        let pixel = context.imagePixel(fromGlobalPoint: CGPoint(x: 150, y: 100))
        #expect(context.globalPoint(fromImagePixel: pixel) == CGPoint(x: 150, y: 100))
        let rect = CGRect(x: 150, y: 100, width: 40, height: 20)
        let pixels = context.imagePixelRect(fromGlobalRect: rect)
        #expect(pixels == CGRect(x: 100, y: 100, width: 80, height: 40))
        #expect(context.globalRect(fromImagePixelRect: pixels) == rect)
    }

    @Test("a bottom-left normalized box flips to top-left pixels")
    func bottomLeftFlips() {
        let box = CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)
        #expect(context.imagePixelRect(fromBottomLeftNormalized: box) == CGRect(x: 200, y: 150, width: 200, height: 150))
    }

    @Test("Cocoa screen conversions flip the right edge")
    func cocoaFlips() {
        #expect(cocoaScreenPoint(fromGlobalPoint: CGPoint(x: 10, y: 100), globalHeight: 900) == CGPoint(x: 10, y: 800))
        #expect(cocoaScreenRect(fromGlobalRect: CGRect(x: 10, y: 100, width: 20, height: 50), globalHeight: 900)
                == CGRect(x: 10, y: 750, width: 20, height: 50))
    }
}
