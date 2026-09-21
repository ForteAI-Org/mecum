import CoreGraphics
import Accelerate

/// Spatial normalized cross-correlation. Window mean/variance come from integral images (O(1) each);
/// the cross term Σ(I·T) is a direct loop over the (small) template. Multi-scale by resizing the
/// template. Degenerate (flat) templates/windows score 0 rather than producing NaN.
///
/// The cross-term loop is O(template-area × candidate-positions), so a LARGE template (e.g. a coarse
/// 184×1146 AX element) is billions of ops. Pass `maxTemplateDimension` to run the match on
/// area-downsampled copies — NCC still localizes well at reduced resolution, and the result is mapped
/// back to full-resolution pixels.
public struct NCCTemplateMatcher: TemplateMatcher {
    public init() {}

    /// Protocol entry point — exact (no downscale).
    public func match(template: CGImage, in image: CGImage, searchRegion: CGRect?, scales: [CGFloat]) -> NCCMatch? {
        match(template: template, in: image, searchRegion: searchRegion, scales: scales, maxTemplateDimension: nil)
    }

    public func match(template: CGImage, in image: CGImage, searchRegion: CGRect?, scales: [CGFloat],
                      maxTemplateDimension: CGFloat?, maxSearchDimension: CGFloat? = nil) -> NCCMatch? {
        var img = ImageOps.grayscale(image)
        var tmpl = ImageOps.grayscale(template)
        guard img.width > 0, img.height > 0, tmpl.width > 0, tmpl.height > 0 else { return nil }

        // NCC requires the template and image at the SAME scale, so a SINGLE `factor` downsamples both.
        // maxTemplateDimension bounds a huge template; maxSearchDimension bounds a huge search window —
        // both keep the O(positions × template-area) loop tractable.
        var factor: CGFloat = 1
        let tmplLong = CGFloat(max(tmpl.width, tmpl.height))
        if let maxDim = maxTemplateDimension, tmplLong > maxDim { factor = min(factor, maxDim / tmplLong) }
        if let maxSearch = maxSearchDimension {
            let imgLong = CGFloat(max(img.width, img.height))
            if imgLong > maxSearch { factor = min(factor, maxSearch / imgLong) }
        }
        // Floor: never let the (window-driven) downscale crush the template below a statistically
        // meaningful size. A few-px template correlates ~1.0 with almost any flat patch → a confident
        // but GARBAGE match. Keep the template's long side ≥ minTemplatePx even at the ladder's smallest
        // scale; capped at 1 (we never upscale). Trades speed for correctness on the rare full-window path.
        let minScale = scales.filter { $0 > 0 }.min() ?? 1   // ignore non-positive scales (would poison the floor)
        let minTemplatePx: CGFloat = 16
        if tmplLong * factor * minScale < minTemplatePx {
            factor = min(1, minTemplatePx / (tmplLong * minScale))
        }
        if factor < 1 {
            img = ImageOps.areaDownsample(img, to: scaled(img.width, factor), scaled(img.height, factor))
            tmpl = ImageOps.areaDownsample(tmpl, to: scaled(tmpl.width, factor), scaled(tmpl.height, factor))
        }
        let region = searchRegion.map {
            CGRect(x: $0.minX * factor, y: $0.minY * factor, width: $0.width * factor, height: $0.height * factor)
        }
        guard let best = core(img: img, base: tmpl, searchRegion: region, scales: scales) else { return nil }
        // Map the location back to full-resolution pixels.
        return NCCMatch(locationPx: CGPoint(x: best.locationPx.x / factor, y: best.locationPx.y / factor), score: best.score)
    }

    private func scaled(_ v: Int, _ factor: CGFloat) -> Int { max(1, Int((CGFloat(v) * factor).rounded())) }

    /// The NCC search over already-grayscale images.
    private func core(img: GrayImage, base: GrayImage, searchRegion: CGRect?, scales: [CGFloat]) -> NCCMatch? {
        let integral = IntegralImage(img)
        let imageRect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let searchArea = (searchRegion?.integral ?? imageRect).intersection(imageRect)
        guard !searchArea.isNull else { return nil }
        let rx0 = Int(searchArea.minX), ry0 = Int(searchArea.minY)
        let rx1 = Int(searchArea.maxX), ry1 = Int(searchArea.maxY)

        var best: NCCMatch?
        for s in (scales.isEmpty ? [1.0] : scales) {
            let tw = max(1, Int((CGFloat(base.width) * s).rounded()))
            let th = max(1, Int((CGFloat(base.height) * s).rounded()))
            if tw > img.width || th > img.height { continue }

            let tmpl = ImageOps.resize(base, to: tw, th)
            let n = Double(tw * th)
            // A region/template must have REAL contrast (std-dev ≥ ~2 levels) to be a valid NCC
            // candidate. On a near-flat patch the formula (cross − n·μ_w·μ_t)/(wNorm·tNorm) is
            // numerically unstable: both terms collapse to rounding noise and the ratio can spuriously
            // clamp to 1.0 — a flat dark BACKGROUND "perfectly matching" a textured template. The old
            // `< 1e-6` only excluded EXACTLY flat; std-dev·√n excludes near-flat too. UI elements have
            // std-dev ≫ 2; only blank backgrounds fall below, so real matches are unaffected.
            let minNorm = 2.0 * n.squareRoot()
            var tSum = 0.0, tSumSq = 0.0
            for v in tmpl.pixels { let d = Double(v); tSum += d; tSumSq += d * d }
            let tMean = tSum / n
            let tNorm = max(0, tSumSq - n * tMean * tMean).squareRoot()
            if tNorm < minNorm { continue }

            let xEnd = min(rx1 - 1, img.width - tw)
            let yEnd = min(ry1 - 1, img.height - th)
            if xEnd < rx0 || yEnd < ry0 { continue }

            // Hot path: the cross-term Σ(I·T) is a per-row dot product. vDSP_dotpr (Accelerate, SIMD,
            // always present incl. headless CI) replaces the scalar tx loop; pointers are hoisted once
            // per scale. Per-row Float dots are summed in a Double accumulator to match the scalar
            // version's precision. Mean/variance still come from the IntegralImage (O(1)).
            img.pixels.withUnsafeBufferPointer { ip in
                tmpl.pixels.withUnsafeBufferPointer { tp in
                    guard let ibase = ip.baseAddress, let tbase = tp.baseAddress else { return }
                    for y in ry0...yEnd {
                        let yBase = y * img.width
                        for x in rx0...xEnd {
                            let wSum = integral.boxSum(x: x, y: y, w: tw, h: th)
                            let wSumSq = integral.boxSumSq(x: x, y: y, w: tw, h: th)
                            let wMean = wSum / n
                            let wNorm = max(0, wSumSq - n * wMean * wMean).squareRoot()
                            if wNorm < minNorm { continue }   // skip near-flat windows (see minNorm above)

                            var cross = 0.0
                            for ty in 0..<th {
                                var rowDot: Float = 0
                                vDSP_dotpr(ibase + (yBase + ty * img.width + x), 1, tbase + ty * tw, 1, &rowDot, vDSP_Length(tw))
                                cross += Double(rowDot)
                            }
                            let ncc = min(1.0, max(-1.0, (cross - n * wMean * tMean) / (wNorm * tNorm)))
                            if best == nil || ncc > best!.score {
                                best = NCCMatch(locationPx: CGPoint(x: x, y: y), score: ncc)
                            }
                        }
                    }
                }
            }
        }
        return best
    }
}
