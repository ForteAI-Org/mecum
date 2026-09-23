//
//  EffortTint.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SwiftUI

/// Grey at low, blue at medium, then amber, orange and red-orange: the
/// colour says how hard the model will think before the person reads it.
enum EffortTint {

    static func color(
        for effort: ReasoningEffort,
        provider  : ModelProvider,
        model     : String
    ) -> Color {
        let supported = ModelSelection.supportedEfforts(
            provider: provider,
            model   : model
        )
        let position = Double(supported.firstIndex(of: effort) ?? 0) / Double(max(
            1,
            supported.count - 1
        ))
        return color(position: position)
    }

    static func color(position: Double) -> Color {
        // Blue (hue 0.60) down to orange (hue 0.07); saturation grows with effort.
        let hue = 0.60 - 0.53 * position
        return Color(
            hue       : hue,
            saturation: 0.55 + 0.4 * position,
            brightness: 0.95
        )
    }
}
