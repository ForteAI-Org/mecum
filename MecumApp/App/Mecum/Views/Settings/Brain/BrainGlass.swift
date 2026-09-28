//
//  BrainGlass.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainGlass is the ground of the controls that float over the Brain's
/// graph: Liquid Glass on macOS 26, and before it a material capsule with a
/// hairline edge and a soft shadow.
struct BrainGlass: ViewModifier {

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: .capsule
                )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: .capsule
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            .quaternary,
                            lineWidth: 0.5
                        )
                }
                .shadow(
                    color : .black.opacity(0.12),
                    radius: 8,
                    y     : 2
                )
        }
    }
}
