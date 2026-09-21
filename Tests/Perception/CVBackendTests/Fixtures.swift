import CoreGraphics

/// Build a deterministic sRGB RGBA8 image from a draw closure.
func makeCGImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

/// Gray rectangles on a gray background (values 0…1). Rects are authored in **top-left** pixel coords
/// (the context is flipped) so they land where the matcher — which indexes the CGImage top-left —
/// expects them.
func patternImage(width: Int, height: Int, bg: CGFloat, rects: [(CGRect, CGFloat)]) -> CGImage {
    makeCGImage(width: width, height: height) { ctx in
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(gray: bg, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, g) in rects {
            ctx.setFillColor(gray: g, alpha: 1)
            ctx.fill(r)
        }
    }
}

/// High-frequency checkerboard — structured content unlikely to correlate with blocky UI.
func checkerboard(width: Int, height: Int, cell: Int) -> CGImage {
    makeCGImage(width: width, height: height) { ctx in
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0, alpha: 1)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if ((x / cell) + (y / cell)) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)) }
                x += cell
            }
            y += cell
        }
    }
}
