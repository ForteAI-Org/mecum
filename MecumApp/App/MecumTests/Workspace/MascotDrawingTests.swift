//
//  MascotDrawingTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import Testing
@testable import Mecum

/// The drawing input, which is where "the mascot does not change between
/// relaunches" is decided. What a renderer then paints is not checked here.
@Suite("Mascot drawing input")
struct MascotDrawingTests {

    @Test("The same appearance yields the same drawing input")
    func derivationIsDeterministic() {
        let appearance = WorkerAppearance(
            seed            : Int64(bitPattern: 0xDEAD_BEEF_CAFE_F00D),
            generatorVersion: MascotDrawing.generatorVersion,
            palette         : "tide",
            roundness       : 0.25,
            wobble          : 0.75,
            glow            : 0.4
        )

        #expect(MascotDrawing(appearance) == MascotDrawing(appearance))

        var other = appearance
        other.seed = appearance.seed &+ 1
        #expect(MascotDrawing(other).hue != MascotDrawing(appearance).hue)
    }

    @Test("An unknown palette still draws, with the fallback family")
    func unknownPaletteFallsBack() {
        let known = WorkerAppearance(seed: 7, palette: MascotPalette.fallback.name)
        let gone  = WorkerAppearance(seed: 7, palette: "a palette that was retuned away")

        #expect(MascotDrawing(gone) == MascotDrawing(known))
        #expect(MascotPalette.named("dusk").name == "dusk")
    }

    @Test("Shape parameters from outside the unit range are brought back")
    func shapeParametersAreClamped() {
        let wild = WorkerAppearance(
            seed     : 3,
            palette  : "moss",
            roundness: -4,
            wobble   : 9,
            glow     : .nan
        )
        let drawing = MascotDrawing(wild)

        #expect(abs(drawing.radiusFraction - 0.30) < 1e-9)
        #expect(abs(drawing.highlightSpread - 0.65) < 1e-9)
        #expect(drawing.glow == 0.5)
        #expect((0...1).contains(drawing.hue))
    }
}
