import CoreGraphics
import Foundation
@testable import LocatorCore

/// Builds a deterministic sRGB RGBA8 `CGImage` by running `draw` against a fresh context.
/// The single source of synthetic image fixtures (CCL rectangles, NCC self-crops, pHash variants …).
func makeCGImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(ctx)
    return ctx.makeImage()!
}

/// A fully-populated descriptor (every optional set) for round-trip / store tests.
func sampleDescriptor(id: UUID = UUID(), version: Int = 1) -> Descriptor {
    Descriptor(
        id: id,
        version: version,
        created: Date(timeIntervalSince1970: 1_700_000_000),
        lastVerified: Date(timeIntervalSince1970: 1_700_000_500),
        app: AppContext(
            bundleID: "com.apple.TextEdit",
            windowTitlePattern: "^Untitled.*",
            windowSizeAtCapture: CGSize(width: 800, height: 600),
            backingScale: 2.0
        ),
        ax: AXDescriptor(
            available: true,
            path: [
                AXPathStep(role: "AXWindow", title: "Untitled", index: 0),
                AXPathStep(
                    role: "AXButton",
                    title: "Bold",
                    identifier: "bold",
                    descriptionText: "Bold",
                    index: 2,
                    siblingContext: SiblingContext(prevTitle: "Italic", nextTitle: "Underline")
                ),
            ],
            leafAttrs: AXLeafAttrs(role: "AXButton", title: "Bold", descriptionText: "Bold", enabled: true, actions: ["AXPress"])
        ),
        visual: VisualDescriptor(
            cropRef: CropStore.cropName(id: id),
            cropSize: CGSize(width: 24, height: 24),
            contextCropRef: CropStore.contextCropName(id: id),
            contextMarginPx: 60,
            edgeHash: "abc123",
            stateVariants: [StateVariant(name: "on", cropRef: CropStore.cropName(id: id, state: "on"), edgeHash: "def456")]
        ),
        text: TextDescriptor(
            selfText: "Bold",
            neighbors: [TextNeighbor(text: "Italic", offset: CGPoint(x: -30, y: 0), tolerancePx: 8)]
        ),
        geometry: GeometryDescriptor(
            windowRelative: CGPoint(x: 0.5, y: 0.1),
            sizePx: CGSize(width: 24, height: 24),
            anchor: Anchor(type: "window_origin", container: "toolbar", offsetPx: CGPoint(x: 12, y: 12)),
            scrollStateAtCapture: ["main": 0.0]
        ),
        appSpecific: ["element_kind": "format_button", "track_name": "Vox Lead"],
        thresholds: .defaults
    )
}

/// A unique temp directory for hermetic store tests; caller deletes in tearDown.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocatorTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
