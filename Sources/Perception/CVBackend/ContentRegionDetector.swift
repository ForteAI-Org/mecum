import CoreGraphics

/// PHOTOGRAPHIC / VIDEO CONTENT DETECTOR — the moat fix for scene NOISE. A photo (a Google-Images
/// thumbnail, a video frame, an Instagram post) makes the connected-component segmenter explode into
/// dozens of spurious "elements" (a face, a jersey number, crowd texture — none of them controls).
/// Measured live: a Messi image grid produced 344 elements / 1.1s, almost all garbage inside photos.
///
/// Finds candidate photographic regions from local texture, then rejects sparse bounding rectangles,
/// text-heavy regions, and aligned lists. These are conservative hypotheses, not semantic image
/// recognition: a rejected candidate leaves the original controls available to later stages.
public enum ContentRegionDetector {
    /// The signals measured for one candidate region — the tuning surface. `diagnose` returns these
    /// per candidate so the offline loop (`debug-segment --content`) can SEE why a region fires or not at
    /// a given resolution, instead of guessing thresholds blind.
    public struct RegionSignals: Sendable, Equatable {
        public let rect: CGRect
        public let textureFill: Double   // textured cells / bounding rectangle cells
        public let aspect: Double        // w/h — photos ~square; extreme strips are UI bars
        public let segsInside: Int       // segmenter boxes centered in the region (the "explosion")
        public let textInside: Int       // OCR runs centered in the region
        public let textPerMpx: Double    // textInside / megapixels — RESOLUTION-DEPENDENT (legacy signal)
        public let textCoverage: Double  // text pixel-area / region area — RESOLUTION-INVARIANT discriminator
        public let textPerSeg: Double    // textInside / segsInside — content-relative, res-robust-ish
        public let leftAlign: Double     // fraction of text runs sharing a dominant left-edge — LIST structure
        public let textRows: Int         // distinct y-clustered text rows — a list has many, a photo few
        public let keep: Bool            // did this region pass the suppression filter?
        public let rejectReason: String  // "" when kept, else why it was rejected (for tuning)
    }

    /// Texture proposes a connected region; occupancy, segment count, and text structure decide
    /// whether its bounding rectangle is safe to suppress. A connected border around a quiet UI
    /// is not a photograph of the entire window.
    public static func contentRegions(in image: CGImage, segments: [CGRect], textBoxes: [CGRect] = [],
                                      cellPx cellPxIn: Int = -1,
                                      textureThreshold: Float = 10.0, minSideCells: Int = 3,
                                      minSegsInRegion: Int = 10,
                                      maxTextCoverage: Double = 0.15,
                                      maxLeftAlign: Double = 0.4,
                                      minTextureFill: Double = 0.75) -> [CGRect] {
        diagnose(in: image, segments: segments, textBoxes: textBoxes, cellPx: cellPxIn,
                 textureThreshold: textureThreshold, minSideCells: minSideCells,
                 minSegsInRegion: minSegsInRegion, maxTextCoverage: maxTextCoverage, maxLeftAlign: maxLeftAlign,
                 minTextureFill: minTextureFill)
            .filter { $0.keep }.map { $0.rect }
    }

