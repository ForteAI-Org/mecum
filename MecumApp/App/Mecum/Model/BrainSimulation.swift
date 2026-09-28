//
//  BrainSimulation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Foundation
import Observation

/// BrainSimulation keeps a `BrainGraph` moving on screen: it runs the graph's
/// `BrainPhysics` at sixty steps a second while anything moves, and sleeps
/// once it is cool, so the view stops drawing every frame. Holding a node,
/// letting it go and a node coming in wake it. It starts already settled, and
/// `beginEntrance` plays the settled graph coming in from its middle.
///
/// With `animates` off nothing moves by itself: a held node follows the
/// pointer alone, the rest settles at once when it is let go, and a node
/// comes in where it stands.
@Observable
final class BrainSimulation {

    let graph: BrainGraph

    /// Around the whole graph once it first settled, which the view frames until it is moved.
    let restingBounds: CGRect

    /// The shape each link is drawn with, by the link's place in `physics.links`.
    let strands: [BrainStrand]

    /// Whether anything still moves; the view draws a frame at a time only while it does.
    private(set) var isAwake = false

    /// Whether the graph moves on its own; off when the person asks for reduced motion.
    @ObservationIgnored var animates = true {
        didSet {
            if !animates { physics.settle() }
        }
    }

    @ObservationIgnored private(set) var physics: BrainPhysics

    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var backlog  = 0.0

    /// Whether the graph is coming in, and from which frame: nil until the first one is drawn.
    @ObservationIgnored private var isEntering    = false
    @ObservationIgnored private var entranceStart: Date?

    /// How long one node takes to come in, and how much later the last starts than the first.
    static let arrivalDuration: TimeInterval = 0.9
    static let arrivalSpread  : TimeInterval = 0.45

    /// A simulation of `graph` settled here and now, which a large graph takes a while to do.
    convenience init(graph: BrainGraph) {
        var physics = BrainPhysics(graph: graph)
        physics.settle(from: 1)
        self.init(
            graph  : graph,
            physics: physics
        )
    }

    private init(
        graph  : BrainGraph,
        physics: BrainPhysics
    ) {
        self.graph    = graph
        self.physics  = physics
        restingBounds = physics.presentBounds
        strands       = physics.links.map { link in
            BrainStrand(
                from: graph.nodes[link.from].id,
                to  : graph.nodes[link.to].id
            )
        }
    }

    /// A simulation of `graph` settled away from the main thread.
    static func settled(_ graph: BrainGraph) async -> BrainSimulation {
        let physics = await Task.detached(priority: .userInitiated) {
            var physics = BrainPhysics(graph: graph)
            physics.settle(from: 1)
            return physics
        }.value
        return BrainSimulation(
            graph  : graph,
            physics: physics
        )
    }

    // MARK: Changes

    /// Shows the nodes and the edges that had come in by `moment`, and hides the rest.
    func reveal(upTo moment: Date) {
        let changed = physics.reveal(
            upTo   : moment,
            placing: animates
        )
        if changed { wake() }
    }

    /// Plays the graph coming in: every node from the graph's middle out to where it stands, the
    /// windows first, then the groups, then the controls, each a little apart from the next.
    func beginEntrance() {
        guard animates else { return }

        isEntering    = true
        entranceStart = nil
        wake()
    }

    /// How far `node` has come in at `date`: 0 at the middle, 1 in place, a little past 1 for a
    /// moment as it overshoots, and 1 whenever the graph is not coming in.
    func arrival(
        of node: Int,
        at date: Date
    ) -> CGFloat {
        guard isEntering, animates else { return 1 }
        guard let start = entranceStart else { return 0 }

        let rank: Double = switch graph.nodes[node].kind {
            case .window : 0
            case .group  : 1
            case .control: 2
        }
        let delay = rank * Self.arrivalSpread / 3 + Self.jitter(of: node) * Self.arrivalSpread / 3
        let t     = min(max((date.timeIntervalSince(start) - delay) / Self.arrivalDuration, 0), 1)
        // Ease out past the end and back, as a spring would.
        let overshoot = 1.4
        let u         = t - 1
        return CGFloat(1 + (overshoot + 1) * u * u * u + overshoot * u * u)
    }

    /// A number between 0 and 1 for each node, the same on every launch, which keeps nodes of one
    /// kind from moving or glowing in step.
    static func jitter(of node: Int) -> Double {
        Double((UInt32(truncatingIfNeeded: node) &* 2_654_435_761) % 1_000) / 1_000
    }

    /// Takes hold of `node` where it stands; it follows `move(to:)` until `release()`.
    func hold(_ node: Int) {
        physics.hold(node)
        wake()
    }

    func move(to point: CGPoint) { physics.move(to: point) }

    func release() {
        physics.release()
        if !animates { physics.settle() }
        wake()
    }

    /// Moves on to `date`, at sixty steps a second whatever the display's rate, and sleeps once settled.
    func advance(to date: Date) {
        guard isAwake else { return }

        if animates {
            let elapsed = lastFrame.map { max(date.timeIntervalSince($0), 0) } ?? 1.0 / 60
            backlog     = min(backlog + elapsed * 60, 4)
            while backlog >= 1 {
                physics.step()
                backlog -= 1
            }
        }
        lastFrame = date

        if isEntering {
            let start = entranceStart ?? date
            entranceStart = start
            if date.timeIntervalSince(start) > Self.arrivalSpread + Self.arrivalDuration {
                isEntering    = false
                entranceStart = nil
            }
        }

        // Sleeping is a change the view observes, so it waits until this frame is drawn.
        if isSettled { Task { self.sleepIfSettled() } }
    }

    // MARK: Sleep

    private var isSettled: Bool { physics.held == nil && !isEntering && (!animates || physics.isCool) }

    private func wake() {
        guard !isAwake else { return }

        isAwake = true
    }

    private func sleepIfSettled() {
        guard isSettled else { return }

        isAwake   = false
        lastFrame = nil
        backlog   = 0
    }
}
