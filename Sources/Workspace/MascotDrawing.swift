//
//  MascotDrawing.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// MascotDrawing is everything a renderer needs to draw one mascot, derived
/// from the persisted `WorkerAppearance` and from nothing else.
///
/// It holds no colour, image or graphics type, so the derivation stays in this
/// module and can be compared in a test: the same appearance must produce an
/// equal value every time, in this process and in the next one. That is the
/// whole guarantee behind "the mascot does not change between relaunches", and
/// renaming a worker or attaching a model cannot reach any field here.
///
/// The first generator draws the coloured ball with soft light. The shape
/// variation and the eyes of the 2,5D mascot are a later generator, which is
/// why `WorkerAppearance.generatorVersion` is persisted; there is one version
/// today, so nothing branches on it yet, and a second one branches here so an
/// older worker keeps drawing the way it always did.
public struct MascotDrawing: Sendable, Hashable {

    /// The generator this type implements. A new appearance is stamped with
    /// it so a later generator can tell what a descriptor was authored for.
    public static let generatorVersion = 1

    public let hue       : Double
    public let saturation: Double
    public let brightness: Double

    /// Corner radius as a fraction of the side. 0.5 is a circle.
    public let radiusFraction: Double

    /// Where the soft light sits, in the unit square, 0.5 being the centre.
    public let highlightX: Double
    public let highlightY: Double

    /// How wide the soft light spreads before it reaches the base colour.
    public let highlightSpread: Double

    /// How bright the light is. It is the only expressive knob the first
    /// generator uses; nothing here is animated.
    public let glow: Double

    public init(_ appearance: WorkerAppearance) {
        let palette = MascotPalette.named(appearance.palette)
        let seed    = UInt64(bitPattern: appearance.seed)

        let span = palette.hueRange.upperBound - palette.hueRange.lowerBound
        self.hue        = palette.hueRange.lowerBound + Self.unit(seed, stream: 1) * span
        self.saturation = palette.saturation
        self.brightness = palette.brightness

        self.radiusFraction  = 0.30 + 0.20 * Self.clamped(appearance.roundness)
        self.highlightX      = 0.30 + 0.18 * Self.unit(seed, stream: 2)
        self.highlightY      = 0.26 + 0.18 * Self.unit(seed, stream: 3)
        self.highlightSpread = 0.35 + 0.30 * Self.clamped(appearance.wobble)
        self.glow            = Self.clamped(appearance.glow)
    }

    // MARK: Deterministic derivation

    /// A value in 0..<1 for one independent stream of the same seed.
    private static func unit(_ seed: UInt64, stream: UInt64) -> Double {
        Double(mixed(seed &+ stream &* 0x9E37_79B9_7F4A_7C15) >> 11) * 0x1p-53
    }

    /// The SplitMix64 finalizer. It is written out rather than taken from a
    /// random generator because the result has to be identical across
    /// launches and toolchains, which a system generator does not promise.
    private static func mixed(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// The shape parameters come from disk, so a value outside 0...1 or a
    /// value that is not a number is brought back before it reaches a context.
    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
