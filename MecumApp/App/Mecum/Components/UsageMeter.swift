//
//  UsageMeter.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// UsageMeter is a usage popover's line for something with a limit, a plan's
/// window or the model's context: its name, how much is used, and a thin bar
/// of that share under them in the caller's `fill`. VoiceOver reads it as one
/// sentence, `spoken`.
struct UsageMeter: View {

    let label   : String
    let value   : String

    /// From 0 to 1; more than 1 draws a full bar.
    let fraction: Double
    let fill    : AnyShapeStyle
    let spoken  : String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 5
        ) {
            HStack {
                Text(label)

                Spacer()

                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            bar
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var bar: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(fill)
                    .scaleEffect(
                        x     : min(max(fraction, 0), 1),
                        y     : 1,
                        anchor: .leading
                    )
            }
            .frame(height: 3)
            .clipShape(Capsule())
    }
}
