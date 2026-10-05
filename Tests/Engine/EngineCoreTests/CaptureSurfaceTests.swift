//
//  CaptureSurfaceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import EngineCore
import PerceptionCore
import Testing

@Suite("The surface of one capture")
struct CaptureSurfaceTests {

    @Test("a surface is classified from the tree's role and subrole, and never guessed")
    func classification() {
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXStandardWindow") == .window)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXFloatingWindow") == .window)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXDialog") == .dialog)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXSystemDialog") == .dialog)
        #expect(CaptureSurface.classified(role: "AXSheet", subrole: nil) == .sheet)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXSheet") == .sheet)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: nil) == .unknown)
        #expect(CaptureSurface.classified(role: "AXWindow", subrole: "AXUnknown") == .unknown)
        #expect(CaptureSurface.classified(role: nil, subrole: nil) == .unknown)
        #expect(CaptureSurface.classified(role: "AXGroup", subrole: "AXDialog") == .unknown)
        #expect(CaptureSurface.popupUnion.rawValue == "popup_union")
    }

    @Test("a perceived window without a stated capture is unknown on both counts, and equality sees what a provider stated")
    func perceivedWindowDefaults() {
        let scene = SceneSnapshot(bundleID: "x", appName: "X", windowTitle: "W",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let plain = PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(plain.capture == .unknown)
        #expect(plain.surface == .unknown)
        let stated = PerceivedWindow(scene: scene, frame: plain.frame,
                                     capture: CaptureQuality(walkCompleted: true, windowFound: true), surface: .dialog)
        #expect(stated != plain)
        #expect(stated.capture.isComplete)
    }
}
