import CoreGraphics
import Accelerate

/// Local photographic surface proposals. Flat palette colors and smooth UI backgrounds are removed
/// before connected components, so a photo cannot borrow toolbar/text edges as its enclosing boundary.
/// This is pixel geometry, not a semantic classifier; screenshots, diagrams and overlaid controls can
/// still be ambiguous. All work is bounded to a 1200-pixel analysis image.
///
/// Two phases so the pixel work can overlap OCR: `analyze` needs only the image (histogram, texture
/// mask, components, colour-bin check), `finish` applies the text-area filter and gutter splits.
/// `detect` is the two run back to back. Measured 2026-09-06: the per-pixel `Dictionary` histogram and
/// `Set` membership were ~15% of the whole perception pass; a radix-sorted histogram, a 2^24-bit
/// background bitset and vImage 3×3 min/max make the same decisions in a fraction of the time.
public enum ImageSurfaceDetector {
    public struct Analysis: Sendable {
        let w: Int, h: Int
        let sx: Double, sy: Double
        let rgba: [UInt8]
        let backgroundKeys: [Int]          // the ≤32 dominant 24-bit colours
        let candidates: [CGRect]           // image-pixel rects that passed every pixel test but the text filter
        public static let empty = Analysis(w: 0, h: 0, sx: 1, sy: 1, rgba: [], backgroundKeys: [], candidates: [])
    }

    public static func detect(in image: CGImage, textBoxes: [CGRect] = []) -> [CGRect] {
        finish(analyze(in: image), textBoxes: textBoxes)
    }

