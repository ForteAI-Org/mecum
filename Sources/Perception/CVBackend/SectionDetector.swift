import CoreGraphics
import Foundation

/// Panel-SECTION detection for a UI window — a recursive X-Y cut on edge projection profiles. Pro
/// apps draw hard panel boundaries (a sidebar edge, a clips-panel edge, a transport strip): each is
/// a near-continuous straight edge line spanning its region. Connected components cannot hand these
/// to us (borders merge into content blobs — measured on Pro Tools: 560 segments, 0 usable vertical
/// dividers), but a column/row PROJECTION of the binarized Sobel map shows every boundary as a tower.
/// We cut recursively at the towers; the leaves are the window's sections.
public enum SectionDetector {
    public struct Params: Sendable {
        /// Aligned text strokes can have high total fill while never forming a long divider.
        public var minContinuousFrac: Double = 0.25
        /// Field borders that cover only part of a column are not panel seams.
        public var horizontalFillMin: Double = 0.90
        public var useColorEdges: Bool = true
        public var fillMin: Double = 0.62        // fraction of the span an edge line must cover
        public var minSliceFrac: Double = 0.06   // a slice thinner than this fraction is not a section
        public var minRegionFrac: Double = 0.08  // regions thinner than this (vs the WINDOW) never subdivide
        public var periodicMax: Int = 6          // more lines than this on one axis = a GRID (toolbar/table), not boundaries
        public var maxLinesPerSplit: Int = 4     // strongest K lines only — panels are few, buttons are many
        public var edgeThreshold: Float = 40     // binarize level on the 0–255 Sobel map (segmenter parity)
        public var maxDepth: Int = 4   // root strips → columns → bands → fine
        public var columnFirstFill: Double = 0.9 // a near-full-HEIGHT column boundary owns the root
        /// Pixels inside an accepted IMAGE SURFACE are NEUTRAL to seam detection: a photo's interior
        /// texture may not propose a panel boundary, and a real seam passing under a photo keeps its
        /// continuity. The inset (analysis px) keeps the image's own border live, so the image can still
        /// be BOUNDED by a seam — it just cannot be cut through.
        public var imageInsetPx: Int = 3
        /// A seam must be supported by at least this fraction of its span OUTSIDE image surfaces: a line
        /// living mostly inside a photo is the photo's content, whatever its fill.
        public var minOutsideFrac: Double = 0.4
        public init() {}
    }

    /// Detect section rects (pixel space, top-left origin, same size as `image`). Deterministic.
    /// `excluding` are accepted IMAGE SURFACES in image pixels (`ImageSurfaceDetector` / content regions):
    /// their interiors are neutral ground for seam detection — see `Params.imageInsetPx`. Measured on
    /// Premiere's Edit workspace (live Peek): pink section lines ran through the program monitor and the
    /// project thumbnails because the cut never knew where the pictures were.
    public static func detect(in image: CGImage, params: Params = Params(), excluding imageRects: [CGRect] = []) -> [CGRect] {
        let iw = image.width, ih = image.height
        guard iw > 8, ih > 8 else { return [] }
        let scale = max(1, iw / 1000)
        let gradient: GrayImage
        if params.useColorEdges {
            gradient = ImageOps.colorSobelMagnitude(image, downsampleBy: scale)
        } else {
            let gray = ImageOps.grayscale(image)
            let small = scale > 1 ? ImageOps.areaDownsample(gray, to: iw / scale, ih / scale) : gray
            gradient = ImageOps.sobelMagnitude(small)
        }
        let edges = ImageOps.binarize(gradient, threshold: params.edgeThreshold)
        // IMAGE SURFACES ARE NEUTRAL GROUND: a face, a jersey number or film grain is not a panel seam,
        // and hiding the lines only in Peek would leave the SCENE wrong. nil when there are no images.
        let neutral = neutralMask(imageRects, imageSize: (iw, ih),
                                  gridSize: (gradient.width, gradient.height), inset: params.imageInsetPx)
        var out: [(x: Int, y: Int, w: Int, h: Int)] = []
        // Whole-window chrome owns its own strip; body columns must not cross the title text.
        var chromeParams = params; chromeParams.minSliceFrac = 0.02
        let chrome = boundaryLines(x: 0, y: 0, rw: gradient.width, rh: gradient.height,
            mask: edges, w: gradient.width, neutral: neutral, vertical: false, params: chromeParams)
            .filter { params.maxDepth > 0 && $0.fill >= 0.98 }
        let top = chrome.first { Double($0.pos) <= 0.15 * Double(gradient.height) }?.pos ?? 0
        let bottom = chrome.first { Double($0.pos) >= 0.85 * Double(gradient.height) }?.pos ?? gradient.height
        if top > 0 { out.append((0, 0, gradient.width, top)) }
        cut(x: 0, y: top, rw: gradient.width, rh: bottom - top, mask: edges, neutral: neutral, w: gradient.width,
            winW: gradient.width, winH: gradient.height,
            depth: params.maxDepth - ((top > 0 || bottom < gradient.height) ? 1 : 0), params: params, into: &out)
        if bottom < gradient.height { out.append((0, bottom, gradient.width, gradient.height - bottom)) }
        // Integer downsampling may discard a remainder; map the partition over the entire image.
        let sx = CGFloat(iw) / CGFloat(gradient.width), sy = CGFloat(ih) / CGFloat(gradient.height)
        return out.map { CGRect(x: CGFloat($0.x) * sx, y: CGFloat($0.y) * sy,
                                width: CGFloat($0.w) * sx, height: CGFloat($0.h) * sy) }
    }

