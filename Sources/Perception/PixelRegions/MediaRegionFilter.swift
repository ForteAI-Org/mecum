import CoreGraphics
import PerceptionCore

/// MediaRegionFilter separates visual candidates from photographic content using current pixels.
///
/// It borrows the image only during the call and stores no state. OCR rectangles protect text-heavy
/// UI from suppression; OCR itself is not removed. Candidates inside photographs are discarded
/// unless compact geometry and a flat backing support retaining an uncertain overlay. Callers must
/// keep those overlays unnamed and stateless unless independent evidence supplies their semantics.
/// This adapter requires only local pixel processing, without models, memory, capture, or app access.
nonisolated public struct MediaRegionFilter: VisualRegionFiltering {

    /// Failure describes an incomplete pixel read. No partial regions are returned after failure.
    public enum Failure: Error {
        case imageRenderingFailed
    }

    /// Creates an independent, stateless filter.
    public init() {}

    /// Filters image-local pixel rectangles, preserving candidates outside detected media.
    /// Checks cancellation between analysis and candidate validation. A synchronous kernel already
    /// executing finishes before cancellation can be observed.
    public func filter(
        _ segments: [CGRect],
        in image: CGImage,
        protecting text: [CGRect]
    ) throws -> VisualRegions {
        try Task.checkCancellation()
        let analysis = try ImageSurfaceDetector.analyze(in: image)
        let images = ImageSurfaceDetector.finish(analysis, textBoxes: text)
        var icons: [CGRect] = []
        var overlays: [CGRect] = []

        for segment in segments {
            try Task.checkCancellation()
            if !ImageSurfaceDetector.containsMost(of: segment, in: images) {
                icons.append(segment)
            } else if try ImageSurfaceDetector.hasControlBacking(segment, in: image, regions: images) {
                overlays.append(segment)
            }
        }
        try Task.checkCancellation()
        return VisualRegions(icons: icons, images: images, overlays: overlays)
    }
}