    /// Same pipeline as `contentRegions` but returns EVERY candidate region with its measured signals and
    /// the keep/reject decision — the offline tuning + diagnosis surface. Behaviour of `contentRegions`
    /// is exactly `diagnose(...).filter(keep).map(rect)`, so the two can never drift.
    public static func diagnose(in image: CGImage, segments: [CGRect], textBoxes: [CGRect] = [],
                                cellPx cellPxIn: Int = -1,
                                textureThreshold: Float = 10.0, minSideCells: Int = 3,
                                minSegsInRegion: Int = 10,
                                maxTextCoverage: Double = 0.15,
                                maxLeftAlign: Double = 0.4,
                                minTextureFill: Double = 0.75) -> [RegionSignals] {
        let W = image.width, H = image.height
        guard W >= 64, H >= 64, !segments.isEmpty else { return [] }
        // RESOLUTION-ADAPTIVE grid: ~64 cells across the frame, so behaviour is stable whether the live
        // capture is 1840px or a Retina 3024px window (tuned on 3024, must also fire on 1840).
        let cellPx = cellPxIn > 0 ? cellPxIn : max(20, W / 64)
        let gw = max(1, W / cellPx), gh = max(1, H / cellPx)

        // pixel texture per cell (draw the frame at grid resolution, 3×3 luma std)
        var rgba = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: gw, height: gh, bitsPerComponent: 8,
                                      bytesPerRow: gw * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        }
        var luma = [Float](repeating: 0, count: gw * gh)
        for i in 0..<(gw * gh) {
            luma[i] = 0.299 * Float(rgba[i*4]) + 0.587 * Float(rgba[i*4+1]) + 0.114 * Float(rgba[i*4+2])
        }
        func textured(_ x: Int, _ y: Int) -> Bool {
            var sum: Float = 0, sum2: Float = 0, n: Float = 0
            for dy in -1...1 { let ny = y+dy; if ny<0||ny>=gh {continue}
                for dx in -1...1 { let nx = x+dx; if nx<0||nx>=gw {continue}
                    let v = luma[ny*gw+nx]; sum+=v; sum2+=v*v; n+=1 } }
            let mean = sum/n; return (max(0, sum2/n - mean*mean)).squareRoot() >= textureThreshold
        }

