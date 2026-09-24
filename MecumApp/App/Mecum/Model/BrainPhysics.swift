//
//  BrainPhysics.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Foundation

/// BrainPhysics is the physics of a `BrainGraph`, one step at a time: every
/// edge is a spring, every node pushes away the nodes near it, a weak pull
/// holds the whole near the centre, and every step loses some of its speed.
///
/// It cools as it steps, the way a force layout does: the forces weaken with
/// `alpha` until it is cool and nothing is left to move. A held node stays
/// where it is put and keeps the physics warm, so the springs drag what is
/// joined to it along. It holds no clock and knows nothing of a view, so a
/// large graph can settle away from the main thread; `BrainSimulation` runs it.
nonisolated struct BrainPhysics: Sendable {

    /// One edge as a spring between two nodes, by their index in the graph.
    struct Link: Sendable {
        let from    : Int
        let to      : Int
        let kind    : BrainGraph.EdgeKind
        let cameIn  : Date
        let rest    : CGFloat
        let strength: CGFloat

        /// How much of a pull moves `to` rather than `from`, so the end joined to fewer moves more.
        let bias: CGFloat
    }

    let links: [Link]

    private(set) var positions: [CGPoint]
    private(set) var isPresent: [Bool]
    private(set) var isLinked : [Bool]
    private(set) var held     : Int?

    /// What is left of the heat, which the forces are scaled by.
    private(set) var alpha: CGFloat = 1

    private var alphaTarget: CGFloat = 0
    private var velocities : [CGVector]

    /// The shown nodes along x, kept from one step to the next, when it is still almost in order.
    private var order: [Int]

    private let arrivals  : [Date]
    private let charges   : [CGFloat]
    private let parents   : [Int?]
    private let neighbours: [[Int]]

    private static let coolest : CGFloat = 0.001
    private static let cooling : CGFloat = 1 - pow(0.001, 1.0 / 300)
    private static let warmth  : CGFloat = 0.3
    private static let friction: CGFloat = 0.4
    private static let gravity : CGFloat = 0.012
    private static let reach   : CGFloat = 280

    init(graph: BrainGraph) {
        let count = graph.nodes.count
        let index = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($1.id, $0) })
        let ends  = graph.edges.compactMap { edge -> (Int, Int, BrainGraph.Edge)? in
            guard let from = index[edge.from], let to = index[edge.to] else { return nil }
            return (from, to, edge)
        }

        var degree   = [Int](
            repeating: 0,
            count    : count
        )
        var joined   = [[Int]](
            repeating: [],
            count    : count
        )
        var parentOf = [Int?](
            repeating: nil,
            count    : count
        )
        for (from, to, edge) in ends {
            degree[from] += 1
            degree[to]   += 1
            joined[from].append(to)
            joined[to].append(from)
            if edge.kind != .effect, parentOf[to] == nil { parentOf[to] = from }
        }

        links      = ends.map { from, to, edge in
            Link(
                from    : from,
                to      : to,
                kind    : edge.kind,
                cameIn  : edge.cameIn,
                rest    : Self.rest(
                    of: edge.kind,
                    to: graph.nodes[to].kind
                ),
                strength: 1 / CGFloat(min(degree[from], degree[to])),
                bias    : CGFloat(degree[from]) / CGFloat(degree[from] + degree[to])
            )
        }
        arrivals   = graph.nodes.map(\.cameIn)
        charges    = graph.nodes.map { Self.charge(of: $0.kind) }
        parents    = parentOf
        neighbours = joined
        positions  = graph.nodes.map(\.position)
        velocities = [CGVector](
            repeating: .zero,
            count    : count
        )
        isPresent  = [Bool](
            repeating: true,
            count    : count
        )
        isLinked   = [Bool](
            repeating: true,
            count    : ends.count
        )
        order      = Array(0..<count)
    }

    // MARK: Reading

    /// Whether the forces have died away, so a step would move nothing a person could see.
    var isCool: Bool { alpha < Self.coolest }

    /// Around the nodes shown now.
    var presentBounds: CGRect {
        let xs = order.map { positions[$0].x }
        let ys = order.map { positions[$0].y }
        guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return .zero }

        return CGRect(
            x     : left,
            y     : top,
            width : right - left,
            height: bottom - top
        )
    }

    /// The nodes an edge joins to `node`, shown or not.
    func neighbours(of node: Int) -> [Int] { neighbours[node] }

    // MARK: Changes

    /// Shows the nodes and edges that had come in by `moment` and hides the rest; with `placing`,
    /// a node coming in starts beside its parent and the physics warms up. Says whether any changed.
    mutating func reveal(
        upTo moment: Date,
        placing    : Bool
    ) -> Bool {
        var changed = false
        for node in arrivals.indices {
            let present = arrivals[node] <= moment
            guard present != isPresent[node] else { continue }

            changed         = true
            isPresent[node] = present
            if present, placing {
                positions[node]  = arrival(of: node)
                velocities[node] = .zero
            }
        }
        for (index, link) in links.enumerated() {
            isLinked[index] = isPresent[link.from] && isPresent[link.to] && link.cameIn <= moment
        }
        order = arrivals.indices.filter { isPresent[$0] }
        if changed, placing { alpha = max(alpha, Self.warmth) }
        return changed
    }

    /// Takes hold of `node` where it stands, and keeps the physics warm until `release()`.
    mutating func hold(_ node: Int) {
        held             = node
        velocities[node] = .zero
        alpha            = max(alpha, Self.warmth)
        alphaTarget      = Self.warmth
    }

    mutating func move(to point: CGPoint) {
        guard let held else { return }

        positions[held] = point
    }

    mutating func release() {
        held        = nil
        alphaTarget = 0
    }

    /// Steps until it is cool from `heat`, or from where it stands without one.
    mutating func settle(from heat: CGFloat? = nil) {
        alpha       = heat ?? alpha
        alphaTarget = 0
        while !isCool { step() }
    }

    // MARK: Step

    /// One step: the springs, the push between near nodes, the pull to the centre, then the move.
    mutating func step() {
        alpha += (alphaTarget - alpha) * Self.cooling
        Self.step(
            positions : &positions,
            velocities: &velocities,
            order     : &order,
            links     : links,
            isLinked  : isLinked,
            charges   : charges,
            held      : held,
            alpha     : alpha
        )
    }

    // The loops read and write through pointers, which keeps a Debug build near a frame's budget.
    private static func step(
        positions : inout [CGPoint],
        velocities: inout [CGVector],
        order     : inout [Int],
        links     : [Link],
        isLinked  : [Bool],
        charges   : [CGFloat],
        held      : Int?,
        alpha     : CGFloat
    ) {
        positions.withUnsafeMutableBufferPointer { positions in
            velocities.withUnsafeMutableBufferPointer { velocities in
                charges.withUnsafeBufferPointer { charges in
                    guard let p = positions.baseAddress, let v = velocities.baseAddress, let c = charges.baseAddress
                    else { return }

                    for (index, link) in links.enumerated() where isLinked[index] {
                        let from     = link.from
                        let to       = link.to
                        var dx       = p[to].x + v[to].dx - p[from].x - v[from].dx
                        var dy       = p[to].y + v[to].dy - p[from].y - v[from].dy
                        let distance = max(sqrt(dx * dx + dy * dy), 0.01)
                        let pull     = (distance - link.rest) / distance * alpha * link.strength
                        dx *= pull
                        dy *= pull
                        v[to].dx   -= dx * link.bias
                        v[to].dy   -= dy * link.bias
                        v[from].dx += dx * (1 - link.bias)
                        v[from].dy += dy * (1 - link.bias)
                    }

                    // Swept along x, each node meets only the nodes within reach of it.
                    order.sort { p[$0].x < p[$1].x }
                    let count = order.count
                    order.withUnsafeBufferPointer { order in
                        guard let o = order.baseAddress else { return }

                        for rank in 0..<count {
                            let a      = o[rank]
                            let origin = p[a]
                            var ax     = CGFloat.zero
                            var ay     = CGFloat.zero
                            var next   = rank + 1
                            while next < count {
                                let b  = o[next]
                                next  += 1
                                let dx = p[b].x - origin.x
                                guard dx < reach else { break }

                                let dy       = p[b].y - origin.y
                                let distance = dx * dx + dy * dy
                                guard distance < reach * reach else { continue }

                                let push = alpha / max(distance, 36)
                                ax      -= dx * c[b] * push
                                ay      -= dy * c[b] * push
                                v[b].dx += dx * c[a] * push
                                v[b].dy += dy * c[a] * push
                            }
                            v[a].dx += ax
                            v[a].dy += ay
                        }

                        for rank in 0..<count {
                            let node = o[rank]
                            guard node != held else {
                                v[node] = .zero
                                continue
                            }

                            v[node].dx = (v[node].dx - p[node].x * gravity * alpha) * (1 - friction)
                            v[node].dy = (v[node].dy - p[node].y * gravity * alpha) * (1 - friction)
                            p[node].x += v[node].dx
                            p[node].y += v[node].dy
                        }
                    }
                }
            }
        }
    }

    /// Beside its parent, turned by the golden angle so siblings coming in together fan out.
    private func arrival(of node: Int) -> CGPoint {
        guard let parent = parents[node], isPresent[parent] else { return positions[node] }

        let angle = CGFloat(node) * 2.399963
        return CGPoint(
            x: positions[parent].x + 8 * cos(angle),
            y: positions[parent].y + 8 * sin(angle)
        )
    }

    private static func rest(
        of kind: BrainGraph.EdgeKind,
        to node: BrainGraph.Kind
    ) -> CGFloat {
        switch (kind, node) {
        case (.membership, _)    : 30
        case (.placement, .group): 120
        case (.placement, _)     : 64
        case (.effect, _)        : 220
        }
    }

    /// How hard a node pushes the nodes near it: a window most, a control least.
    private static func charge(of kind: BrainGraph.Kind) -> CGFloat {
        switch kind {
        case .window : 520
        case .group  : 180
        case .control: 45
        }
    }
}
