//
//  ConversationContextRing.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import SwiftUI

/// ConversationContextRing is how full the model's context is, drawn as a
/// ring: a quiet track, and the fill green while there is room, orange as it
/// fills and red from where Mecum compacts it (`UsageWording.contextLevel`),
/// the owner's choice for this one indicator. A new fill moves round the ring,
/// and changes at once with Reduce Motion.
///
/// While the context is compacted its size is not known, so the fill gives way
/// to a short quiet arc that turns, and stands still with Reduce Motion.
struct ConversationContextRing: View {

    /// The context's fill, from 0 to 1; more than 1 draws a full ring.
    let fraction : Double
    let side     : CGFloat
    let lineWidth: CGFloat

    /// True while the context is compacted.
    var isIndeterminate = false

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color(nsColor: .separatorColor),
                    lineWidth: lineWidth
                )

            if isIndeterminate {
                TimelineView(.animation(paused: reducesMotion)) { timeline in
                    arc(
                        to   : 0.25,
                        style: AnyShapeStyle(.secondary)
                    )
                    .rotationEffect(.degrees(Self.turn(at: timeline.date)))
                }
            } else {
                arc(
                    to   : min(max(fraction, 0), 1),
                    style: fill
                )
                .rotationEffect(.degrees(-90))
            }
        }
        // The stroke is centred on the circle's edge, so half of it would fall outside `side`.
        .padding(lineWidth / 2)
        .frame(
            width : side,
            height: side
        )
        .animation(reducesMotion ? nil : .smooth(duration: 0.4), value: fraction)
    }

    private var fill: AnyShapeStyle { Self.style(of: UsageWording.contextLevel(fraction)) }

    private func arc(
        to end: Double,
        style : AnyShapeStyle
    ) -> some View {
        Circle()
            .trim(
                from: 0,
                to  : end
            )
            .stroke(
                style,
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap  : .round
                )
            )
    }

    /// Where the turning arc points at `date`: once round a second.
    private static func turn(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }

    /// A context level's colour, which the context popover's bar shares.
    static func style(of level: UsageWording.ContextLevel) -> AnyShapeStyle {
        switch level {
            case .roomy  : AnyShapeStyle(.green)
            case .filling: AnyShapeStyle(.orange)
            case .full   : AnyShapeStyle(.red)
        }
    }
}
