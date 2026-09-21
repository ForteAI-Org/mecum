import CoreGraphics

/// A normalized-cross-correlation match. `score` is in [-1, 1]; `locationPx` is the match's top-left.
public struct NCCMatch: Sendable, Equatable {
    public var locationPx: CGPoint
    public var score: Double

    public init(locationPx: CGPoint, score: Double) {
        self.locationPx = locationPx
        self.score = score
    }
}

/// Spatial normalized cross-correlation, optionally multi-scale and region-limited.
public protocol TemplateMatcher: Sendable {
    func match(template: CGImage, in image: CGImage, searchRegion: CGRect?, scales: [CGFloat]) -> NCCMatch?
}

/// State-invariant perceptual hash over an edge map (a lit/unlit button changes hue, not structure).
public protocol PerceptualHasher: Sendable {
    func edgeHash(of image: CGImage) -> String      // hex string
    func distance(_ a: String, _ b: String) -> Int  // Hamming
}