        // textured mask → connected components → candidate regions
        var mask = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { mask[y*gw+x] = textured(x, y) } }
        var seen = [Bool](repeating: false, count: gw * gh)
        var candidates: [CGRect] = []
        var stack: [(Int, Int)] = []
        for sy in 0..<gh { for sx in 0..<gw {
            let i0 = sy*gw+sx; guard mask[i0], !seen[i0] else { continue }
            var minX=sx, maxX=sx, minY=sy, maxY=sy
            stack.removeAll(keepingCapacity: true); stack.append((sx, sy)); seen[i0] = true
            while let (cx, cy) = stack.popLast() {
                minX=min(minX,cx); maxX=max(maxX,cx); minY=min(minY,cy); maxY=max(maxY,cy)
                for (nx, ny) in [(cx-1,cy),(cx+1,cy),(cx,cy-1),(cx,cy+1)] {
                    if nx<0||nx>=gw||ny<0||ny>=gh { continue }
                    let ni = ny*gw+nx; if mask[ni] && !seen[ni] { seen[ni]=true; stack.append((nx,ny)) }
                }
            }
            let cw = maxX-minX+1, ch = maxY-minY+1
            guard cw >= minSideCells, ch >= minSideCells else { continue }
            candidates.append(CGRect(x: minX*cellPx, y: minY*cellPx, width: cw*cellPx, height: ch*cellPx)
                        .intersection(CGRect(x: 0, y: 0, width: W, height: H)))
        } }
        // SUPPRESS a region as a PHOTO only if ALL of:
        //   • texture occupies at least minTextureFill of its rectangle — no large quiet holes, AND
        //   • roughly square (aspect 0.25–4) — strips are UI bars, AND
        //   • segment-heavy (≥ minSegsInRegion) — it actually causes the explosion, AND
        //   • TEXT-SPARSE by AREA (text pixels cover < maxTextCoverage of the region) — the photo↔UI
        //     discriminator, and RESOLUTION-INVARIANT, AND
        //   • NOT a left-aligned list (leftAlign < maxLeftAlign) — a text-light note-list is low-coverage
        //     but a real list; alignment rescues it (see the list-structure note below).
        // The old signal (OCR runs per megapixel) was resolution-DEPENDENT and broke live: the run COUNT
        // is fixed by what's on screen (~68 captions) but the megapixel denominator collapses quadratically,
        // so the SAME Messi grid read 13/Mpx at 3024px (suppressed) yet 36/Mpx at 1840px (missed) — the
        // measured "under-fires at the live window size" bug. Text-COVERAGE fixes it: text boxes scale with
        // the image, so the fraction is identical at any resolution. Measured across the corpus: photos
        // cluster at 8–9% coverage, real UI/text panels at 18–67% (Finder 38%, Claude 55%, a Wikipedia
        // article 44–67%), a clean gap that holds at 1512/1840/3024px. This also fixes a SECOND bug the old
        // signal had — over-suppressing a large text-heavy article (low runs/Mpx but high coverage).
        return candidates.map { region in
            // The rectangle can contain large holes even though its border is connected. In the
            // visual audit, whole-window UI candidates were often only 24–57% textured; both
            // photo-grid fixtures were ~81%. Rejecting sparse rectangles preserves their controls.
            let x0 = Int(region.minX) / cellPx, x1 = Int(region.maxX) / cellPx
            let y0 = Int(region.minY) / cellPx, y1 = Int(region.maxY) / cellPx
            var filled = 0
            for y in y0..<y1 { for x in x0..<x1 where mask[y * gw + x] { filled += 1 } }
            let textureFill = Double(filled) / Double(max(1, (x1 - x0) * (y1 - y0)))
            let aspect = Double(region.width / max(1, region.height))
            let segIn = segments.reduce(0) { $0 + (region.contains(CGPoint(x: $1.midX, y: $1.midY)) ? 1 : 0) }
            let textIn = textBoxes.reduce(0) { $0 + (region.contains(CGPoint(x: $1.midX, y: $1.midY)) ? 1 : 0) }
            let mpx = max(0.05, Double(region.width * region.height) / 1_000_000)
            let textPerMpx = Double(textIn) / mpx
            // RESOLUTION-INVARIANT text signal: fraction of the region's pixels covered by OCR text boxes.
            // Text boxes scale with the image, so this ratio is the same at 3024px or 1840px — unlike
            // text/Mpx, whose denominator collapses quadratically while the run COUNT stays fixed.
            let regionArea = Double(region.width * region.height)
            let textArea = textBoxes.reduce(0.0) { acc, t in
                let i = region.intersection(t); return acc + (i.isNull ? 0 : Double(i.width * i.height))
            }
            let textCoverage = regionArea > 0 ? textArea / regionArea : 0
            let textPerSeg = segIn > 0 ? Double(textIn) / Double(segIn) : 0
            // LIST STRUCTURE (resolution-invariant): a navigation list stacks text in a LEFT-ALIGNED column
            // of many rows; a photo's text (captions, jersey numbers) is scattered. Two cheap measures over
            // the region's own text runs: the fraction sharing a dominant left-edge x, and the count of
            // distinct y-clustered rows. This is what tells a text-light note-list (low coverage, but a real
            // list) apart from a photo of the same coverage.
            let inTexts = textBoxes.filter { region.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            var leftAlign = 0.0, textRows = 0
            if inTexts.count >= 3 {
                let lefts = inTexts.map { Double($0.minX) }.sorted()
                let medLeft = lefts[lefts.count / 2]
                let tolX = Double(region.width) * 0.06
                leftAlign = Double(inTexts.filter { abs(Double($0.minX) - medLeft) <= tolX }.count) / Double(inTexts.count)
                let ys = inTexts.map { Double($0.midY) }.sorted()
                let rowTol = Double(region.height) * 0.02
                var rows = 1
                for i in 1..<ys.count where ys[i] - ys[i-1] > rowTol { rows += 1 }
                textRows = rows
            }
            var reason = ""
            if !(aspect <= 4.0 && aspect >= 0.25) { reason = "aspect \(String(format: "%.2f", aspect))" }
            else if textureFill < minTextureFill { reason = "sparse texture \(String(format: "%.2f", textureFill))<\(String(format: "%.2f", minTextureFill))" }
            else if segIn < minSegsInRegion { reason = "segs \(segIn)<\(minSegsInRegion)" }
            else if !(textCoverage < maxTextCoverage) { reason = "cover \(String(format: "%.1f", textCoverage*100))%≥\(String(format: "%.0f", maxTextCoverage*100))%" }
            // A left-aligned column of text rows is a navigation LIST, not a photo — keep it even at low
            // coverage (a tall note-list is mostly whitespace). Aligned ⇒ keep is strictly safe: it only
            // ever suppresses LESS, so it can never eat a control.
            else if !(leftAlign < maxLeftAlign) { reason = "align \(String(format: "%.2f", leftAlign))≥\(String(format: "%.2f", maxLeftAlign)) (list)" }
            return RegionSignals(rect: region, textureFill: textureFill, aspect: aspect, segsInside: segIn, textInside: textIn,
                                 textPerMpx: textPerMpx, textCoverage: textCoverage, textPerSeg: textPerSeg,
                                 leftAlign: leftAlign, textRows: textRows,
                                 keep: reason.isEmpty, rejectReason: reason)
        }
    }
}
