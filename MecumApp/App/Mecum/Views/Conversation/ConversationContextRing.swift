//
//  ConversationContextRing.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// ConversationContextRing is how full the model's context is, drawn as a
/// ring: a quiet track, and the fill in the secondary label colour, amber once
/// the context is high (`UsageWording.isContextHigh`), never red. A new fill
/// moves round the ring, and changes at once with Reduce Motion.
struct ConversationContextRing: View {

    /// The context's fill, from 0 to 1; more than 1 draws a full ring.
    let fraction : Double
    let side     : CGFloat
    let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color(nsColor: .separatorColor),
                    lineWidth: lineWidth
                )

            Circle()
                .trim(
                    from: 0,
                    to  : min(max(fraction, 0), 1)
                )
                .stroke(
                    fill,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap  : .round
                    )
                )
                .rotationEffect(.degrees(-90))
        }
        // The stroke is centred on the circle's edge, so half of it would fall outside `side`.
        .padding(lineWidth / 2)
        .frame(
            width : side,
            height: side
        )
        .animation(reducesMotion ? nil : .smooth(duration: 0.4), value: fraction)
    }

    private var fill: AnyShapeStyle {
        UsageWording.isContextHigh(fraction) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }
}