    public static func analyze(in image: CGImage) -> Analysis {
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard w >= 40, h >= 40, let rgba = ImageOps.renderRGBA(image, width: w, height: h, highQuality: true) else { return .empty }
        let n = w * h
        @inline(__always) func key(_ i: Int) -> Int { Int(rgba[i * 4]) << 16 | Int(rgba[i * 4 + 1]) << 8 | Int(rgba[i * 4 + 2]) }

        // BACKGROUND PALETTE: colours covering > 0.1% of the frame, the 32 most frequent (ties by key).
        let backgroundKeys = dominantColors(rgba, count: n, minCount: n / 1000, limit: 32)
        var bg = [UInt64](repeating: 0, count: 1 << 18)          // 2^24 bits: is this colour background?
        for k in backgroundKeys { bg[k >> 6] |= 1 << UInt64(k & 63) }
        @inline(__always) func isBackground(_ k: Int) -> Bool { bg[k >> 6] & (1 << UInt64(k & 63)) != 0 }

        // TEXTURE MASK: a non-background pixel whose 3×3 neighbourhood varies by > 2 in ANY channel.
        // Smooth gradients in browser chrome are not photographic texture, even when every pixel has a
        // different colour; isoluminant hues still count.
        var mask = [UInt8](repeating: 0, count: n)
        if let planes = channelPlanes(rgba, w: w, h: h),
           let rMax = ImageOps.boxMorphology8(planes.r, width: w, height: h, kernel: 3, dilate: true),
           let rMin = ImageOps.boxMorphology8(planes.r, width: w, height: h, kernel: 3, dilate: false),
           let gMax = ImageOps.boxMorphology8(planes.g, width: w, height: h, kernel: 3, dilate: true),
           let gMin = ImageOps.boxMorphology8(planes.g, width: w, height: h, kernel: 3, dilate: false),
           let bMax = ImageOps.boxMorphology8(planes.b, width: w, height: h, kernel: 3, dilate: true),
           let bMin = ImageOps.boxMorphology8(planes.b, width: w, height: h, kernel: 3, dilate: false) {
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                guard !isBackground(key(i)) else { continue }
                if Int(rMax[i]) - Int(rMin[i]) > 2 || Int(gMax[i]) - Int(gMin[i]) > 2 || Int(bMax[i]) - Int(bMin[i]) > 2 { mask[i] = 1 }
            } }
        } else {
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                guard !isBackground(key(i)) else { continue }
                var varied = false
                for channel in 0..<3 {
                    var lo: UInt8 = 255, hi: UInt8 = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let v = rgba[((y + dy) * w + x + dx) * 4 + channel]
                        lo = min(lo, v); hi = max(hi, v)
                    } }
                    if Int(hi) - Int(lo) > 2 { varied = true; break }
                }
                mask[i] = varied ? 1 : 0
            } }
        }
        // A 3×3 opening breaks glyph/anti-alias bridges without joining adjacent photographs. The border
        // never erodes to foreground (a neighbour would be off-image) but may be re-covered by dilation.
        mask = opening3x3(mask, w: w, h: h)

        // CONNECTED TEXTURE BLOBS → candidate photo rects (size, density, aspect, colour richness).
        var seen = [Bool](repeating: false, count: n), stack: [Int] = [], candidates: [CGRect] = []
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        for seed in 0..<n where mask[seed] != 0 && !seen[seed] {
            stack.removeAll(keepingCapacity: true); stack.append(seed); seen[seed] = true
            var x0 = seed % w, x1 = x0, y0 = seed / w, y1 = y0, count = 0
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); count += 1
                if x > 0, mask[i - 1] != 0, !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x + 1 < w, mask[i + 1] != 0, !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w] != 0, !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y + 1 < h, mask[i + w] != 0, !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }
            let bw = x1 - x0 + 1, bh = y1 - y0 + 1, area = bw * bh
            guard min(bw, bh) >= 40, area >= 2500,
                  Double(count) / Double(area) >= 0.4,
                  Double(bw) / Double(bh) >= 0.2, Double(bw) / Double(bh) <= 5 else { continue }
            // Flat colored panels/buttons and grayscale glyphs have too few occupied color bins.
            var bins = [Int](repeating: 0, count: 4096), occupied = 0, dominant = 0
            for y in y0...y1 { for x in x0...x1 {
                let i = (y * w + x) * 4
                let b = Int(rgba[i] >> 4) << 8 | Int(rgba[i + 1] >> 4) << 4 | Int(rgba[i + 2] >> 4)
                if bins[b] == 0 { occupied += 1 }; bins[b] += 1; dominant = max(dominant, bins[b])
            } }
            guard occupied >= 40, Double(dominant) / Double(area) <= 0.6 else { continue }
            candidates.append(CGRect(x: Double(x0) * sx, y: Double(y0) * sy, width: Double(bw) * sx, height: Double(bh) * sy))
        }
        return Analysis(w: w, h: h, sx: sx, sy: sy, rgba: rgba, backgroundKeys: backgroundKeys, candidates: candidates)
    }

    public static func finish(_ a: Analysis, textBoxes: [CGRect]) -> [CGRect] {
        guard a.w > 0, a.h > 0 else { return [] }
        let w = a.w, h = a.h, sx = a.sx, sy = a.sy, rgba = a.rgba
        // Text-heavy surfaces are documents, not pictures.
        let proposals = a.candidates.filter { r in
            let textArea = textBoxes.reduce(0.0) { sum, text in
                let overlap = r.intersection(text)
                return sum + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            return textArea / (r.width * r.height) < 0.15
        }
        guard !proposals.isEmpty else { return [] }
        // Undo occasional bridges between adjacent thumbnails. A gutter must be a repeated UI palette
        // colour along almost its entire span, not merely a quiet patch inside a photograph. Palette
        // membership is a 15-bit lookup table, not a hashed Set per pixel.
        func gutterKey(_ rgb: Int) -> Int { (rgb >> 19) << 10 | ((rgb >> 11) & 31) << 5 | ((rgb >> 3) & 31) }
        var gutterLUT = [Bool](repeating: false, count: 1 << 15)
        for k in a.backgroundKeys { gutterLUT[gutterKey(k)] = true }
        @inline(__always) func isGutter(_ i: Int) -> Bool {
            gutterLUT[Int(rgba[i * 4] >> 3) << 10 | Int(rgba[i * 4 + 1] >> 3) << 5 | Int(rgba[i * 4 + 2] >> 3)]
        }
        func splitAtGutters(_ r: CGRect, depth: Int) -> [CGRect] {
            guard depth < 6 else { return [r] }
            let x0 = max(0, Int((r.minX / sx).rounded())), x1 = min(w, Int((r.maxX / sx).rounded()))
            let y0 = max(0, Int((r.minY / sy).rounded())), y1 = min(h, Int((r.maxY / sy).rounded()))
            for vertical in [true, false] {
                let lo = vertical ? x0 : y0, hi = vertical ? x1 : y1
                let crossLo = vertical ? y0 : x0, crossHi = vertical ? y1 : x1
                guard hi - lo > 82, crossHi > crossLo else { continue }
                var start: Int?
                for pos in (lo + 40)..<(hi - 39) {
                    var flat = 0
                    for cross in crossLo..<crossHi {
                        let i = vertical ? cross * w + pos : pos * w + cross
                        if isGutter(i) { flat += 1 }
                    }
                    let gutter = Double(flat) / Double(crossHi - crossLo) >= 0.92
                    if gutter { if start == nil { start = pos } }
                    else if let a = start {
                        if pos - a >= 2 {
                            let first = vertical
                                ? CGRect(x: r.minX, y: r.minY, width: Double(a) * sx - r.minX, height: r.height)
                                : CGRect(x: r.minX, y: r.minY, width: r.width, height: Double(a) * sy - r.minY)
                            let second = vertical
                                ? CGRect(x: Double(pos) * sx, y: r.minY, width: r.maxX - Double(pos) * sx, height: r.height)
                                : CGRect(x: r.minX, y: Double(pos) * sy, width: r.width, height: r.maxY - Double(pos) * sy)
                            return splitAtGutters(first, depth: depth + 1) + splitAtGutters(second, depth: depth + 1)
                        }
                        start = nil
                    }
                }
            }
            return [r]
        }
        return consolidate(proposals).flatMap { splitAtGutters($0, depth: 0) }
    }

    // MARK: pixel helpers

    /// Exact 24-bit colour histogram by LSD radix sort (3 byte passes), then the colours with more than
    /// `minCount` pixels, most frequent first (ties by smaller key), at most `limit`.
    static func dominantColors(_ rgba: [UInt8], count n: Int, minCount: Int, limit: Int) -> [Int] {
        guard n > 0 else { return [] }
        var keys = [UInt32](repeating: 0, count: n), tmp = keys
        for i in 0..<n { keys[i] = UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2]) }
        var counts = [Int](repeating: 0, count: 256)
        for shift in stride(from: 0, to: 24, by: 8) {
            for c in counts.indices { counts[c] = 0 }
            for k in keys { counts[Int((k >> UInt32(shift)) & 255)] += 1 }
            var offset = 0
            for c in counts.indices { let cnt = counts[c]; counts[c] = offset; offset += cnt }
            for k in keys { let b = Int((k >> UInt32(shift)) & 255); tmp[counts[b]] = k; counts[b] += 1 }
            swap(&keys, &tmp)
        }
        var found: [(key: Int, count: Int)] = []
        var i = 0
        while i < n {
            var j = i + 1
            while j < n, keys[j] == keys[i] { j += 1 }
            if j - i > minCount { found.append((Int(keys[i]), j - i)) }
            i = j
        }
        return found.sorted { $0.count > $1.count || ($0.count == $1.count && $0.key < $1.key) }.prefix(limit).map(\.key)
    }

    /// Split interleaved RGBA into three planes (vImage); nil when vImage refuses.
    static func channelPlanes(_ rgba: [UInt8], w: Int, h: Int) -> (r: [UInt8], g: [UInt8], b: [UInt8])? {
        var src = rgba
        var r = [UInt8](repeating: 0, count: w * h), g = r, b = r, a = r
        let err: vImage_Error = src.withUnsafeMutableBufferPointer { s in
            r.withUnsafeMutableBufferPointer { rp in g.withUnsafeMutableBufferPointer { gp in
            b.withUnsafeMutableBufferPointer { bp in a.withUnsafeMutableBufferPointer { ap in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var rb = vImage_Buffer(data: rp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var gb = vImage_Buffer(data: gp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var bb = vImage_Buffer(data: bp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var ab = vImage_Buffer(data: ap.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageConvert_ARGB8888toPlanar8(&sb, &rb, &gb, &bb, &ab, vImage_Flags(kvImageNoFlags))
            } } } }
        }
        return err == kvImageNoError ? (r, g, b) : nil
    }

    /// 3×3 erosion then 3×3 dilation on a 0/1 plane, border pixels never eroded to foreground.
    static func opening3x3(_ mask: [UInt8], w: Int, h: Int) -> [UInt8] {
        if var eroded = ImageOps.boxMorphology8(mask, width: w, height: h, kernel: 3, dilate: false) {
            for x in 0..<w { eroded[x] = 0; eroded[(h - 1) * w + x] = 0 }
            for y in 0..<h { eroded[y * w] = 0; eroded[y * w + w - 1] = 0 }
            if let dilated = ImageOps.boxMorphology8(eroded, width: w, height: h, kernel: 3, dilate: true) { return dilated }
        }
        var eroded = [UInt8](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where mask[y * w + x] != 0 {
            eroded[y * w + x] = (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in mask[(y + dy) * w + x + dx] != 0 } } ? 1 : 0
        } }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where eroded[y * w + x] != 0 {
            for dy in -1...1 { for dx in -1...1 { out[(y + dy) * w + x + dx] = 1 } }
        } }
        return out
    }

    /// Different textured parts of one photo can be disconnected across a quiet sky or dark strip.
    /// Merge substantially overlapping hypotheses; adjacent thumbnails remain separate.
    static func consolidate(_ proposals: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for proposal in proposals.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            var merged = proposal, changed = true
            while changed {
                changed = false
                for i in result.indices.reversed() {
                    let other = result[i], overlap = other.intersection(merged)
                    guard !overlap.isNull,
                        overlap.width * overlap.height >= 0.15 * min(other.width * other.height, merged.width * merged.height) else { continue }
                    merged = merged.union(other); result.remove(at: i); changed = true
                }
            }
            result.append(merged)
        }
        return result.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    /// A compact glyph on a nearly uniform surrounding backing can be a real media overlay
    /// (play/next/close). Retain it as an unknown candidate, not a confirmed semantic control.
    public static func hasControlBacking(_ box: CGRect, in image: CGImage, regions: [CGRect]) -> Bool {
        guard box.width >= 9, box.height >= 9, box.width / box.height >= 0.4,
              box.width / box.height <= 2.5,
              let region = regions.first(where: { containsMost(of: box, in: [$0]) }),
              max(box.width, box.height) <= min(region.width, region.height) * 0.25 else { return false }
        let pad = max(4, Int(min(box.width, box.height) * 0.35))
        let rect = box.integral.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad))
        guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
              let crop = image.cropping(to: rect) else { return false }
        // Keep per-candidate work bounded; large picture objects never justify expensive rescues.
        let w = crop.width, h = crop.height
        guard w <= 180, h <= 180, let bytes = ImageOps.renderRGBA(crop, width: w, height: h) else { return false }
        var bins = [Int: Int](), total = 0
        for y in 0..<h { for x in 0..<w where x < pad || y < pad || x >= w - pad || y >= h - pad {
            let i = (y * w + x) * 4
            let key = Int(bytes[i] >> 3) << 10 | Int(bytes[i + 1] >> 3) << 5 | Int(bytes[i + 2] >> 3)
            bins[key, default: 0] += 1; total += 1
        } }
        guard let dominant = bins.max(by: { $0.value < $1.value }),
              Double(dominant.value) / Double(max(1, total)) >= 0.92 else { return false }
        let color = [(dominant.key >> 10) * 8, ((dominant.key >> 5) & 31) * 8, (dominant.key & 31) * 8]
        var contrast = 0, interior = 0
        for y in pad..<(h - pad) { for x in pad..<(w - pad) {
            let i = (y * w + x) * 4
            if (0..<3).contains(where: { abs(Int(bytes[i + $0]) - color[$0]) >= 40 }) { contrast += 1 }
            interior += 1
        } }
        let fraction = Double(contrast) / Double(max(1, interior))
        return fraction >= 0.04 && fraction <= 0.5
    }

    public static func containsMost(of box: CGRect, in regions: [CGRect]) -> Bool {
        let area = box.width * box.height
        guard area > 0 else { return false }
        return regions.contains { region in
            let overlap = region.intersection(box)
            return !overlap.isNull && overlap.width * overlap.height / area >= 0.7
        }
    }
}
