import CoreGraphics
import Perception
import PerceptionCore
import Testing

@Suite("Visual region composition")
struct ScenePipelineVisualRegionsTests {
    private struct Media: VisualRegionFiltering {
        func filter(_ segments: [CGRect], in image: CGImage, protecting text: [CGRect]) throws -> VisualRegions {
            #expect(segments == [CGRect(x: 80, y: 80, width: 20, height: 20)])
            #expect(text == [CGRect(x: 102, y: 80, width: 65, height: 18)])
            return VisualRegions(
                icons: [],
                images: [CGRect(x: 20, y: 20, width: 300, height: 200)],
                overlays: segments
            )
        }
    }

    @Test("photo overlays remain unnamed instead of borrowing text printed in the image")
    func overlaysAreNotCaptionControls() async throws {
        let context = try #require(CGContext(
            data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let pipeline = ScenePipeline(
            text: ScenePipelineTests.FixedText(runs: [
                .init(text: "Camera", pixelBox: CGRect(x: 102, y: 80, width: 65, height: 18))
            ]),
            regions: ScenePipelineTests.FixedRegions(boxes: [CGRect(x: 80, y: 80, width: 20, height: 20)]),
            regionFilter: Media()
        )
        let scene = try await pipeline.perceive(
            image,
            of: .init(bundleID: "test.media", appName: "Media", title: "")
        )
        let overlay = try #require(scene.elements.first { $0.kind == .overlayCandidate })
        #expect(overlay.isUnlabeled)
        #expect(overlay.state == nil)
        #expect(overlay.role == nil)
        #expect(overlay.isEnabled == nil)
        #expect(scene.elements.contains { $0.kind == .image })
        #expect(scene.elements.contains { $0.kind == .text && $0.label == "Camera" })
        #expect(!scene.elements.contains { $0.kind == .control })
    }
}
