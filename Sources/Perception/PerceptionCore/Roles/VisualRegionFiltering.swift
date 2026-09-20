import CoreGraphics

/// VisualRegionFiltering separates ordinary icon candidates from media after OCR is available.
/// Returned rectangles use the input image's top-left pixel space. Implementations read only
/// current pixels and text bounds, retain no image, and throw when analysis cannot complete.
public protocol VisualRegionFiltering: Sendable {
    func filter(_ segments: [CGRect], in image: CGImage, protecting text: [CGRect]) throws -> VisualRegions
}

/// VisualRegions keeps photo interiors and uncertain backed overlays out of icon-caption pairing.
/// None of these rectangles establish a semantic name, interactivity, availability, or state.
public struct VisualRegions: Sendable {
    public var icons: [CGRect]
    public var images: [CGRect]
    public var overlays: [CGRect]

    public init(icons: [CGRect], images: [CGRect] = [], overlays: [CGRect] = []) {
        self.icons = icons
        self.images = images
        self.overlays = overlays
    }
}
