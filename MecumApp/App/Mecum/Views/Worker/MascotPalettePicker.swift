//
//  MascotPalettePicker.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// MascotPalettePicker is the mascot's colour as a row of swatches, the way
/// System Settings picks an accent: one dot per palette in the middle of its
/// hues, and a ring around the chosen one. Each dot is a button that
/// VoiceOver reads by the palette's name.
struct MascotPalettePicker: View {

    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MascotPalette.all) { palette in
                let isChosen = palette.name == selection

                Button {
                    selection = palette.name
                } label: {
                    Circle()
                        .fill(colour(of: palette))
                        .frame(
                            width : 18,
                            height: 18
                        )
                        .padding(3)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isChosen ? colour(of: palette) : .clear,
                                    lineWidth: 2
                                )
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(palette.name.capitalized)
                .accessibilityLabel(palette.name.capitalized)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Colour")
    }

    private func colour(of palette: MascotPalette) -> Color {
        Color(
            hue       : (palette.hueRange.lowerBound + palette.hueRange.upperBound) / 2,
            saturation: palette.saturation,
            brightness: palette.brightness
        )
    }
}