    /// One recursion step: find boundary lines on both axes, split along the axis with the STRONGEST
    /// line (a transport strip's bottom edge spans the full window; a sidebar edge only spans the area
    /// below it — cutting the stronger line first lets recursion discover the weaker one inside).
    static func cut(x: Int, y: Int, rw: Int, rh: Int, mask: [Bool], neutral: [Bool]? = nil, w: Int, winW: Int, winH: Int,
                    depth: Int, params: Params, into out: inout [(x: Int, y: Int, w: Int, h: Int)]) {
        // Thin strips (toolbars, tab bars) are LEAVES — a 5%-tall strip's internal cell borders are
        // content, not panel boundaries. Both dims must clear the window-relative floor to subdivide.
        let bigEnough = Double(rw) >= params.minRegionFrac * Double(winW)
            && Double(rh) >= params.minRegionFrac * Double(winH)
        if depth > 0, bigEnough {
            // Cluster parallel lines within the slice floor to their strongest member — a boundary's
            // multi-line band (a sidebar's edge + track color strips) is ONE boundary, and the
            // periodicity veto must count boundaries, not band members (measured: the main region's
            // legit towers got wiped as "periodic" while a real grid has 10+ CLUSTERS).
            func clusters(_ lines: [(pos: Int, fill: Double)], minGap: Int) -> [(pos: Int, fill: Double)] {
                var out: [(pos: Int, fill: Double)] = []
                for line in lines.sorted(by: { $0.pos < $1.pos }) {
                    if let last = out.last, line.pos - last.pos < minGap {
                        if line.fill > last.fill { out[out.count - 1] = line }
                    } else { out.append(line) }
                }
                return out
            }
            let vGap = max(2, Int(Double(winW) * params.minSliceFrac))
            let hGap = max(2, Int(Double(winH) * params.minSliceFrac))
            var v = clusters(boundaryLines(x: x, y: y, rw: rw, rh: rh, mask: mask, w: w, neutral: neutral, vertical: true, params: params), minGap: vGap)
            var hz = clusters(collapseRepeatedRows(boundaryLines(x: x, y: y, rw: rw, rh: rh, mask: mask, w: w, neutral: neutral, vertical: false, params: params)), minGap: hGap)
            // PERIODICITY veto: a REGULAR grid of cells (toolbar, table, channel strips) is ONE section,
            // not many. But the veto must not throw away a STRONG outlier boundary that merely sits among
            // grid lines — e.g. Pro Tools' transport-strip edge (fill 1.0) among ~12 track-row separators
            // (measured: the whole window fell back to vertical-only because that edge got nuked). So:
            // drop the axis ONLY if its lines are near-uniformly spaced AND near-equal strength.
            if v.count > params.periodicMax, isRegularGrid(v) { v = [] }
            if hz.count > params.periodicMax, isRegularGrid(hz) { hz = [] }
            let vBest = v.map(\.fill).max() ?? 0
            let hBest = hz.map(\.fill).max() ?? 0
            if hBest >= params.fillMin || vBest >= params.fillMin {
                // Axis order encodes how app windows are BUILT: the ROOT peels horizontal EDGE STRIPS
                // only (title/transport/tab bars live within ~15% of the top/bottom edges — that's what
                // a strip is); the body then cuts COLUMNS first; bands come last, WITHIN their column.
                // Without the edge-zone rule the root grabs interior track-color boundaries (which can
                // measure fill 1.0 clear across the window when sidebar/clips rows happen to align) and
                // slices full-width bands through every panel (measured live).
                let isRoot = depth == params.maxDepth
                let isBody = depth == params.maxDepth - 1
                // root: COLUMNS FIRST when a near-full-height vertical boundary exists (measured on
                // Slack: sidebar/content edge fill 0.97 while the strips that were slicing the sidebar
                // in half — date dividers, composer border — are 0.72–0.78 window-wide; the nav-rail
                // edge then emerges at 1.00 INSIDE the isolated column). Otherwise peel horizontal
                // edge strips (Pro Tools transport measured 1.0 — still peels). Body: columns first;
                // deeper: strongest wins — bands emerge only INSIDE their own column.
                let vertical = isRoot ? (vBest >= params.columnFirstFill || hBest < params.fillMin)
                    : isBody ? vBest >= params.fillMin
                    : vBest > hBest
                let minGap = vertical ? vGap : hGap       // slice floor is WINDOW-relative
                let (lo, span) = vertical ? (x, rw) : (y, rh)
                var pool = vertical ? v : hz
                if isRoot, !vertical {
                    let zone = Int(Double(span) * 0.15)
                    let edgy = pool.filter { $0.pos - lo <= zone || lo + span - $0.pos <= zone }
                    pool = edgy.isEmpty ? pool.sorted(by: { $0.fill > $1.fill }).prefix(1).map { $0 } : edgy
                }
                let strongest = pool.sorted { $0.fill > $1.fill }
                    .prefix(params.maxLinesPerSplit).map(\.pos)
                var edgesAt = [lo] + strongest.sorted() + [lo + span]
                // A sub-floor sliver pinned to the region edge with a NEAR-TOTAL boundary survives:
                // Slack's nav rail is 5.5% wide (under the 6% floor) but its edge fills 0.95 — a real
                // column. Interior slivers and weak lines (a search box border at 0.75) stay banned,
                // so the floor still prevents over-cutting.
                let fillAt = Dictionary(pool.map { ($0.pos, $0.fill) }, uniquingKeysWith: max)
                // Vertical cuts only: rails are COLUMNS. A horizontal micro-band behind a strong line
                // (a search box border fills 0.9+ across a narrow sidebar) must stay under the floor.
                let sliverOK: (Int) -> Bool = vertical
                    ? { pos in (fillAt[pos] ?? 0) >= params.columnFirstFill }
                    : { _ in false }
                edgesAt = dedupeClose(edgesAt, minGap: minGap, keepSliver: sliverOK)
                if edgesAt.count > 2 {
                    for i in 0..<(edgesAt.count - 1) {
                        let a = edgesAt[i], b = edgesAt[i + 1]
                        if vertical { cut(x: a, y: y, rw: b - a, rh: rh, mask: mask, neutral: neutral, w: w, winW: winW, winH: winH, depth: depth - 1, params: params, into: &out) }
                        else { cut(x: x, y: a, rw: rw, rh: b - a, mask: mask, neutral: neutral, w: w, winW: winW, winH: winH, depth: depth - 1, params: params, into: &out) }
                    }
                    return
                }
            }
        }
        out.append((x, y, rw, rh))
    }

