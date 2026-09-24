//
//  BrainCanvas.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainCanvas draws the simulation's nodes where they stand, a frame at a
/// time while it moves and once when it sleeps.
///
/// Every node is a point of light in a soft glow of its colour, a glow that
/// adds light in the dark. The controls are at the back, the groups over them
/// and the windows in front; the edges are faint fractal filaments
/// (`BrainStrand`) in the colour of the node they lead to; and a light behind
/// the whole follows a pan at half its pace, so the graph floats over it.
/// Under the pointer a node is ringed, what it is joined to stays lit while
/// the rest dims, and a control shows its name. The camera animates, so the
/// graph glides when it is framed again.
///
/// The graph comes in from its middle when it appears (`BrainSimulation.
/// beginEntrance`), and while it is still its lights breathe, each glow
/// brightening and dimming slowly out of step with the others, so it reads as
/// alive; that is a frame 24 times a second where there would be none.
struct BrainCanvas: View, Animatable {

    let simulation: BrainSimulation
    var camera    : BrainCamera
    let hovered   : Int?

    @Environment(\.colorScheme)
    private var colorScheme

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    /// How often the lights are drawn again while the graph is still, which is what their breathing
    /// costs: a frame this often instead of none.
    private static let breathingInterval = 1.0 / 24

    /// How much of itself a node keeps while the pointer is on one it is not joined to.
    private static let faded = 0.3

    /// The share of a node's radius its core of light fills; the glow takes the rest.
    private static let coreShare: CGFloat = 0.6

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGFloat> {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    var body: some View {
        // Read in the body itself, not in a closure under it, so waking and sleeping start and stop the frames.
        let isAwake = simulation.isAwake

        // Every frame while it moves; while it is still, often enough for the lights to breathe.
        TimelineView(.animation(
            minimumInterval: isAwake ? nil : Self.breathingInterval,
            paused         : !isAwake && reducesMotion
        )) { timeline in
            let _ = simulation.advance(to: timeline.date)

            Canvas { context, size in
                draw(
                    in  : &context,
                    size: size,
                    at  : timeline.date
                )
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in name(in: geometry.size) }
            }
        }
    }

    // MARK: Drawing

    private func draw(
        in context: inout GraphicsContext,
        size      : CGSize,
        at date   : Date
    ) {
        let isDark  = colorScheme == .dark
        let nodes   = simulation.graph.nodes
        let physics = simulation.physics
        let present = physics.isPresent

        // While the graph comes in, each node is on its way out from the middle to where it stands.
        let middle  = camera.screen(
            CGPoint(
                x: simulation.restingBounds.midX,
                y: simulation.restingBounds.midY
            ),
            in: size
        )
        let arrived = nodes.indices.map { simulation.arrival(of: $0, at: date) }
        let points  = physics.positions.enumerated().map { index, point in
            let placed = camera.screen(
                point,
                in: size
            )
            return CGPoint(
                x: middle.x + (placed.x - middle.x) * arrived[index],
                y: middle.y + (placed.y - middle.y) * arrived[index]
            )
        }
        let lit     = hovered.map { Set(physics.neighbours(of: $0) + [$0]) }
        let dimming = hovered == nil ? 1 : Self.faded

        backdrop(
            in    : &context,
            size  : size,
            isDark: isDark
        )

        // The edges, one path for each colour, and those of the node under the pointer apart.
        var strands: [BrainGraph.Kind: Path] = [:]
        var lighted = Path()
        var effects = Path()
        for (index, link) in physics.links.enumerated() where physics.isLinked[index] {
            let line = strand(
                simulation.strands[index],
                from: points[link.from],
                to  : points[link.to]
            )
            if link.kind == .effect {
                effects.addPath(line)
            } else if link.from == hovered || link.to == hovered {
                lighted.addPath(line)
            } else {
                strands[nodes[link.to].kind, default: Path()].addPath(line)
            }
        }

        var filaments = context
        filaments.blendMode = isDark ? .plusLighter : .normal
        for (kind, path) in strands {
            filaments.stroke(
                path,
                with     : .color(BrainPalette.colour(of: kind).opacity((isDark ? 0.34 : 0.42) * dimming)),
                lineWidth: 1
            )
        }
        filaments.stroke(
            lighted,
            with     : .color(.primary.opacity(0.6)),
            lineWidth: 1.25
        )
        context.stroke(
            effects,
            with : .color(.accentColor.opacity(0.8 * dimming)),
            style: StrokeStyle(
                lineWidth: 1.5,
                dash     : [4, 3]
            )
        )

        // The nodes from the back: controls, then groups, then windows.
        for layer in 0..<3 {
            for index in nodes.indices where present[index] && depth(of: nodes[index].kind) == layer {
                bead(
                    nodes[index],
                    at    : points[index],
                    fade  : (lit.map { $0.contains(index) ? 1 : Self.faded } ?? 1) * min(1, arrived[index]),
                    breath: breath(of: index, at: date),
                    isDark: isDark,
                    in    : &context
                )
            }
        }

        // Windows and groups carry their names under them; a control's shows under the pointer.
        for index in nodes.indices where present[index] && depth(of: nodes[index].kind) > 0 {
            let node  = nodes[index]
            let title = node.kind == .window
                ? Text(node.label).font(.callout.weight(.semibold))
                : Text(node.label).font(.caption2).foregroundStyle(.secondary)
            var label = context
            label.opacity = (lit.map { $0.contains(index) ? 1 : Self.faded } ?? 1) * min(1, arrived[index])
            label.draw(
                title,
                at    : CGPoint(
                    x: points[index].x,
                    y: points[index].y + camera.radius(node.radius) * Self.coreShare + 6
                ),
                anchor: .top
            )
        }

        if let hovered, present[hovered] {
            context.stroke(
                Path(ellipseIn: square(
                    around: points[hovered],
                    radius: camera.radius(nodes[hovered].radius) * Self.coreShare + 3
                )),
                with     : .color(.primary.opacity(0.8)),
                lineWidth: 1.5
            )
        }
    }

