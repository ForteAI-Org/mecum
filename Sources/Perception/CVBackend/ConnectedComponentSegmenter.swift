import CoreGraphics

/// Tuning knobs for the segmenter (defaults from the Phase 0 spike on Pro Tools).
public struct SegmentationParams: Sendable {
    /// Experimental for element outlines: RGB can merge checkbox/radio contours differently.
    /// Panel detection uses color independently; retain the validated grayscale control path by default.
    public var useColorEdges: Bool
    public var binarizeThreshold: Float   // on the [0,255]-normalized Sobel map — the #1 knob (~40)
    public var closeRadius: Int           // dilate to connect broken edges into one component (~2)
    public var erodeRadius: Int           // erode to separate touching elements (0 = off)
    public var minAreaPx: Int             // drop tiny components (bbox area)
    public var maxAreaFraction: Double    // drop the near-full-window blob
    public var minSidePx: Int             // drop slivers

    public init(binarizeThreshold: Float = 40, closeRadius: Int = 2, erodeRadius: Int = 0,
                minAreaPx: Int = 150, maxAreaFraction: Double = 0.4, minSidePx: Int = 6, useColorEdges: Bool = false) {
        self.useColorEdges = useColorEdges
        self.binarizeThreshold = binarizeThreshold
        self.closeRadius = closeRadius
        self.erodeRadius = erodeRadius
        self.minAreaPx = minAreaPx
        self.maxAreaFraction = maxAreaFraction
        self.minSidePx = minSidePx
    }
}

/// Classical-CV element segmentation, reimplemented from UIED's non-text pipeline (no UIED source):
/// Grayscale Sobel (experimental RGB available) → normalize → binarize → morphology → two-pass union-find labeling → filter.
/// Emits boxes in window-local pixels (offset back into full-image coords when a `region` is given).
public struct ConnectedComponentSegmenter: ElementSegmenter {
    public let params: SegmentationParams
    public init(params: SegmentationParams = .init()) { self.params = params }

    public func segment(in image: CGImage, region: CGRect?) -> [SegmentedElement] {
        let (input, ox, oy) = croppedImage(image, region)
        let w = input.width, h = input.height
        guard w >= 3, h >= 3 else { return [] }

        // Sobel, normalized to [0,255] so `binarizeThreshold` matches the Phase 0 ballpark.
        let sobel = params.useColorEdges ? ImageOps.colorSobelMagnitude(input)
            : ImageOps.sobelMagnitude(ImageOps.grayscale(input))
        let maxMag = sobel.pixels.max() ?? 0
        let norm = maxMag > 0 ? GrayImage(width: w, height: h, pixels: sobel.pixels.map { $0 / maxMag * 255 }) : sobel

        // The UNDILATED mask is kept: it is what rescues an over-chained blob below.
        let binMask = ImageOps.binarize(norm, threshold: params.binarizeThreshold)
        var mask = ImageOps.dilate(binMask, width: w, height: h, radius: params.closeRadius)
        if params.erodeRadius > 0 { mask = ImageOps.erode(mask, width: w, height: h, radius: params.erodeRadius) }

        let totalArea = Double(w * h)
        func passes(_ b: Box) -> Bool {
            b.width * b.height >= params.minAreaPx && b.width >= params.minSidePx && b.height >= params.minSidePx
        }
        var kept: [Box] = []
        var overSized: [Box] = []
        for b in label(mask, w: w, h: h) {
            guard passes(b) else { continue }
            if Double(b.width * b.height) <= params.maxAreaFraction * totalArea { kept.append(b) }
            else { overSized.append(b) }   // the near-full-window blob — recovered below, not binned
        }

        // RESCUE the discarded mega-blob. `closeRadius` dilation bridges any gap ≤ 2·radius, so a window's
        // border + panel splitters + title bars + tab strips can CHAIN into one component whose bbox is the
        // whole frame. That trips `maxAreaFraction` and used to be dropped outright — silently taking every
        // control welded to the chain with it (measured on Avid Media Composer: settings dialogs lost 10/10
        // of their window furniture, one blob holding 46.6% of all edge pixels).
        //
        // So instead of binning it, re-label its region on the UNDILATED mask: without the bridging, the
        // chain falls apart into the real controls. This is deliberately LOCAL — globally disabling dilation
        // recovers Media Composer (+4.0 actionable recall) but wrecks DaVinci Resolve (−10.1), whose thin
        // strokes need the dilation to close. Applying it only inside a blob that was already being thrown
        // away is strictly additive: one level deep, no recursion, and nothing here can remove a box.
        for blob in overSized {
            for sub in label(subMask(binMask, w: w, h: h, box: blob), w: blob.width, h: blob.height) {
                let abs = Box(minX: sub.minX + blob.minX, minY: sub.minY + blob.minY, width: sub.width, height: sub.height)
                guard passes(abs), Double(abs.width * abs.height) <= params.maxAreaFraction * totalArea else { continue }
                // Don't duplicate a box we already emitted (a small component can merely sit inside the
                // blob's bbox without belonging to the chain).
                let dup = kept.contains { k in
                    let ix = max(0, min(k.minX + k.width, abs.minX + abs.width) - max(k.minX, abs.minX))
                    let iy = max(0, min(k.minY + k.height, abs.minY + abs.height) - max(k.minY, abs.minY))
                    return Double(ix * iy) > 0.5 * Double(min(k.width * k.height, abs.width * abs.height))
                }
                if !dup { kept.append(abs) }
            }
        }

        return kept.map {
            SegmentedElement(bboxPx: CGRect(x: $0.minX + ox, y: $0.minY + oy, width: $0.width, height: $0.height))
        }
    }

