//
//  EffortSlider.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import ModelTransports
import SwiftUI

/// EffortSlider is a model's effort as a rail of stops that gets harder to
/// climb: the filled part runs from grey, little processing, to the accent at
/// the model's top level. While it is dragged the pointer is detached from the
/// hand (`EffortSliderInput`) and drawn where the knob holds it: each stretch
/// up takes more of the hand's motion than the one before, every stop holds
/// the knob a little as it passes, and going down is otherwise free. The
/// trackpad answers each stop a little harder, and when the knob is let go it
/// settles on the nearest stop and the real pointer comes back over it.
///
/// macOS offers three haptic patterns and no intensity, so the climb goes
/// from alignment to generic to level change, and the top stop answers twice.
/// Going down is always the light one.
struct EffortSlider: View {

    let positions: [ReasoningEffort]

    let provider: ModelProvider

    @Binding var effort: ReasoningEffort

    /// Where the knob is while it is dragged, in the slider's own coordinates.
    @State private var knob: CGFloat?

    /// How far down the slider the drag was pressed, where the drawn pointer rides.
    @State private var grip: CGFloat?

    /// Where on the knob it was taken, from its centre, so taking it never moves it.
    @State private var grab: CGFloat = 0

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    private static let knobSide  : CGFloat = 28
    private static let railHeight: CGFloat = 14

