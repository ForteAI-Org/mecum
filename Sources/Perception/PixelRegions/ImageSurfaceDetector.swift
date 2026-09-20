import Accelerate
import CoreGraphics

/// ImageSurfaceDetector proposes photographic surfaces using local texture and palette diversity.
/// It is independent from capture, accessibility, storage, and application identity. Analysis is
/// bounded to a 1200-pixel maximum dimension; outputs use the original image's pixel coordinates.
/// These are geometric hypotheses, not semantic image recognition. Flat illustrations and
/// text-heavy media can remain undetected. Morphology uses a scalar fallback if Accelerate refuses it.
nonisolated enum ImageSurfaceDetector {
    struct Analysis: Sendable {
        let width: Int, height: Int
        let scaleX: Double, scaleY: Double
        let rgba: [UInt8]
        let backgroundKeys: [Int]
        let candidates: [CGRect]
        static let empty = Analysis(
            width: 0, height: 0, scaleX: 1, scaleY: 1, rgba: [], backgroundKeys: [], candidates: [])
    }

    /// Analyzes pixels independently of OCR. Throws if CoreGraphics cannot normalize the image.
    static func analyze(in image: CGImage) throws -> Analysis {
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard width >= 40, height >= 40 else { return .empty }
        guard let rgba = ImageOps.renderRGBA(image, width: width, height: height, highQuality: true) else {
            throw MediaRegionFilter.Failure.imageRenderingFailed
        }
        let pixelCount = width * height
        @inline(__always) func key(_ i: Int) -> Int {
            Int(rgba[i * 4]) << 16 | Int(rgba[i * 4 + 1]) << 8 | Int(rgba[i * 4 + 2])
        }
        let backgroundKeys = dominantColors(rgba, count: pixelCount, minCount: pixelCount / 1000, limit: 32)
        var background = [UInt64](repeating: 0, count: 1 << 18)
        for k in backgroundKeys { background[k >> 6] |= 1 << UInt64(k & 63) }
        @inline(__always) func isBackground(_ k: Int) -> Bool {
            background[k >> 6] & (1 << UInt64(k & 63)) != 0
        }
        var mask = [UInt8](repeating: 0, count: pixelCount)
        if let planes = channelPlanes(rgba, width: width, height: height),
            let rMax = ImageOps.boxMorphology8(
                planes.r, width: width, height: height, kernel: 3, dilate: true),
            let rMin = ImageOps.boxMorphology8(
                planes.r, width: width, height: height, kernel: 3, dilate: false),
            let gMax = ImageOps.boxMorphology8(
                planes.g, width: width, height: height, kernel: 3, dilate: true),
            let gMin = ImageOps.boxMorphology8(
                planes.g, width: width, height: height, kernel: 3, dilate: false),
            let bMax = ImageOps.boxMorphology8(
                planes.b, width: width, height: height, kernel: 3, dilate: true),
            let bMin = ImageOps.boxMorphology8(
                planes.b, width: width, height: height, kernel: 3, dilate: false)
        {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    guard !isBackground(key(i)) else { continue }
                    if Int(rMax[i]) - Int(rMin[i]) > 2 || Int(gMax[i]) - Int(gMin[i]) > 2
                        || Int(bMax[i]) - Int(bMin[i]) > 2
                    {
                        mask[i] = 1
                    }
                }
            }
        } else {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    guard !isBackground(key(i)) else { continue }
                    var varied = false
                    for channel in 0..<3 {
                        var lower: UInt8 = 255
                        var upper: UInt8 = 0
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let v = rgba[((y + dy) * width + x + dx) * 4 + channel]
                                lower = min(lower, v)
                                upper = max(upper, v)
                            }
                        }
                        if Int(upper) - Int(lower) > 2 {
                            varied = true
                            break
                        }
                    }
                    mask[i] = varied ? 1 : 0
                }
            }
        }
        mask = opening3x3(mask, width: width, height: height)
        var seen = [Bool](repeating: false, count: pixelCount)
        var stack: [Int] = []
        var candidates: [CGRect] = []
        let scaleX = Double(image.width) / Double(width)
        let scaleY = Double(image.height) / Double(height)
        for seed in 0..<pixelCount where mask[seed] != 0 && !seen[seed] {
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            seen[seed] = true
            var x0 = seed % width
            var x1 = x0
            var y0 = seed / width
            var y1 = y0
            var count = 0
            while let i = stack.popLast() {
                let x = i % width
                let y = i / width
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
                count += 1
                if x > 0, mask[i - 1] != 0, !seen[i - 1] {
                    seen[i - 1] = true
                    stack.append(i - 1)
                }
                if x + 1 < width, mask[i + 1] != 0, !seen[i + 1] {
                    seen[i + 1] = true
                    stack.append(i + 1)
                }
                if y > 0, mask[i - width] != 0, !seen[i - width] {
                    seen[i - width] = true
                    stack.append(i - width)
                }
                if y + 1 < height, mask[i + width] != 0, !seen[i + width] {
                    seen[i + width] = true
                    stack.append(i + width)
                }
            }
            let boxWidth = x1 - x0 + 1
            let boxHeight = y1 - y0 + 1
            let area = boxWidth * boxHeight
            guard min(boxWidth, boxHeight) >= 40, area >= 2500,
                Double(count) / Double(area) >= 0.4,
                Double(boxWidth) / Double(boxHeight) >= 0.2, Double(boxWidth) / Double(boxHeight) <= 5
            else { continue }
            var bins = [Int](repeating: 0, count: 4096)
            var occupied = 0
            var dominant = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    let i = (y * width + x) * 4
                    let b = Int(rgba[i] >> 4) << 8 | Int(rgba[i + 1] >> 4) << 4 | Int(rgba[i + 2] >> 4)
                    if bins[b] == 0 { occupied += 1 }
                    bins[b] += 1
                    dominant = max(dominant, bins[b])
                }
            }
            guard occupied >= 40, Double(dominant) / Double(area) <= 0.6 else { continue }
            candidates.append(
                CGRect(
                    x: Double(x0) * scaleX, y: Double(y0) * scaleY, width: Double(boxWidth) * scaleX,
                    height: Double(boxHeight) * scaleY))
        }
        return Analysis(
            width: width, height: height, scaleX: scaleX, scaleY: scaleY, rgba: rgba,
            backgroundKeys: backgroundKeys, candidates: candidates)
    }

    /// Protects text-heavy surfaces and separates adjacent thumbnails along flat palette gutters.
    static func finish(_ a: Analysis, textBoxes: [CGRect]) -> [CGRect] {
        guard a.width > 0, a.height > 0 else { return [] }
        let width = a.width
        let height = a.height
        let scaleX = a.scaleX
        let scaleY = a.scaleY
        let rgba = a.rgba
        let proposals = a.candidates.filter { r in
            let textArea = textBoxes.reduce(0.0) { sum, text in
                let overlap = r.intersection(text)
                return sum + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            return textArea / (r.width * r.height) < 0.15
        }
        guard !proposals.isEmpty else { return [] }
        func gutterKey(_ rgb: Int) -> Int { (rgb >> 19) << 10 | ((rgb >> 11) & 31) << 5 | ((rgb >> 3) & 31) }
        var gutterLUT = [Bool](repeating: false, count: 1 << 15)
        for k in a.backgroundKeys { gutterLUT[gutterKey(k)] = true }
        @inline(__always) func isGutter(_ i: Int) -> Bool {
            gutterLUT[
                Int(rgba[i * 4] >> 3) << 10 | Int(rgba[i * 4 + 1] >> 3) << 5 | Int(rgba[i * 4 + 2] >> 3)]
        }
        func splitAtGutters(_ r: CGRect, depth: Int) -> [CGRect] {
            guard depth < 6 else { return [r] }
            let x0 = max(0, Int((r.minX / scaleX).rounded()))
            let x1 = min(width, Int((r.maxX / scaleX).rounded()))
            let y0 = max(0, Int((r.minY / scaleY).rounded()))
            let y1 = min(height, Int((r.maxY / scaleY).rounded()))
            for vertical in [true, false] {
                let lower = vertical ? x0 : y0
                let upper = vertical ? x1 : y1
                let crossLo = vertical ? y0 : x0
                let crossHi = vertical ? y1 : x1
                guard upper - lower > 82, crossHi > crossLo else { continue }
                var start: Int?
                for pos in (lower + 40)..<(upper - 39) {
                    var flat = 0
                    for cross in crossLo..<crossHi {
                        let i = vertical ? cross * width + pos : pos * width + cross
                        if isGutter(i) { flat += 1 }
                    }
                    let gutter = Double(flat) / Double(crossHi - crossLo) >= 0.92
                    if gutter {
                        if start == nil { start = pos }
                    } else if let a = start {
                        if pos - a >= 2 {
                            let first =
                                vertical
                                ? CGRect(
                                    x: r.minX, y: r.minY, width: Double(a) * scaleX - r.minX, height: r.height
                                )
                                : CGRect(
                                    x: r.minX, y: r.minY, width: r.width, height: Double(a) * scaleY - r.minY)
                            let second =
                                vertical
                                ? CGRect(
                                    x: Double(pos) * scaleX, y: r.minY, width: r.maxX - Double(pos) * scaleX,
                                    height: r.height)
                                : CGRect(
                                    x: r.minX, y: Double(pos) * scaleY, width: r.width,
                                    height: r.maxY - Double(pos) * scaleY)
                            return splitAtGutters(first, depth: depth + 1)
                                + splitAtGutters(second, depth: depth + 1)
                        }
                        start = nil
                    }
                }
            }
            return [r]
        }
        return consolidate(proposals).flatMap { splitAtGutters($0, depth: 0) }
    }
    /// Counts exact RGB colors with radix sorting; frequency ties use the smaller color key.
    private static func dominantColors(_ rgba: [UInt8], count pixelCount: Int, minCount: Int, limit: Int)
        -> [Int]
    {
        guard pixelCount > 0 else { return [] }
        var keys = [UInt32](repeating: 0, count: pixelCount)
        var scratch = keys
        for i in 0..<pixelCount {
            keys[i] = UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2])
        }
        var counts = [Int](repeating: 0, count: 256)
        for shift in stride(from: 0, to: 24, by: 8) {
            for c in counts.indices { counts[c] = 0 }
            for k in keys { counts[Int((k >> UInt32(shift)) & 255)] += 1 }
            var offset = 0
            for c in counts.indices {
                let count = counts[c]
                counts[c] = offset
                offset += count
            }
            for k in keys {
                let b = Int((k >> UInt32(shift)) & 255)
                scratch[counts[b]] = k
                counts[b] += 1
            }
            swap(&keys, &scratch)
        }
        var found: [(key: Int, count: Int)] = []
        var i = 0
        while i < pixelCount {
            var j = i + 1
            while j < pixelCount, keys[j] == keys[i] { j += 1 }
            if j - i > minCount { found.append((Int(keys[i]), j - i)) }
            i = j
        }
        return found.sorted { $0.count > $1.count || ($0.count == $1.count && $0.key < $1.key) }.prefix(limit)
            .map(\.key)
    }
    private static func channelPlanes(_ rgba: [UInt8], width: Int, height: Int) -> (
        r: [UInt8], g: [UInt8], b: [UInt8]
    )? {
        var src = rgba
        var r = [UInt8](repeating: 0, count: width * height)
        var g = r
        var b = r
        var a = r
        let error: vImage_Error = src.withUnsafeMutableBufferPointer { s in
            r.withUnsafeMutableBufferPointer { rp in
                g.withUnsafeMutableBufferPointer { gp in
                    b.withUnsafeMutableBufferPointer { bp in
                        a.withUnsafeMutableBufferPointer { ap in
                            var sb = vImage_Buffer(
                                data: s.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width * 4)
                            var rb = vImage_Buffer(
                                data: rp.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width)
                            var gb = vImage_Buffer(
                                data: gp.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width)
                            var bb = vImage_Buffer(
                                data: bp.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width)
                            var ab = vImage_Buffer(
                                data: ap.baseAddress, height: vImagePixelCount(height),
                                width: vImagePixelCount(width), rowBytes: width)
                            return vImageConvert_ARGB8888toPlanar8(
                                &sb, &rb, &gb, &bb, &ab, vImage_Flags(kvImageNoFlags))
                        }
                    }
                }
            }
        }
        return error == kvImageNoError ? (r, g, b) : nil
    }
    private static func opening3x3(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        if var eroded = ImageOps.boxMorphology8(mask, width: width, height: height, kernel: 3, dilate: false)
        {
            for x in 0..<width {
                eroded[x] = 0
                eroded[(height - 1) * width + x] = 0
            }
            for y in 0..<height {
                eroded[y * width] = 0
                eroded[y * width + width - 1] = 0
            }
            if let dilated = ImageOps.boxMorphology8(
                eroded, width: width, height: height, kernel: 3, dilate: true)
            {
                return dilated
            }
        }
        var eroded = [UInt8](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where mask[y * width + x] != 0 {
                eroded[y * width + x] =
                    (-1...1).allSatisfy { dy in
                        (-1...1).allSatisfy { dx in mask[(y + dy) * width + x + dx] != 0 }
                    } ? 1 : 0
            }
        }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where eroded[y * width + x] != 0 {
                for dy in -1...1 { for dx in -1...1 { out[(y + dy) * width + x + dx] = 1 } }
            }
        }
        return out
    }
    private static func consolidate(_ proposals: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for proposal in proposals.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            var merged = proposal
            var changed = true
            while changed {
                changed = false
                for i in result.indices.reversed() {
                    let other = result[i]
                    let overlap = other.intersection(merged)
                    guard !overlap.isNull,
                        overlap.width * overlap.height >= 0.15
                            * min(other.width * other.height, merged.width * merged.height)
                    else { continue }
                    merged = merged.union(other)
                    result.remove(at: i)
                    changed = true
                }
            }
            result.append(merged)
        }
        return result.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }
    /// Keeps compact, contrasted glyphs on nearly uniform backing as uncertain media overlays.
    /// A positive result is not proof of actionability; it must not create a name or toggle state.
    static func hasControlBacking(_ box: CGRect, in image: CGImage, regions: [CGRect]) throws -> Bool {
        guard box.width >= 9, box.height >= 9, box.width / box.height >= 0.4,
            box.width / box.height <= 2.5,
            let region = regions.first(where: { containsMost(of: box, in: [$0]) }),
            max(box.width, box.height) <= min(region.width, region.height) * 0.25
        else { return false }
        let pad = max(4, Int(min(box.width, box.height) * 0.35))
        let rect = box.integral.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad))
        guard rect.minX >= 0, rect.minY >= 0,
            rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height)
        else { return false }
        guard let crop = image.cropping(to: rect) else {
            throw MediaRegionFilter.Failure.imageRenderingFailed
        }
        let width = crop.width
        let height = crop.height
        guard width <= 180, height <= 180 else { return false }
        guard let bytes = ImageOps.renderRGBA(crop, width: width, height: height) else {
            throw MediaRegionFilter.Failure.imageRenderingFailed
        }
        var bins = [Int: Int]()
        var total = 0
        for y in 0..<height {
            for x in 0..<width where x < pad || y < pad || x >= width - pad || y >= height - pad {
                let i = (y * width + x) * 4
                let key = Int(bytes[i] >> 3) << 10 | Int(bytes[i + 1] >> 3) << 5 | Int(bytes[i + 2] >> 3)
                bins[key, default: 0] += 1
                total += 1
            }
        }
        guard let dominant = bins.max(by: { $0.value < $1.value }),
            Double(dominant.value) / Double(max(1, total)) >= 0.92
        else { return false }
        let color = [(dominant.key >> 10) * 8, ((dominant.key >> 5) & 31) * 8, (dominant.key & 31) * 8]
        var contrast = 0
        var interior = 0
        for y in pad..<(height - pad) {
            for x in pad..<(width - pad) {
                let i = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(bytes[i + $0]) - color[$0]) >= 40 }) { contrast += 1 }
                interior += 1
            }
        }
        let fraction = Double(contrast) / Double(max(1, interior))
        return fraction >= 0.04 && fraction <= 0.5
    }

    static func containsMost(of box: CGRect, in regions: [CGRect]) -> Bool {
        let area = box.width * box.height
        guard area > 0 else { return false }
        return regions.contains { region in
            let overlap = region.intersection(box)
            return !overlap.isNull && overlap.width * overlap.height / area >= 0.7
        }
    }
}
