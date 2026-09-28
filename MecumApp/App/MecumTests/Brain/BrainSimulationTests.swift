//
//  BrainSimulationTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Foundation
import Memory
import PerceptionCore
import Testing
@testable import Mecum

/// The Brain graph's physics: what a held node does to the nodes joined to
/// it, and that the simulation stops by itself once it is let go.
@Suite("The Brain graph's simulation")
@MainActor
struct BrainSimulationTests {

    @Test("A held group drags the controls joined to it, and the graph sleeps again once let go")
    func holdingDragsTheNeighboursAndItSleeps() async throws {
        let simulation = BrainSimulation(graph: BrainGraph(brain: Self.brain()))
        #expect(!simulation.isAwake)

        let nodes  = simulation.graph.nodes
        let group  = try #require(nodes.firstIndex { if case .group = $0.kind { true } else { false } })
        let member = try #require(simulation.physics.neighbours(of: group).first { if case .control = nodes[$0].kind { true } else { false } })
        let start  = simulation.physics.positions[member]

        simulation.hold(group)
        simulation.move(to: CGPoint(
            x: simulation.physics.positions[group].x + 300,
            y: simulation.physics.positions[group].y
        ))
        var clock = Date()
        for _ in 0..<60 {
            clock += 1.0 / 60
            simulation.advance(to: clock)
        }
        #expect(simulation.isAwake)
        #expect(simulation.physics.positions[member].x > start.x + 150)

        simulation.release()
        for _ in 0..<600 where simulation.isAwake {
            clock += 1.0 / 60
            simulation.advance(to: clock)
            await Task.yield()
        }
        #expect(!simulation.isAwake)
    }

    /// One window with a group of three controls, each learned a second after the last.
    private static func brain() -> UIBrain {
        let start   = Date(timeIntervalSince1970: 1_800_000_000)
        let group   = UUID()
        let anchors = (0..<3).map { index in
            ObjectAnchor(
                kind         : .control,
                label        : "Control \(index)",
                boundsTypical: NormalizedRect(
                    x     : 0,
                    y     : 0,
                    width : 0.1,
                    height: 0.1
                ),
                groupID      : group,
                firstSeen    : start.addingTimeInterval(Double(index)),
                lastSeen     : start.addingTimeInterval(Double(index)),
                window       : "main"
            )
        }
        return UIBrain(
            objects: anchors,
            groups : [
                SiblingGroup(
                    id           : group,
                    axis         : .column,
                    memberAnchors: anchors.map(\.anchorKey),
                    sharedKind   : .control,
                    cellSize     : NormalizedSize(
                        width : 0.1,
                        height: 0.1
                    ),
                    lastSeen     : start
                ),
            ]
        )
    }
}
