//
//  TextSizeAndAccentTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Testing
@testable import Mecum

@Suite("Text size steps and the accent under the person's text")
struct TextSizeAndAccentTests {

    @Test("Bigger and Smaller step through the sizes, stop at both ends, and Actual Size is 14 points")
    func textSizeStepsAndResets() throws {
        #expect(TranscriptStyle.actualSize.bodyPointSize == 14)
        #expect(TranscriptStyle.actualSize == TranscriptStyle())
        #expect(TranscriptStyle.actualSize.smaller == nil)

        var style   = TranscriptStyle.actualSize
        var visited = [style.bodyPointSize]
        while let next = style.bigger {
            style = next
            visited.append(style.bodyPointSize)
        }
        #expect(visited == TranscriptStyle.bodyPointSizes)
        #expect(style.bodyPointSize == 24)

        let back = try #require(style.smaller)
        #expect(back.bodyPointSize == 22)
        // A size between two steps moves to the neighbouring steps, never to itself.
        let between = TranscriptStyle(bodyPointSize: 17)
        #expect(between.bigger?.bodyPointSize == 18)
        #expect(between.smaller?.bodyPointSize == 16)
    }

    @Test("A light accent is darkened until white text reads on it, and its hue is kept")
    func aLightAccentIsAdaptedWithItsHueKept() throws {
        let yellow = (red: CGFloat(1.0), green: CGFloat(0.8), blue: CGFloat(0.0))
        #expect(TranscriptColors.contrastWithWhite(yellow.red, yellow.green, yellow.blue) < 2)

        let adapted = TranscriptColors.readableUnderWhite(red: yellow.red, green: yellow.green, blue: yellow.blue)
        let ratio   = TranscriptColors.contrastWithWhite(adapted.red, adapted.green, adapted.blue)
        #expect(ratio >= TranscriptColors.minimumContrastOnAccent)
        #expect(ratio < TranscriptColors.minimumContrastOnAccent + 0.05)

        let before = try #require(NSColor(srgbRed: yellow.red, green: yellow.green, blue: yellow.blue, alpha: 1)
            .usingColorSpace(.sRGB))
        let after  = try #require(NSColor(srgbRed: adapted.red, green: adapted.green, blue: adapted.blue, alpha: 1)
            .usingColorSpace(.sRGB))
        #expect(abs(before.hueComponent - after.hueComponent) < 0.001)
        #expect(abs(before.saturationComponent - after.saturationComponent) < 0.001)
        #expect(after.brightnessComponent < before.brightnessComponent)

        // An accent already dark enough is left as it is.
        let dark = TranscriptColors.readableUnderWhite(red: 0.1, green: 0.2, blue: 0.6)
        #expect(dark.red == 0.1 && dark.green == 0.2 && dark.blue == 0.6)
    }
}
