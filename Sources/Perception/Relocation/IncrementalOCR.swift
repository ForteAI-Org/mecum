import Foundation
import CoreGraphics
import CVBackend

/// A recognized text run, with its box already converted to image pixels (top-left). No Vision-space
/// (bottom-left normalized) coordinates ever leave the OCR layer.
///
/// Lived in `OCRSupport` beside the Vision wrapper `VisionText` now covers; kept here because the
/// incremental plan below is written in terms of it. T5 ports both onto the Perception layer's own
/// recognized-text vocabulary.
public struct OCRResult: Sendable, Equatable {
    public var text: String
    public var boxImagePx: CGRect

    public init(text: String, boxImagePx: CGRect) {
        self.text = text
        self.boxImagePx = boxImagePx
    }
}

/// What one frame's OCR knew: its tile grid and every recognized run. Hand it to the next frame's
/// `IncrementalOCR.recognize` and only the tiles that changed are read again.
public struct OCRFrame: Sendable, Equatable {
    public let grid: TileGrid
    public let runs: [OCRResult]
    public init(grid: TileGrid, runs: [OCRResult]) { self.grid = grid; self.runs = runs }
}

/// ACCURATE OCR that re-reads only what changed. Measured 2026-09-06: after the CV stack moved to
/// Accelerate, Vision `.accurate` was 97% of a perception pass (122 of 125 ms on a Retina peek tile), and
/// it scales with the amount of TEXT, not pixels. Between two live frames most tiles are identical (a
/// hover highlight, a tooltip, a menu), so:
///
/// 1. tiles whose hash changed are the DIRTY set (`TileDiff`);
/// 2. each dirty rect is padded by a line height, then GROWN to cover every previous run it touches
///    (a changed word must re-read its whole line, never a fragment), and overlapping rects merge;
/// 3. previous runs inside those rects are dropped, the rects are cropped and re-read with `.accurate`,
///    everything else is kept verbatim.
///
/// Same recognizer, same level: the trade is only WHERE it looks. Falls back to a full read when there is
/// no comparable previous frame, when the dirty area exceeds `maxPartialArea`, or when `LOCATOR_FULL_OCR`
/// is set (the kill switch). `locator debug-incremental-ocr` is the harness that measures the incremental
/// result against a full read on frame pairs — run it before trusting a change here.
public enum IncrementalOCR {
    public enum Mode: Sendable, Equatable {
        case full(reason: String)
        case unchanged
        case partial(rects: Int, areaFraction: Double)

        public var summary: String {
            switch self {
            case .full(let r): return "full (\(r))"
            case .unchanged: return "unchanged"
            case .partial(let n, let a): return String(format: "partial %d rect(s), %.0f%% of frame", n, a * 100)
            }
        }
    }

    public struct Outcome: Sendable {
        public let runs: [OCRResult]
        public let frame: OCRFrame
        public let mode: Mode
    }

    /// Above this share of the frame a full read is cheaper than many crops.
    public static let maxPartialArea = 0.6

    /// AREA IS NOT THE ONLY COST. Each crop call carries a measured 17–20 ms floor (ticket 09) with
    /// break-even against a full read at ≈8–10 rects — so twelve scattered one-line rects cost MORE than
    /// a full read while covering only ~4% of the frame, a case `maxPartialArea` cannot see because it
    /// only ever looks at total area. The guard therefore has two terms, both evaluated AFTER `plan()`,
    /// which is where the rect count is finally known (planning merges and grows rects, so counting
    /// dirty tiles beforehand would count the wrong thing).
    ///
    /// The 8–10 break-even is measured; this cutoff is not. It belongs to the sweep list
    /// (`.scratch/harness/issues/14-sweep-and-freeze-rule.md`) and must be earned, not kept.
    public static let maxPartialRects = 10