    /// The colour of little processing, where the rail starts.
    private static let scarce = Color(nsColor: .systemGray)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.railHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors    : [Self.scarce, colour],
                            startPoint: .leading,
                            endPoint  : .trailing
                        )
                    )
                    .frame(
                        width : knobCentre(in: width) + Self.railHeight / 2,
                        height: Self.railHeight
                    )

                ForEach(positions.indices, id: \.self) { stop in
                    Circle()
                        .fill(stop <= index ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .frame(
                            width : 4,
                            height: 4
                        )
                        .offset(x: detent(stop, in: width) - 2)
                }

                Circle()
                    .fill(.white)
                    .shadow(
                        color : .black.opacity(0.25),
                        radius: 2.5,
                        y     : 1
                    )
                    .frame(
                        width : Self.knobSide,
                        height: Self.knobSide
                    )
                    .offset(x: knobCentre(in: width) - Self.knobSide / 2)
            }
            .frame(
                width : width,
                height: geometry.size.height
            )
            .contentShape(Rectangle())
            .overlay {
                EffortSliderInput(
                    holdsPointer: !reducesMotion,
                    press       : { press(at: $0, in: width) },
                    drag        : { drag(by: $0, to: $1, in: width) },
                    release     : { release(in: width) }
                )
            }
            .overlay(alignment: .topLeading) {
                if let knob, let grip, !reducesMotion {
                    heldPointer(
                        at: CGPoint(
                            x: knob + grab,
                            y: grip
                        )
                    )
                }
            }
        }
        .frame(height: Self.knobSide + 4)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement()
        .accessibilityLabel("Effort")
        .accessibilityValue(effort.title(for: provider))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    // MARK: Geometry

    private var index: Int { positions.firstIndex(of: effort) ?? 0 }

    /// How far up the rail the effort is, from 0 at the first stop to 1 at the last.
    private func fraction(_ stop: Int) -> CGFloat {
        positions.count > 1 ? CGFloat(stop) / CGFloat(positions.count - 1) : 1
    }

    /// The rail's colour at the current stop, between scarce and the accent.
    private var colour: Color {
        Self.colour(
            of: effort,
            in: positions
        )
    }

    /// The colour of `effort` on a rail of `positions`, which the effort's name beside the model shares.
    static func colour(
        of effort   : ReasoningEffort,
        in positions: [ReasoningEffort]
    ) -> Color {
        let stop   = positions.firstIndex(of: effort) ?? 0
        let height = positions.count > 1 ? Double(stop) / Double(positions.count - 1) : 1
        return scarce.mix(
            with: .accentColor,
            by  : height
        )
    }

    private func detent(
        _ stop  : Int,
        in width: CGFloat
    ) -> CGFloat {
        let inset = Self.knobSide / 2
        return inset + (width - 2 * inset) * fraction(stop)
    }

    /// The knob where the drag has it, and on its stop otherwise.
    private func knobCentre(in width: CGFloat) -> CGFloat {
        knob ?? detent(index, in: width)
    }

    /// `x` kept on the rail, between the first stop and the last.
    private func clamped(
        _ x     : CGFloat,
        in width: CGFloat
    ) -> CGFloat {
        let inset = Self.knobSide / 2
        return min(max(x, inset), width - inset)
    }

    /// The stop nearest `x`.
    private func nearestStop(
        to x    : CGFloat,
        in width: CGFloat
    ) -> Int {
        guard positions.count > 1 else { return 0 }

        let inset = Self.knobSide / 2
        let along = (x - inset) / (width - 2 * inset)
        return Int((along * CGFloat(positions.count - 1)).rounded())
    }

    // MARK: Moving

    /// The knob settling on a stop, after a drag or a key; nothing moves under Reduce Motion.
    private var settling: Animation? {
        reducesMotion ? nil : .spring(duration: 0.25, bounce: 0.3)
    }

    /// The system's arrow, drawn with its hot spot on `point` while the real pointer is detached.
    private func heldPointer(at point: CGPoint) -> some View {
        let arrow = NSCursor.arrow
        return Image(nsImage: arrow.image)
            .offset(
                x: point.x - arrow.hotSpot.x,
                y: point.y - arrow.hotSpot.y
            )
            .allowsHitTesting(false)
    }

    /// A press on the knob takes it where it is, at the point it was pressed; a press on the rail
    /// brings the knob under the pointer, and onto the stop nearest it.
    private func press(
        at point: CGPoint,
        in width: CGFloat
    ) {
        let centre = knobCentre(in: width)
        grip = point.y

        if abs(point.x - centre) <= Self.knobSide / 2 {
            knob = centre
            grab = point.x - centre
            return
        }

        let x = clamped(point.x, in: width)
        knob  = x
        grab  = 0
        move(to: nearestStop(to: x, in: width))
    }

    /// The share of the hand's motion the knob takes. Up, each stretch between two stops divides
    /// it by more, less so near the top, and the last a little less again: all of it on the
    /// first, then 48%, 36%, 30%, 29% on a rail of six. Near a stop,
    /// within a quarter of the way to the next, the stop holds the knob at 45% more, both ways.
    private func share(
        movingUp: Bool,
        at x    : CGFloat,
        in width: CGFloat
    ) -> CGFloat {
        guard positions.count > 1 else { return 1 }

        let inset   = Self.knobSide / 2
        let along   = (x - inset) / ((width - 2 * inset) / CGFloat(positions.count - 1))
        let stretch = min(max(along.rounded(.down), 0), CGFloat(positions.count - 2))
        let notch   = abs(along - along.rounded()) < 0.25 ? 0.45 : 1
        let last    = stretch > 0 && stretch == CGFloat(positions.count - 2) ? 1.12 : 1
        return movingUp ? last * notch / (1 + 1.08 * pow(stretch, 0.7)) : notch
    }

    /// Moves the knob by the hand's `delta` times its `share`. Under Reduce Motion the knob is
    /// where the pointer is, `x`, with no resistance.
    private func drag(
        by delta: CGFloat,
        to x    : CGFloat,
        in width: CGFloat
    ) {
        guard let current = knob else { return }

        let moved: CGFloat
        if reducesMotion {
            moved = clamped(x - grab, in: width)
        } else {
            let taken = delta * share(
                movingUp: delta > 0,
                at      : current,
                in      : width
            )
            moved = clamped(current + taken, in: width)
        }

        knob = moved
        move(to: nearestStop(to: moved, in: width))
    }

    /// Lets the knob settle on its stop, and answers where the pointer comes back to: the point on
    /// the knob it was taken at.
    private func release(in width: CGFloat) -> CGFloat? {
        grip = nil
        withAnimation(settling) { knob = nil }
        return detent(index, in: width) + grab
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let stop = index + offset
        guard positions.indices.contains(stop) else { return .ignored }

        withAnimation(settling) { move(to: stop) }
        return .handled
    }

    private func move(to stop: Int) {
        guard stop != index else { return }

        feel(movingUp: stop > index, to: stop)
        effort = positions[stop]
    }

    /// The trackpad's answer to a stop: harder as the effort climbs, the light one going down.
    private func feel(
        movingUp: Bool,
        to stop : Int
    ) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        guard movingUp else {
            performer.perform(
                .alignment,
                performanceTime: .now
            )
            return
        }

        let height  = fraction(stop)
        let pattern: NSHapticFeedbackManager.FeedbackPattern = height < 0.34 ? .alignment
            : height < 0.67 ? .generic
            : .levelChange
        performer.perform(
            pattern,
            performanceTime: .now
        )

        // The top stop answers twice, the firmest the trackpad can be asked for.
        if stop == positions.count - 1, positions.count > 2 {
            Task {
                try? await Task.sleep(for: .milliseconds(70))
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .levelChange,
                    performanceTime: .now
                )
            }
        }
    }
}
