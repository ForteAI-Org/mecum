import CoreGraphics

/// No-op segmenter. Ships first so the relocation cascade (stages 1/2/3a/3b) works end-to-end before
/// the real connected-component segmenter (M7) exists. Stage 4 is degraded (no candidates) until then.
public struct StubSegmenter: ElementSegmenter {
    public init() {}
    public func segment(in image: CGImage, region: CGRect?) -> [SegmentedElement] { [] }
}
