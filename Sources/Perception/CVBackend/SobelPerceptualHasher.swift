import CoreGraphics

/// Perceptual hash over the **Sobel edge map** (not raw color), which is what makes it state-invariant:
/// a button lighting up or inverting changes hue/brightness but not edge structure, so the hash barely
/// moves. Pipeline: grayscale → Sobel magnitude → downscale to 32×32 → 1 bit per cell (above/below the
/// map mean) → 1024 bits → 256 hex chars. The output format is a fixed contract (length never changes),
/// so the internal bit derivation could later switch to a DCT low-frequency sign without breaking stored
/// hashes' comparability by length.
public struct SobelPerceptualHasher: PerceptualHasher {
    public static let gridSize = 32   // 32×32 = 1024 bits = 256 hex chars

    public init() {}

    public func edgeHash(of image: CGImage) -> String {
        let edges = ImageOps.sobelMagnitude(ImageOps.grayscale(image))
        // Area-average (not bilinear) so thin edges aren't skipped between sample points — keeps the
        // hash stable across capture resolutions.
        let small = ImageOps.areaDownsample(edges, to: Self.gridSize, Self.gridSize)
        let n = small.pixels.count
        guard n > 0 else { return String(repeating: "0", count: Self.gridSize * Self.gridSize / 4) }

        let mean = small.pixels.reduce(0, +) / Float(n)

        // Pack bits MSB-first into nibbles → hex.
        var hex = ""
        hex.reserveCapacity(n / 4)
        var nibble = 0, count = 0
        for v in small.pixels {
            nibble = (nibble << 1) | (v > mean ? 1 : 0)
            count += 1
            if count == 4 {
                hex.append(Self.hexChars[nibble])
                nibble = 0; count = 0
            }
        }
        return hex
    }

    /// Hamming distance over equal-length hex strings. Unequal lengths → a large sentinel (incomparable).
    public func distance(_ a: String, _ b: String) -> Int {
        guard a.count == b.count else { return Int.max }
        var dist = 0
        for (ca, cb) in zip(a, b) {
            guard let va = ca.hexDigitValue, let vb = cb.hexDigitValue else { return Int.max }
            dist += (va ^ vb).nonzeroBitCount
        }
        return dist
    }

    private static let hexChars: [Character] = Array("0123456789abcdef")
}
