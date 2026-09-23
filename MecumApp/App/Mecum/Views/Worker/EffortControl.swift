//
//  EffortControl.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import ModelTransports
import SwiftUI

/// EffortControl is the reasoning effort of §6.4, in the worker's profile.
///
/// A detented rail in a capsule when the model has levels, a switch when its
/// only control is thinking on or off, and a sentence when it has no effort
/// parameter, which then offers no level at all. The positions and every
/// landing come from `EffortScale`: a click and a drag go through
/// `effort(atFraction:)`, the arrow keys through `effort(from:steps:)`, so all
/// three stop on the same detents.
struct EffortControl: View {

    let scale: EffortScale

    @Binding
    var effort: ReasoningEffort

    /// Half the knob, so the first and last detents sit inside the capsule.
    private let inset: CGFloat = 12

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 8
        ) {
            HStack {
                Text("Impegno di ragionamento")
                    .font(.headline)

                Spacer()

                if !scale.isEmpty, !scale.isSwitch {
                    Text(effort.title(for: scale.provider))
                        .fontWeight(.semibold)
                }
            }

            if scale.isEmpty {
                Text("This model takes no reasoning effort setting, so there is no level to choose.")
                    .foregroundStyle(.secondary)
            } else if scale.isSwitch {
                Toggle(
                    "Think before answering",
                    isOn: thinking
                )
                summary
            } else {
                rail
                labels
                summary
            }
        }
    }

    // MARK: Parts

    private var summary: some View {
        Text(scale.summary(of: effort))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(
                horizontal: false,
                vertical  : true
            )
    }

    private var thinking: Binding<Bool> {
        Binding(
            get: { effort != scale.positions.first },
            set: { isOn in
                if let landed = isOn ? scale.positions.last : scale.positions.first { effort = landed }
            }
        )
    }

    private var rail: some View {
        GeometryReader { geometry in
            let track  = max(
                1,
                geometry.size.width - inset * 2
            )
            let middle = geometry.size.height / 2

            ZStack {
                Capsule()
                    .fill(.quaternary)

                ForEach(scale.positions) { position in
                    Circle()
                        .fill(.secondary)
                        .frame(
                            width : 5,
                            height: 5
                        )
                        .position(
                            x: inset + track * scale.fraction(of: position),
                            y: middle
                        )
                }

                Circle()
                    .fill(.tint)
                    .frame(
                        width : 20,
                        height: 20
                    )
                    .shadow(radius: 1)
                    .position(
                        x: inset + track * scale.fraction(of: effort),
                        y: middle
                    )
            }
            .contentShape(Capsule())
            // Zero distance, so a click is a drag that did not move and lands the same way.
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if let landed = scale.effort(atFraction: (value.location.x - inset) / track) {
                        effort = landed
                    }
                }
            )
        }
        .frame(height: 26)
        .animation(
            .snappy(duration: 0.15),
            value: effort
        )
        .focusable()
        .onKeyPress(.leftArrow)  { step(-1) }
        .onKeyPress(.downArrow)  { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.upArrow)    { step(1) }
        .accessibilityElement()
        .accessibilityLabel("Impegno di ragionamento")
        .accessibilityValue(effort.title(for: scale.provider))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    private var labels: some View {
        HStack {
            ForEach(scale.positions) { position in
                Text(position.title(for: scale.provider))
                    .font(.caption2)
                    .foregroundStyle(position == effort ? .primary : .secondary)

                if position != scale.positions.last { Spacer() }
            }
        }
        .accessibilityHidden(true)
    }

    private func step(_ steps: Int) -> KeyPress.Result {
        guard let landed = scale.effort(
            from : effort,
            steps: steps
        ) else { return .ignored }

        effort = landed
        return .handled
    }
}
