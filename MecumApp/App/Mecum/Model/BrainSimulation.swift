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
/// once it is cool, so the view stops drawing and the window costs nothing at
/// rest. Holding a node, letting it go and a node coming in wake it. It starts
/// already settled, so the graph opens still.
///
/// With `animates` off nothing moves by itself: a held node follows the
/// pointer alone, the rest settles at once when it is let go, and a node
/// comes in where it stands.
@Observable
final class BrainSimulation {

    let graph: BrainGraph

    /// Around the whole graph once it first settled, which the view frames until it is moved.
    let restingBounds: CGRect

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

        // Sleeping is a change the view observes, so it waits until this frame is drawn.
        if isSettled { Task { self.sleepIfSettled() } }
    }

    // MARK: Sleep

    private var isSettled: Bool { physics.held == nil && (!animates || physics.isCool) }

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
