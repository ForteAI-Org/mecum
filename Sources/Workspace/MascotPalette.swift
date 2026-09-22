//
//  MascotPalette.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// MascotPalette resolves the colour family a `WorkerAppearance` names.
///
/// `WorkerAppearance` stores a palette name rather than colour components, so
/// a palette can be retuned without rewriting every worker. This type is the
/// other half of that decision: it turns the name back into a colour family,
/// and an unknown name resolves to `fallback` rather than to nothing, because
/// a worker whose palette was renamed must still draw with an identity.
///
/// The hue is a range and not a point: the worker's seed picks a hue inside
/// it, so two workers sharing a palette are still told apart.
public struct MascotPalette: Sendable, Hashable, Identifiable {

    public let name      : String
    public let hueRange  : ClosedRange<Double>
    public let saturation: Double
    public let brightness: Double

    public var id: String { name }

    init(
        name      : String,
        hueRange  : ClosedRange<Double>,
        saturation: Double,
        brightness: Double
    ) {
        self.name       = name
        self.hueRange   = hueRange
        self.saturation = saturation
        self.brightness = brightness
    }

    /// Every palette the creation sheet offers, in the order it offers them.
    public static let all: [MascotPalette] = [
        MascotPalette(name: "dusk",  hueRange: 0.70...0.78, saturation: 0.52, brightness: 0.80),
        MascotPalette(name: "tide",  hueRange: 0.52...0.60, saturation: 0.56, brightness: 0.78),
        MascotPalette(name: "moss",  hueRange: 0.28...0.36, saturation: 0.50, brightness: 0.72),
        MascotPalette(name: "sand",  hueRange: 0.09...0.14, saturation: 0.58, brightness: 0.86),
        MascotPalette(name: "ember", hueRange: 0.01...0.07, saturation: 0.62, brightness: 0.82),
        MascotPalette(name: "plum",  hueRange: 0.85...0.92, saturation: 0.52, brightness: 0.80),
    ]

    /// What an unrecognised name resolves to. It is a real palette, not a
    /// grey placeholder: the point of the fallback is that identity survives.
    public static let fallback = MascotPalette(
        name      : "dusk",
        hueRange  : 0.70...0.78,
        saturation: 0.52,
        brightness: 0.80
    )

    public static func named(_ name: String) -> MascotPalette {
        all.first { $0.name == name } ?? fallback
    }
}