    /// Boundary lines along one axis of a region: positions whose edge-pixel fill across the region's
    /// other dimension ≥ fillMin. Adjacent candidates merge to the strongest position. Region-edge
    /// margins are excluded (a window's own border is not an internal boundary).
    static func boundaryLines(x: Int, y: Int, rw: Int, rh: Int, mask: [Bool], w: Int, neutral: [Bool]? = nil,
                              vertical: Bool, params: Params) -> [(pos: Int, fill: Double)] {
        let span = vertical ? rw : rh
        let depthLen = vertical ? rh : rw
        guard depthLen > 8, span > 8 else { return [] }
        let margin = max(2, Int(Double(span) * params.minSliceFrac))
        var candidates: [(pos: Int, fill: Double)] = []
        let lo = (vertical ? x : y) + margin
        let hi = (vertical ? x : y) + span - margin
        guard lo < hi else { return [] }
        let debug = ProcessInfo.processInfo.environment["LOCATOR_DEBUG_SECTIONS"] != nil
        var top: [(pos: Int, fill: Double)] = []
        for c in lo..<hi {
            var count = 0, longest = 0, runLength = 0, outside = 0
            for offset in 0..<depthLen {
                let index = vertical ? (y + offset) * w + c : c * w + x + offset
                // Inside an image surface the pixel is NEUTRAL: no fill, no length, and no run break — a
                // divider passing under a photo stays continuous, and a photo's texture proposes nothing.
                if let neutral, neutral[index] { continue }
                outside += 1
                if mask[index] {
                    count += 1; runLength += 1; longest = max(longest, runLength)
                } else { runLength = 0 }
            }
            // A seam is judged on its support OUTSIDE images, and needs enough of it to be a seam at all.
            guard outside > 0, Double(outside) / Double(depthLen) >= params.minOutsideFrac else { continue }
            let fill = Double(count) / Double(outside)
            // A document's repeated glyph columns are not panel seams. Retain total-fill evidence,
            // but require a sustained straight run as well; interrupted dividers can still qualify.
            if fill >= (vertical ? params.fillMin : max(params.fillMin, params.horizontalFillMin)), Double(longest) / Double(outside) >= params.minContinuousFrac {
                candidates.append((c, fill))
            }
            if debug, fill >= 0.3 { top.append((c, fill)) }
        }
        if debug, !top.isEmpty {
            let best = top.sorted { $0.fill > $1.fill }.prefix(8)
                .map { "\($0.pos):\(String(format: "%.2f", $0.fill))" }.joined(separator: " ")
            FileHandle.standardError.write(Data("[sections] region \(x),\(y) \(rw)×\(rh) \(vertical ? "V" : "H") top: \(best)\n".utf8))
        }
        // Merge runs of adjacent candidate positions to their strongest member.
        var lines: [(pos: Int, fill: Double)] = []
        var run: [(pos: Int, fill: Double)] = []
        for cand in candidates {
            if let last = run.last, cand.pos - last.pos > 3 {
                if let best = run.max(by: { $0.fill < $1.fill }) { lines.append(best) }
                run = []
            }
            run.append(cand)
        }
        if let best = run.max(by: { $0.fill < $1.fill }) { lines.append(best) }
        return lines
    }

