//
//  GeometryObservationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import Testing
@testable import SeatCore

@Suite("Geometry carried from a captured Frame into input")
struct GeometryObservationTests {

    private static let identity = WindowIdentity(
        process: ProcessIdentity(
            processID       : 42,
            serialNumberHigh: 7,
            serialNumberLow : 9
        ),
        windowNumber     : 117,
        ownerConnectionID: 31
    )

    private static func frame(
        source      : FrameSourceIdentity = .window(identity),
        screenRect  : CGRect = CGRect(x: 100, y: 200, width: 400, height: 300),
        contentRect : CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
        scaleFactor : CGFloat = 2,
        contentScale: CGFloat = 1,
        pixelSize   : CGSize = CGSize(width: 800, height: 600),
        capturesFullWindow: Bool = true
    ) -> FrameGeometryObservation {
        FrameGeometryObservation(
            source              : source,
            screenRect          : screenRect,
            contentRectInSurface: contentRect,
            scaleFactor         : scaleFactor,
            contentScale        : contentScale,
            pixelSize           : pixelSize,
            version             : GeometryObservationVersion(
                observerGeneration: 3,
                sequence          : 19
            ),
            capturesFullWindow  : capturesFullWindow
        )
    }

    @Test("a pixel in an identity-bound window maps through surface points")
    func pixelPointMapsToWindow() throws {
        let location = try #require(InputLocation(
            pixelPoint: CGPoint(x: 200, y: 100),
            observedIn: Self.frame()
        ))

        #expect(location.screenPoint == CGPoint(x: 200, y: 250))
        #expect(location.windowPointFromTop == CGPoint(x: 100, y: 50))
        #expect(location.observedGeometry?.window.identity == Self.identity)
        #expect(location.observedGeometry?.version.sequence == 19)
    }

    @Test("content padding is accounted for rather than treated as screen geometry")
    func contentPaddingMapsCorrectly() throws {
        let frame = Self.frame(
            contentRect : CGRect(x: 10, y: 20, width: 200, height: 150),
            contentScale: 0.5,
            pixelSize   : CGSize(width: 440, height: 340)
        )
        let location = try #require(InputLocation(
            pixelPoint: CGPoint(x: 220, y: 190),
            observedIn: frame
        ))

        #expect(location.screenPoint == CGPoint(x: 300, y: 350))
        #expect(location.windowPointFromTop == CGPoint(x: 200, y: 150))
    }

    @Test("display frames cannot authorize arbitrary window input")
    func displayFrameIsNotWindowAuthority() {
        let frame = Self.frame(source: .display(8))
        #expect(frame.windowObservation == nil)
        #expect(InputLocation(pixelPoint: CGPoint(x: 20, y: 20), observedIn: frame) == nil)
    }

    @Test("a raw window number remains unverified provenance")
    func rawWindowFrameIsNotAuthority() {
        let frame = Self.frame(source: .unverifiedWindow(windowNumber: 117))
        #expect(frame.windowObservation == nil)
    }

    @Test("uniform ratios do not prove a complete window without capture flags")
    func shadowOrClipAmbiguityIsRefused() {
        let frame = Self.frame(capturesFullWindow: false)
        #expect(frame.hasUniformWindowMapping)
        #expect(frame.windowObservation == nil)
    }

    @Test("nonfinite geometry and points are refused")
    func nonfiniteValuesAreRefused() {
        let invalidFrame = Self.frame(
            screenRect: CGRect(x: CGFloat.nan, y: 0, width: 400, height: 300)
        )

        #expect(!invalidFrame.isValid)
        #expect(invalidFrame.screenPoint(fromPixelPoint: .zero) == nil)
        #expect(Self.frame().screenPoint(fromPixelPoint: CGPoint(x: CGFloat.infinity, y: 0)) == nil)

        let overflowingFrame = Self.frame(
            screenRect: CGRect(
                x     : CGFloat.greatestFiniteMagnitude,
                y     : 0,
                width : CGFloat.greatestFiniteMagnitude,
                height: 300
            )
        )
        #expect(!overflowingFrame.isValid)
    }

    @Test("points outside captured content are refused")
    func contentBoundsAreEnforced() {
        let frame = Self.frame()
        #expect(frame.screenPoint(fromPixelPoint: CGPoint(x: -1, y: 20)) == nil)
        #expect(frame.screenPoint(fromPixelPoint: CGPoint(x: 800, y: 20)) == nil)
    }

    @Test("nonuniform output scaling is refused")
    func nonuniformScaleIsRefused() {
        let frame = Self.frame(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 150)
        )

        #expect(frame.isValid)
        #expect(!frame.hasUniformWindowMapping)
        #expect(InputLocation(pixelPoint: CGPoint(x: 20, y: 20), observedIn: frame) == nil)
    }

    @Test("direct coordinates require an attested reference and observed scale")
    func directObservationRejectsRawReference() {
        let raw = WindowReference(
            processID   : 42,
            windowNumber: 117,
            frame       : CGRect(x: 100, y: 200, width: 400, height: 300)
        )

        #expect(WindowGeometryObservation(
            window     : raw,
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 1, sequence: 1)
        ) == nil)
    }
}
