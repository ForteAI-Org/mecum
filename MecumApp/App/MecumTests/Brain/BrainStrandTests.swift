//
//  BrainStrandTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Testing
@testable import Mecum

/// The fractal a link of the Brain's graph is drawn with: the same for the
/// same two nodes on every launch, and pinned to the two nodes wherever they are.
@Suite("A link's fractal strand")
struct BrainStrandTests {

    @Test func aLinkKeepsItsShapeAndItsEndsStayOnItsNodes() {
        let strand = BrainStrand(
            from: "window:notes",
            to  : "group:tags"
        )
        let again  = BrainStrand(
            from: "window:notes",
            to  : "group:tags"
        )
        #expect(strand.spine == again.spine)
        #expect(strand.twigs == again.twigs)
        #expect(strand.spine != BrainStrand(from: "window:notes", to: "group:other").spine)

        // Four bendings of one line: 17 points, bent to the side and never back along the link.
        #expect(strand.spine.count == 17)
        #expect(strand.spine.contains { $0.y != 0 })
        #expect(zip(strand.spine, strand.spine.dropFirst()).allSatisfy { $0.x < $1.x })

        let start  = CGPoint(
            x: 10,
            y: 20
        )
        let end    = CGPoint(
            x: 110,
            y: -40
        )
        let placed = BrainStrand.placed(
            strand.spine,
            from: start,
            to  : end
        )
        #expect(placed.first == start)
        #expect(placed.last == end)

        // Every twig grows out of the spine.
        #expect(!strand.twigs.isEmpty)
        #expect(strand.twigs.allSatisfy { twig in strand.spine.contains(twig[0]) })
    }
}