    /// The analysis-grid mask of pixels INSIDE accepted image surfaces, each inset so the image's own
    /// border stays live (an image may be bounded by a seam, never cut through). nil when there are no
    /// images, so the common path pays nothing. Pure → unit-tested through `detect(excluding:)`.
    static func neutralMask(_ rects: [CGRect], imageSize: (w: Int, h: Int), gridSize: (w: Int, h: Int),
                            inset: Int) -> [Bool]? {
        guard !rects.isEmpty, gridSize.w > 0, gridSize.h > 0, imageSize.w > 0, imageSize.h > 0 else { return nil }
        let sx = Double(gridSize.w) / Double(imageSize.w), sy = Double(gridSize.h) / Double(imageSize.h)
        var mask = [Bool](repeating: false, count: gridSize.w * gridSize.h)
        var any = false
        for r in rects where !r.isNull && !r.isEmpty {
            let x0 = max(0, Int((r.minX * sx).rounded(.down)) + inset), x1 = min(gridSize.w, Int((r.maxX * sx).rounded(.up)) - inset)
            let y0 = max(0, Int((r.minY * sy).rounded(.down)) + inset), y1 = min(gridSize.h, Int((r.maxY * sy).rounded(.up)) - inset)
            guard x1 > x0, y1 > y0 else { continue }
            for yy in y0..<y1 { for xx in x0..<x1 { mask[yy * gridSize.w + xx] = true } }
            any = true
        }
        return any ? mask : nil
    }

