//
//  IncrementalTextPlan.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import PerceptionCore

/// IncrementalTextPlan decides, from the tiles that changed and the runs the previous frame read,
/// which rects to read again and which runs survive untouched. Pure geometry: no image, no
/// recognizer, no clock, so a test settles every threshold here.
///
/// It exists because recognition scales with the amount of TEXT, not with pixels, and between two
/// live frames most tiles are identical. Measured 2026-09-06 on a Retina peek tile: Vision at
/// `accurate` was 122 ms of a 125 ms pass, 97% of the whole cost. Reading only what changed is the
/// one lever that moves that number without trading accuracy away, because the level never changes,
/// only where it looks.
public enum IncrementalTextPlan {

    /// Above this share of the frame a full read is cheaper than many crops.
    public static let maxPartialArea = 0.6

    /// Area is not the only cost. Each crop carries a measured 17 to 20 ms floor, with break-even
    /// against a full read at about eight to ten rects, so twelve scattered one-line rects cost MORE
    /// than a full read while covering some 4% of the frame: a case `maxPartialArea` cannot see,
    /// because it only ever looks at total area. Both terms are judged after `plan`, which is where
    /// the rect count is finally known, since planning merges and grows rects and counting dirty
    /// tiles beforehand would count the wrong thing.
    ///
    /// The break-even is measured; this cutoff is not, and it has to be earned rather than kept.
    public static let maxPartialRects = 10

    /// The padding around a dirty tile, and around a line it touches, from the median text height of
    /// the previous frame: a full line height SIDEWAYS, so a changed word is read with the
    /// neighbours on its line, but only about a third of a line VERTICALLY.
    ///
    /// Line spacing is at least 1.3 lines, so a gap of 0.3 line, and a vertical pad below that never
    /// reaches the line above or below: the growth follows the LINE, not the column. Measured on a
    /// chat window, where a full-line vertical pad cascaded every dirty tile through the whole text
    /// column, 27 to 43% of the frame re-read, against 17 to 24% at half a line.
    public static func pads(lineHeight: CGFloat) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(16, lineHeight), max(6, 0.35 * lineHeight))
    }

    /// The rects to read again, and the previous runs that survive untouched.
    ///
    /// Dirty tiles are padded, so a word that changed at a tile edge is read with its neighbours. A
    /// rect that touches a previous run without containing it grows to that run's padded box,
    /// because a line is read whole or not at all: a crop through the middle of "Align Clips…"
    /// yields a fragment that then replaces the true text. Rects that come to overlap merge, and the
    /// two rules iterate until nothing moves.
    public static func plan(
        dirty   : [CGRect],
        previous: [RecognizedText],
        frame   : CGRect
    ) -> (rects: [CGRect], kept: [RecognizedText]) {

        let heights = previous.map(\.pixelBox.height).filter { $0 >= 4 }.sorted()
        let lineHeight = heights.isEmpty ? 24 : heights[heights.count / 2]
        let pad = pads(lineHeight: lineHeight)

        var rects = TileDiff.coalesce(dirty.map {
            $0.insetBy(dx: -pad.horizontal, dy: -pad.vertical).intersection(frame)
        })
        var iterations = 0
        var changed = true
        while changed, iterations < 12 {
            changed = false
            iterations += 1
            for index in rects.indices {
                for run in previous {
                    let box = run.pixelBox
                    guard box.intersects(rects[index]), !rects[index].contains(box) else { continue }
                    rects[index] = rects[index]
                        .union(box.insetBy(dx: -pad.horizontal, dy: -pad.vertical))
                        .intersection(frame)
                    changed = true
                }
            }
            let merged = TileDiff.coalesce(rects)
            if merged.count != rects.count { changed = true }
            rects = merged
        }
        let kept = previous.filter { run in !rects.contains { $0.intersects(run.pixelBox) } }
        return (rects, kept)
    }

    /// True when the planned rects are not worth cropping for and the whole frame should be read
    /// again: too much area, or too many separate crops. Both cutoffs above.
    public static func prefersFullRead(rects: [CGRect], in frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
            / Double(frame.width * frame.height)
        return area > maxPartialArea || rects.count > maxPartialRects
    }
}
