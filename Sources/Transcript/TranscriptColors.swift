//
//  TranscriptColors.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptColors holds the transcript's surfaces, each with a light and a
/// dark value. The person's bubble takes the workspace accent, which is the
/// system accent until a workspace stores its own; a mascot keeps its colour.
enum TranscriptColors {

    /// The contrast white body text needs on the person's bubble: WCAG AA for
    /// text at the 14 point body size, which is not large text.
    static let minimumContrastOnAccent = 4.5

    /// The accent under the person's white text. An accent too light for it,
    /// such as yellow, is darkened in brightness only, so its hue is kept (§3.2).
    static let personBubble = NSColor(name: "TranscriptPersonBubble") { appearance in
        var accent: NSColor?
        // The accent resolves per appearance, so it is read inside the one being drawn.
        appearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) }
        guard let accent else { return .controlAccentColor }
        let (red, green, blue) = readableUnderWhite(red: accent.redComponent, green: accent.greenComponent,
                                                    blue: accent.blueComponent)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// `red`, `green` and `blue` in sRGB, darkened by the least brightness that
    /// gives white text `minimumContrastOnAccent`. A colour already dark enough
    /// comes back unchanged; hue and saturation never change.
    static func readableUnderWhite(red: CGFloat, green: CGFloat, blue: CGFloat)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard contrastWithWhite(red, green, blue) < minimumContrastOnAccent else { return (red, green, blue) }
        // Scaling all three channels by one factor is a brightness change in HSB at a fixed hue.
        var (low, high): (CGFloat, CGFloat) = (0, 1)
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if contrastWithWhite(red * middle, green * middle, blue * middle) >= minimumContrastOnAccent {
                low = middle
            } else {
                high = middle
            }
        }
        return (red * low, green * low, blue * low)
    }

    /// The WCAG contrast ratio of white against an sRGB colour.
    static func contrastWithWhite(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(min(max(channel, 0), 1))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    static let neutralSurface = NSColor(name: "TranscriptNeutralSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.93, alpha: 1)
    }

    static let cardSurface = NSColor(name: "TranscriptCardSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    }

    /// A code block's own surface, inside the reply's bubble.
    static let codeSurface = NSColor(name: "TranscriptCodeSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 1)
            : NSColor(white: 0.985, alpha: 1)
    }
}