    /// Keep the start of a repeated row group, not a separate pane for every other row.
    /// Its last repeated separator is not proof of a viewport end; retaining it cuts off the
    /// quiet space below an accordion and makes the resulting tight tile look falsely scrollable.
    /// Apply before min-slice clustering, which otherwise aliases densely spaced accordion rows.
    static func collapseRepeatedRows(_ lines: [(pos: Int, fill: Double)]) -> [(pos: Int, fill: Double)] {
        guard lines.count >= 7 else { return lines }
        var removed = Set<Int>()
        for start in 0...(lines.count - 7) {
            for end in stride(from: lines.count - 1, through: start + 6, by: -1) {
                let run = Array(lines[start...end])
                let gaps = zip(run.dropFirst(), run).map { Double($0.0.pos - $0.1.pos) }
                let mean = gaps.reduce(0,+) / Double(gaps.count)
                guard mean > 0, gaps.allSatisfy({ abs($0 - mean) <= 0.15 * mean }),
                      isRegularGrid(run) else { continue }
                for i in (start + 1)...end { removed.insert(i) }
                break
            }
        }
        return lines.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    /// A REGULAR grid = near-uniform gaps AND near-equal fills (a table/toolbar of identical cells).
    /// An irregular set — a strong panel edge sitting among weaker row separators, or panels of varied
    /// size — is NOT a grid, so its lines survive to be cut. Distinguishes "12 identical rows" (drop)
    /// from "1 transport edge + 12 rows" (keep, so the transport splits off).
    static func isRegularGrid(_ lines: [(pos: Int, fill: Double)]) -> Bool {
        guard lines.count >= 3 else { return false }
        let sorted = lines.sorted { $0.pos < $1.pos }
        let gaps = zip(sorted.dropFirst(), sorted).map { Double($0.0.pos - $0.1.pos) }
        let gMean = gaps.reduce(0, +) / Double(gaps.count)
        guard gMean > 0 else { return false }
        let gCV = (gaps.map { ($0 - gMean) * ($0 - gMean) }.reduce(0, +) / Double(gaps.count)).squareRoot() / gMean
        let fills = sorted.map(\.fill)
        let fMean = fills.reduce(0, +) / Double(fills.count)
        let fillSpread = fills.max()! - fills.min()!
        return gCV < 0.35 && fillSpread < 0.25 * fMean   // uniform spacing + uniform strength → a grid
    }

    /// Keep split positions at least `minGap` apart (first wins; interior order preserved).
    /// `keepSliver(pos)` may admit a closer-than-minGap position ADJACENT TO A REGION EDGE — a
    /// near-total-fill edge column (nav rail) is real even under the slice floor.
    static func dedupeClose(_ sorted: [Int], minGap: Int, keepSliver: (Int) -> Bool = { _ in false }) -> [Int] {
        guard let first = sorted.first, let trueEnd = sorted.last else { return sorted }
        var out: [Int] = []
        for v in sorted {
            let farEnough = out.last.map { v - $0 >= minGap } ?? true
            // Edge-pinned only: the FIRST interior line hugging the region start (a left nav rail),
            // or the LAST interior line hugging the region end (a right-pinned rail). Interior slivers
            // never pass — that is the slice floor doing its job.
            let startSliver = !farEnough && out.last == first && keepSliver(v) && v - first >= minGap / 2
            let endSliver = !farEnough && v != trueEnd && keepSliver(v)
                && trueEnd - v < minGap && trueEnd - v >= minGap / 2
            if farEnough || startSliver || endSliver { out.append(v) }
        }
        // the region's far edge must survive — replace the last kept if the true end was dropped
        if let trueEnd = sorted.last, out.last != trueEnd {
            if out.count > 1 { out[out.count - 1] = trueEnd } else { out.append(trueEnd) }
        }
        return out
    }
}
