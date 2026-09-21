import CoreGraphics
import Accelerate

/// A grayscale image as row-major `Float` luminance (0…255). Produced by normalizing any `CGImage`
/// through a known sRGB RGBA8 context first — feeding raw screen-capture bytes to pixel math is the
/// classic garbage/crash source, so we always redraw into a known format.
///
/// Hot kernels run on Accelerate (vDSP for the Float planes, vImage for binary morphology); every
/// vImage call checks its return code and falls back to the plain-Swift reference implementation, so
/// a refused flag can never silently change the output. Measured 2026-09-06 on a 700² peek tile: the
/// scalar segmenter stack (grayscale → Sobel → dilate → label) was ~40% of the whole perception pass.
public struct GrayImage {
    public let width: Int
    public let height: Int
    public var pixels: [Float]   // length width*height

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { pixels[y * width + x] }
}

public enum ImageOps {
    /// The ONE normalization step: draw any `CGImage` into an sRGB premultiplied RGBA8 buffer of the
    /// requested size. nil only when CoreGraphics refuses the context.
    public static func renderRGBA(_ image: CGImage, width w: Int, height h: Int, highQuality: Bool = false) -> [UInt8]? {
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if highQuality { ctx.interpolationQuality = .high }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? rgba : nil
    }

    /// Normalize a `CGImage` to grayscale `Float` luminance via a fresh sRGB premultiplied-RGBA8 context.
    public static func grayscale(_ image: CGImage) -> GrayImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let rgba = renderRGBA(image, width: w, height: h) else {
            return GrayImage(width: 0, height: 0, pixels: [])
        }
        let n = w * h, len = vDSP_Length(n)
        // (0.299·r + 0.587·g) + 0.114·b with one rounding per operation — the scalar reference's exact
        // association, and no fused multiply-add (vDSP_vsma may fuse), so the luminance is bit-identical.
        var px = [Float](repeating: 0, count: n), tmp = px
        rgba.withUnsafeBufferPointer { src in
            var k: Float = 0.299
            vDSP_vfltu8(src.baseAddress!, 4, &px, 1, len)
            vDSP_vsmul(px, 1, &k, &px, 1, len)
            k = 0.587
            vDSP_vfltu8(src.baseAddress! + 1, 4, &tmp, 1, len)
            vDSP_vsmul(tmp, 1, &k, &tmp, 1, len)
            vDSP_vadd(px, 1, tmp, 1, &px, 1, len)
            k = 0.114
            vDSP_vfltu8(src.baseAddress! + 2, 4, &tmp, 1, len)
            vDSP_vsmul(tmp, 1, &k, &tmp, 1, len)
            vDSP_vadd(px, 1, tmp, 1, &px, 1, len)
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    /// Bilinear resize.
    static func resize(_ src: GrayImage, to newW: Int, _ newH: Int) -> GrayImage {
        guard src.width > 0, src.height > 0, newW > 0, newH > 0 else {
            return GrayImage(width: max(newW, 0), height: max(newH, 0),
                             pixels: [Float](repeating: 0, count: max(newW, 0) * max(newH, 0)))
        }
        if newW == src.width && newH == src.height { return src }
        var out = [Float](repeating: 0, count: newW * newH)
        let sx = Float(src.width) / Float(newW)
        let sy = Float(src.height) / Float(newH)
        for y in 0..<newH {
            let fy = (Float(y) + 0.5) * sy - 0.5
            let y0 = max(0, min(src.height - 1, Int(fy.rounded(.down))))
            let y1 = min(src.height - 1, y0 + 1)
            let wy = max(0, min(1, fy - Float(y0)))   // clamp so edges interpolate, never extrapolate
            for x in 0..<newW {
                let fx = (Float(x) + 0.5) * sx - 0.5
                let x0 = max(0, min(src.width - 1, Int(fx.rounded(.down))))
                let x1 = min(src.width - 1, x0 + 1)
                let wx = max(0, min(1, fx - Float(x0)))
                let top = src.at(x0, y0) * (1 - wx) + src.at(x1, y0) * wx
                let bot = src.at(x0, y1) * (1 - wx) + src.at(x1, y1) * wx
                out[y * newW + x] = top * (1 - wy) + bot * wy
            }
        }
        return GrayImage(width: newW, height: newH, pixels: out)
    }

    /// Area-averaging downsample (box filter). Unlike bilinear, this averages EVERY source pixel in a
    /// cell's footprint, so thin features (Sobel edges are 1px-bright lines) aren't skipped between
    /// sample points — important for a resolution-stable perceptual hash. Falls back to bilinear if
    /// the target isn't strictly smaller.
    public static func areaDownsample(_ src: GrayImage, to newW: Int, _ newH: Int) -> GrayImage {
        guard newW > 0, newH > 0, src.width >= newW, src.height >= newH else { return resize(src, to: newW, newH) }
        var out = [Float](repeating: 0, count: newW * newH)
        for oy in 0..<newH {
            let y0 = oy * src.height / newH
            let y1 = max(y0 + 1, (oy + 1) * src.height / newH)
            for ox in 0..<newW {
                let x0 = ox * src.width / newW
                let x1 = max(x0 + 1, (ox + 1) * src.width / newW)
                var sum: Float = 0
                var count = 0
                for yy in y0..<min(y1, src.height) {
                    let rowBase = yy * src.width
                    for xx in x0..<min(x1, src.width) { sum += src.pixels[rowBase + xx]; count += 1 }
                }
                out[oy * newW + ox] = count > 0 ? sum / Float(count) : 0
            }
        }
        return GrayImage(width: newW, height: newH, pixels: out)
    }

    /// Sobel gradient magnitude map (same dimensions; the one-pixel border is zero, as in the reference).
    static func sobelMagnitude(_ g: GrayImage) -> GrayImage {
        let w = g.width, h = g.height, n = w * h
        guard w >= 3, h >= 3 else { return GrayImage(width: w, height: h, pixels: [Float](repeating: 0, count: n)) }
        var gx = [Float](repeating: 0, count: n), gy = gx
        sobelComponents(g.pixels, w: w, h: h, gx: &gx, gy: &gy)
        let len = vDSP_Length(n)
        vDSP_vsq(gx, 1, &gx, 1, len)
        vDSP_vsq(gy, 1, &gy, 1, len)
        vDSP_vadd(gx, 1, gy, 1, &gx, 1, len)
        for i in 0..<n { gx[i] = gx[i].squareRoot() }   // the reference's sqrt; vdist/vvsqrtf can differ by an ulp
        zeroBorder(&gx, w: w, h: h)
        return GrayImage(width: w, height: h, pixels: gx)
    }

    /// The two Sobel components, computed as whole-plane shifted adds in EXACTLY the scalar reference's
    /// association — gx = ((tr + 2r) + br) − ((tl + 2l) + bl), gy = ((bl + 2b) + br) − ((tl + 2t) + tr) —
    /// so every interior value is bit-identical to the old per-pixel loop (a 3×3 convolution routine
    /// sums in its own order and flips threshold pixels). Only interior pixels are written; the one-pixel
    /// border is undefined here and zeroed by the callers.
    private static func sobelComponents(_ src: [Float], w: Int, h: Int, gx: inout [Float], gy: inout [Float]) {
        let n = w * h, inner = vDSP_Length(n - 2 * w - 2)   // interior span, offsets ±1 / ±w around it
        var two: Float = 2
        var a = [Float](repeating: 0, count: n), b = a
        src.withUnsafeBufferPointer { s in
            let p = s.baseAddress! + (w + 1)   // first interior pixel
            a.withUnsafeMutableBufferPointer { ab in gx.withUnsafeMutableBufferPointer { gxb in
            b.withUnsafeMutableBufferPointer { bb in gy.withUnsafeMutableBufferPointer { gyb in
                let A = ab.baseAddress! + (w + 1), B = bb.baseAddress! + (w + 1)
                let GX = gxb.baseAddress! + (w + 1), GY = gyb.baseAddress! + (w + 1)
                // gx: A = (tr + 2r) + br ; B = (tl + 2l) + bl
                vDSP_vsma(p + 1, 1, &two, p - w + 1, 1, A, 1, inner)        // 2r + tr
                vDSP_vadd(A, 1, p + w + 1, 1, A, 1, inner)                  // + br
                vDSP_vsma(p - 1, 1, &two, p - w - 1, 1, B, 1, inner)        // 2l + tl
                vDSP_vadd(B, 1, p + w - 1, 1, B, 1, inner)                  // + bl
                vDSP_vsub(B, 1, A, 1, GX, 1, inner)                         // A − B
                // gy: A = (bl + 2b) + br ; B = (tl + 2t) + tr
                vDSP_vsma(p + w, 1, &two, p + w - 1, 1, A, 1, inner)        // 2b + bl
                vDSP_vadd(A, 1, p + w + 1, 1, A, 1, inner)                  // + br
                vDSP_vsma(p - w, 1, &two, p - w - 1, 1, B, 1, inner)        // 2t + tl
                vDSP_vadd(B, 1, p - w + 1, 1, B, 1, inner)                  // + tr
                vDSP_vsub(B, 1, A, 1, GY, 1, inner)
            } } } }
        }
    }

    private static func zeroBorder(_ p: inout [Float], w: Int, h: Int) {
        guard w > 0, h > 0 else { return }
        for x in 0..<w { p[x] = 0; p[(h - 1) * w + x] = 0 }
        for y in 0..<h { p[y * w] = 0; p[y * w + w - 1] = 0 }
    }
}

// MARK: - Scalar references (tests prove the Accelerate kernels match them bit for bit)
extension ImageOps {
    static func referenceGrayscale(_ image: CGImage) -> GrayImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let rgba = renderRGBA(image, width: w, height: h) else { return GrayImage(width: 0, height: 0, pixels: []) }
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            px[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    static func referenceSobelMagnitude(_ g: GrayImage) -> GrayImage {
        let w = g.width, h = g.height
        guard w >= 3, h >= 3 else { return GrayImage(width: w, height: h, pixels: [Float](repeating: 0, count: w * h)) }
        var out = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let tl = g.at(x - 1, y - 1), t = g.at(x, y - 1), tr = g.at(x + 1, y - 1)
                let l = g.at(x - 1, y), r = g.at(x + 1, y)
                let bl = g.at(x - 1, y + 1), b = g.at(x, y + 1), br = g.at(x + 1, y + 1)
                let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                out[y * w + x] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}