    typealias Box = (minX: Int, minY: Int, width: Int, height: Int)

    /// The mask restricted to `box`, as its own w×h buffer (for re-labelling inside one component).
    private func subMask(_ mask: [Bool], w: Int, h: Int, box: Box) -> [Bool] {
        var out = [Bool](repeating: false, count: box.width * box.height)
        for yy in 0..<box.height {
            let sy = box.minY + yy
            guard sy >= 0, sy < h else { continue }
            for xx in 0..<box.width {
                let sx = box.minX + xx
                guard sx >= 0, sx < w else { continue }
                out[yy * box.width + xx] = mask[sy * w + sx]
            }
        }
        return out
    }

    // MARK: Two-pass connected-component labeling (8-connectivity)

    private func label(_ mask: [Bool], w: Int, h: Int) -> [Box] {
        var labels = [Int32](repeating: 0, count: w * h)   // 0 = background; else union-find id + 1
        var uf = UnionFind()
        var sets = 0
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let idx = row + x
                guard mask[idx] else { continue }
                // The four already-labelled 8-neighbours (left, up, up-left, up-right) — plain locals, no
                // per-pixel array: the old `neighbors: [Int]` allocation was the labeller's whole cost.
                let l: Int32 = x > 0 ? labels[idx - 1] : 0
                let u: Int32 = y > 0 ? labels[idx - w] : 0
                let ul: Int32 = (x > 0 && y > 0) ? labels[idx - w - 1] : 0
                let ur: Int32 = (x < w - 1 && y > 0) ? labels[idx - w + 1] : 0
                var m = Int32.max
                if l != 0 { m = min(m, l) }
                if u != 0 { m = min(m, u) }
                if ul != 0 { m = min(m, ul) }
                if ur != 0 { m = min(m, ur) }
                if m == Int32.max {
                    labels[idx] = Int32(uf.makeSet() + 1); sets += 1
                } else {
                    labels[idx] = m
                    if l != 0, l != m { uf.union(Int(m) - 1, Int(l) - 1) }
                    if u != 0, u != m { uf.union(Int(m) - 1, Int(u) - 1) }
                    if ul != 0, ul != m { uf.union(Int(m) - 1, Int(ul) - 1) }
                    if ur != 0, ur != m { uf.union(Int(m) - 1, Int(ur) - 1) }
                }
            }
        }
        // Bounding boxes per root, in root order. DETERMINISTIC on purpose: the old dictionary walk emitted
        // segments in per-process random order, and downstream coalescing/greedy pairing is order-sensitive
        // enough to move the benchmark by ±1–3 boxes per run (measured 2026-09-06 by shuffling).
        var minX = [Int](repeating: Int.max, count: sets), minY = minX
        var maxX = [Int](repeating: -1, count: sets), maxY = maxX
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let l = labels[row + x]
                guard l != 0 else { continue }
                let root = uf.find(Int(l) - 1)
                if x < minX[root] { minX[root] = x }
                if x > maxX[root] { maxX[root] = x }
                if y < minY[root] { minY[root] = y }
                if y > maxY[root] { maxY[root] = y }
            }
        }
        var out: [Box] = []
        for r in 0..<sets where maxX[r] >= 0 {
            out.append(Box(minX: minX[r], minY: minY[r], width: maxX[r] - minX[r] + 1, height: maxY[r] - minY[r] + 1))
        }
        return out
    }

    /// Region-local input with its original top-left offset.
    private func croppedImage(_ image: CGImage, _ region: CGRect?) -> (CGImage, Int, Int) {
        guard let region else { return (image, 0, 0) }
        let r = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let crop = image.cropping(to: r) else { return (image, 0, 0) }
        return (crop, Int(r.minX), Int(r.minY))
    }
}