    /// `read` recognizes one image and answers runs boxed in THAT image's pixels (top-left). It used to be
    /// `OCRSupport.OCREngine`; it is a closure so this decision logic owes nothing to which recognizer runs
    /// underneath — T5 hands it the Perception layer's `TextRecognizing`.
    public static func recognize(in image: CGImage, previous: OCRFrame?, read: (CGImage) -> [OCRResult],
                                 tile: Int = TileDiff.defaultTile) -> Outcome {
        let w = image.width, h = image.height
        func full(_ reason: String, grid: TileGrid?) -> Outcome {
            let runs = read(image)
            let g = grid ?? TileGrid.empty(width: w, height: h, tile: tile)
            return Outcome(runs: runs, frame: OCRFrame(grid: g, runs: runs), mode: .full(reason: reason))
        }
        guard let grid = TileDiff.grid(image, tile: tile) else { return full("render failed", grid: nil) }
        if ProcessInfo.processInfo.environment["LOCATOR_FULL_OCR"] != nil { return full("LOCATOR_FULL_OCR", grid: grid) }
        guard let previous else { return full("no previous frame", grid: grid) }
        guard let dirty = TileDiff.dirtyRects(from: previous.grid, to: grid) else { return full("frame size changed", grid: grid) }
        if dirty.isEmpty {
            return Outcome(runs: previous.runs, frame: OCRFrame(grid: grid, runs: previous.runs), mode: .unchanged)
        }
        let frameRect = CGRect(x: 0, y: 0, width: w, height: h)
        let (rects, kept) = plan(dirty: dirty, previous: previous.runs, frame: frameRect)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) } / Double(w * h)
        guard area <= maxPartialArea else { return full(String(format: "dirty %.0f%% of frame", area * 100), grid: grid) }
        guard rects.count <= maxPartialRects else {
            return full(String(format: "%d rects (>%d) at %.0f%% of frame — crops cost more than one read",
                               rects.count, maxPartialRects, area * 100), grid: grid)
        }
        var fresh: [OCRResult] = []
        for r in rects {
            let ri = r.integral.intersection(frameRect)
            guard ri.width >= 1, ri.height >= 1, let crop = image.cropping(to: ri) else { return full("crop failed", grid: grid) }
            fresh += read(crop).map {
                OCRResult(text: $0.text, boxImagePx: $0.boxImagePx.offsetBy(dx: ri.minX, dy: ri.minY))
            }
        }
        let runs = kept + fresh
        return Outcome(runs: runs, frame: OCRFrame(grid: grid, runs: runs), mode: .partial(rects: rects.count, areaFraction: area))
    }

    /// Padding around a dirty tile / a touched line, from the median text height of the previous frame:
    /// a full line height SIDEWAYS (a changed word is read with its neighbours on the line) but only half
    /// a third of a line VERTICALLY — line spacing is ≥1.3 lines (gap ≥ 0.3), so the pad never reaches the
    /// next line and the growth follows the LINE, not the column. Measured on a chat window: with a
    /// full-line vertical pad every dirty tile cascaded through the whole text column (27–43% of the frame
    /// re-read); at half a line 17–24%.
    public static func pads(lineHeight: CGFloat) -> (h: CGFloat, v: CGFloat) {
        (max(16, lineHeight), max(6, 0.35 * lineHeight))
    }

    /// PURE planning (unit-tested): the rects to re-read and the previous runs that survive untouched.
    /// - dirty tiles are padded (`pads`), so a word that changed at a tile edge is read with its neighbours;
    /// - a rect touching a previous run but not containing it grows to the run's padded box — a line is
    ///   re-read whole or not at all (a crop through the middle of "Align Clips…" would yield a fragment
    ///   that then replaces the true text);
    /// - rects that come to overlap merge; iterate until stable.
    public static func plan(dirty: [CGRect], previous: [OCRResult], frame: CGRect) -> (rects: [CGRect], kept: [OCRResult]) {
        let heights = previous.map(\.boxImagePx.height).filter { $0 >= 4 }.sorted()
        let lineH = heights.isEmpty ? 24 : heights[heights.count / 2]
        let pad = pads(lineHeight: lineH)
        var rects = TileDiff.coalesce(dirty.map { $0.insetBy(dx: -pad.h, dy: -pad.v).intersection(frame) })
        var iterations = 0
        var changed = true
        while changed, iterations < 12 {
            changed = false
            iterations += 1
            for i in rects.indices {
                for run in previous {
                    let box = run.boxImagePx
                    guard box.intersects(rects[i]), !rects[i].contains(box) else { continue }
                    rects[i] = rects[i].union(box.insetBy(dx: -pad.h, dy: -pad.v)).intersection(frame)
                    changed = true
                }
            }
            let merged = TileDiff.coalesce(rects)
            if merged.count != rects.count { changed = true }
            rects = merged
        }
        let kept = previous.filter { run in !rects.contains { $0.intersects(run.boxImagePx) } }
        return (rects, kept)
    }
}