    /// A light behind the graph that follows a pan at half its pace, so the graph floats over it,
    /// and in the dark a shade towards the edges that deepens the space around it.
    private func backdrop(
        in context: inout GraphicsContext,
        size      : CGSize,
        isDark    : Bool
    ) {
        let origin = camera.screen(
            .zero,
            in: size
        )
        let centre = CGPoint(
            x: (size.width / 2 + origin.x) / 2,
            y: (size.height / 2 + origin.y) / 2
        )
        let whole  = Path(CGRect(
            origin: .zero,
            size  : size
        ))
        let reach  = max(size.width, size.height) * 0.75
        context.fill(
            whole,
            with: .radialGradient(
                Gradient(colors: [
                    Color.accentColor.opacity(isDark ? 0.07 : 0.05),
                    Color.accentColor.opacity(0),
                ]),
                center     : centre,
                startRadius: 0,
                endRadius  : reach
            )
        )
        if isDark {
            context.fill(
                whole,
                with: .radialGradient(
                    Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.22),
                    ]),
                    center     : CGPoint(
                        x: size.width / 2,
                        y: size.height / 2
                    ),
                    startRadius: reach * 0.4,
                    endRadius  : reach
                )
            )
        }
    }

    /// A node as a point of light: a small core, near white in the dark and its colour in the
    /// light, in a glow of its colour that fades out over three steps. Its colour is in the glow
    /// more than in the core, so it reads as light and not as a disc.
    private func bead(
        _ node    : BrainGraph.Node,
        at centre : CGPoint,
        fade      : Double,
        breath    : CGFloat,
        isDark    : Bool,
        in context: inout GraphicsContext
    ) {
        let colour = BrainPalette.colour(of: node.kind)
        let radius = camera.radius(node.radius)
        let core   = radius * Self.coreShare
        let halo   = radius * 2.4 * (0.95 + 0.05 * breath)

        var glow = context
        glow.opacity   = fade
        glow.blendMode = isDark ? .plusLighter : .normal
        glow.fill(
            Path(ellipseIn: square(
                around: centre,
                radius: halo
            )),
            with: .radialGradient(
                Gradient(stops: [
                    .init(
                        color   : colour.opacity((isDark ? 0.34 : 0.2) * breath),
                        location: 0
                    ),
                    .init(
                        color   : colour.opacity((isDark ? 0.12 : 0.07) * breath),
                        location: 0.45
                    ),
                    .init(
                        color   : colour.opacity(0),
                        location: 1
                    ),
                ]),
                center     : centre,
                startRadius: core,
                endRadius  : halo
            )
        )

        var light = context
        light.opacity = fade
        light.fill(
            Path(ellipseIn: square(
                around: centre,
                radius: core
            )),
            with: .color(isDark
                ? colour.mix(
                    with: .white,
                    by  : 0.72
                )
                : colour)
        )
    }

    /// A link's fractal strand between its two ends, its twigs included.
    private func strand(
        _ strand: BrainStrand,
        from start: CGPoint,
        to end    : CGPoint
    ) -> Path {
        var path = Path()
        path.addLines(BrainStrand.placed(
            strand.spine,
            from: start,
            to  : end
        ))
        for twig in strand.twigs {
            path.addLines(BrainStrand.placed(
                twig,
                from: start,
                to  : end
            ))
        }
        return path
    }

    /// How bright a node's glow is at `date`, between 0.8 and 1.2 of itself: a slow breath of
    /// its own, between three and four seconds long, out of step with the others. Steady under
    /// Reduce Motion.
    private func breath(
        of node: Int,
        at date: Date
    ) -> CGFloat {
        guard !reducesMotion else { return 1 }

        let jitter = BrainSimulation.jitter(of: node)
        let period = 3 + jitter
        let phase  = jitter * 7 * .pi
        return CGFloat(1 + 0.2 * sin(2 * .pi * date.timeIntervalSinceReferenceDate / period + phase))
    }

    private func depth(of kind: BrainGraph.Kind) -> Int {
        switch kind {
        case .control: 0
        case .group  : 1
        case .window : 2
        }
    }

    private func square(
        around centre: CGPoint,
        radius       : CGFloat
    ) -> CGRect {
        CGRect(
            x     : centre.x - radius,
            y     : centre.y - radius,
            width : radius * 2,
            height: radius * 2
        )
    }

    // MARK: Name

    /// The name of the control under the pointer, beside it.
    @ViewBuilder
    private func name(in size: CGSize) -> some View {
        if let hovered, simulation.physics.isPresent[hovered], case .control = simulation.graph.nodes[hovered].kind {
            let point = camera.screen(
                simulation.physics.positions[hovered],
                in: size
            )
            Text(simulation.graph.nodes[hovered].label)
                .font(.caption)
                .padding(
                    .horizontal,
                    6
                )
                .padding(
                    .vertical,
                    3
                )
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .fixedSize()
                .offset(
                    x: point.x + 10,
                    y: point.y - 26
                )
                .allowsHitTesting(false)
        }
    }
}
