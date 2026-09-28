//
//  BrainStrand.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import CoreGraphics
import Foundation

/// BrainStrand is the shape one link of the Brain's graph is drawn with: a
/// randomised fractal between its two ends, a line bent at its midpoints again
/// and again, each time by half as much, with a few short twigs off it.
///
/// The shape is kept in the link's own terms, how far along it and how far to
/// its side as fractions of its length, so it follows its two ends as the graph
/// moves and is worked out only once. It is seeded by the link's two nodes, so
/// a link always has the same shape and a frame never redraws it differently.
nonisolated struct BrainStrand: Sendable {

    /// The points from one end to the other: `x` along the link, `y` to its side.
    let spine: [CGPoint]

    /// Short branches, each starting on the spine, in the same terms.
    let twigs: [[CGPoint]]

    /// How far the first bend may go to the side, as a share of the link's length.
    static let roughness: CGFloat = 0.12

    /// How many times the line is bent at its midpoints: 17 points.
    static let depth = 4

    init(seed: UInt64) {
        var random = SplitMix(state: seed)

        var points = [
            CGPoint(
                x: 0,
                y: 0
            ),
            CGPoint(
                x: 1,
                y: 0
            ),
        ]
        var amplitude = Self.roughness
        for _ in 0..<Self.depth {
            var bent = [points[0]]
            for (start, end) in zip(points, points.dropFirst()) {
                bent.append(CGPoint(
                    x: (start.x + end.x) / 2,
                    y: (start.y + end.y) / 2 + random.next(in: -amplitude...amplitude)
                ))
                bent.append(end)
            }
            points     = bent
            amplitude /= 2
        }
        spine = points

        // One to three twigs from the spine's inner points, leaning forward and to either side.
        var twigs: [[CGPoint]] = []
        for _ in 0..<(1 + Int(random.next(in: 0...2.99))) {
            let root   = points[Int(random.next(in: 2...CGFloat(points.count - 3)))]
            let length = random.next(in: 0.06...0.14)
            let angle  = random.next(in: 0.5...1.0) * (random.next(in: 0...1) < 0.5 ? -1 : 1)
            let tip    = CGPoint(
                x: root.x + length * cos(angle),
                y: root.y + length * sin(angle)
            )
            let bend   = CGPoint(
                x: (root.x + tip.x) / 2,
                y: (root.y + tip.y) / 2 + random.next(in: -length...length) * 0.3
            )
            twigs.append([root, bend, tip])
        }
        self.twigs = twigs
    }

    /// The strand of the link from node `from` to node `to`, the same on every launch.
    init(
        from: String,
        to  : String
    ) {
        // FNV-1a over the two ids, since Swift's own hashing changes from one launch to the next.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (from + "→" + to).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        self.init(seed: hash)
    }

    /// `points`, in the strand's terms, laid between `start` and `end` on screen.
    static func placed(
        _ points: [CGPoint],
        from start: CGPoint,
        to end    : CGPoint
    ) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        // Along is the link's own vector, across is it turned a quarter: no square root needed.
        return points.map { point in
            CGPoint(
                x: start.x + dx * point.x - dy * point.y,
                y: start.y + dy * point.x + dx * point.y
            )
        }
    }

    /// SplitMix64: small, fast, and the same sequence for the same seed.
    private struct SplitMix {

        var state: UInt64

        mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            value ^= value >> 31
            let unit = CGFloat(value >> 11) / CGFloat(UInt64(1) << 53)
            return range.lowerBound + (range.upperBound - range.lowerBound) * unit
        }
    }
}
