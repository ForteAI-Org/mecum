import CoreGraphics
import Perception
import PerceptionCore
import Testing

@Suite("Scene composition audit regressions")
struct ScenePipelineAuditTests {
    private struct Sections: SectionDetecting {
        func sections(in image: CGImage, protecting text: [CGRect]) throws -> [CGRect] {
            #expect(text == [CGRect(x: 10, y: 10, width: 100, height: 20)])
            return [CGRect(x: 0, y: 0, width: 200, height: 600),
                    CGRect(x: 200, y: 0, width: 800, height: 600)]
        }
    }

    @Test("the section role receives OCR barriers and contributes named sections")
    func sectionRole() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 1000, height: 600,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let text = ScenePipelineTests.FixedText(runs: [
            RecognizedText(text: "Tracks", pixelBox: CGRect(x: 10, y: 10, width: 100, height: 20))
        ])
        let scene = try await ScenePipeline(text: text, sections: Sections()).perceive(image, of: window)
        #expect(scene.sections.count == 1)
        #expect(scene.elements.first?.section == "sidebar (Tracks)")
    }
    private let size = CGSize(width: 1000, height: 600)
    private let window = ScenePipeline.Window(bundleID: "test", appName: "Test", title: "Panel")

    @Test("zero and single-letter values survive without evidence that they are knobs")
    func retainsValues() {
        let runs = ["0", "O", "100"].enumerated().map { index, text in
            RecognizedText(text: text, pixelBox: CGRect(x: 20, y: 20 + index * 40, width: 20, height: 14))
        }
        let scene = ScenePipeline.assemble(runs: runs, segments: [], imageSize: size, window: window)
        #expect(scene.elements.map(\.label) == ["0", "O", "100"])
    }

    @Test("labels on opposite sides of a panel boundary cannot become one target")
    func crossPanelText() {
        var split = window
        split.sectionRects = [.init(x: 0, y: 0, width: 0.5, height: 1),
                              .init(x: 0.5, y: 0, width: 0.5, height: 1)]
        let scene = ScenePipeline.assemble(runs: [
            .init(text: "Cancel", pixelBox: CGRect(x: 450, y: 50, width: 45, height: 16)),
            .init(text: "Export", pixelBox: CGRect(x: 502, y: 50, width: 45, height: 16))
        ], segments: [], imageSize: size, window: split)
        #expect(scene.elements.map(\.label) == ["Cancel", "Export"])
        #expect(Set(scene.elements.compactMap(\.section)).count == 2)
    }

    @Test("adding panel context does not turn stacked control labels into prose")
    func stackedControls() {
        var split = window
        split.sectionRects = [.init(x: 0, y: 0, width: 1, height: 1)]
        let runs = ["Format", "Preset", "Location"].enumerated().map { index, text in
            RecognizedText(text: text, pixelBox: CGRect(x: 30, y: 40 + index * 24, width: 80, height: 16))
        }
        let scene = ScenePipeline.assemble(runs: runs, segments: [], imageSize: size, window: split)
        #expect(scene.elements.map(\.label) == ["Format", "Preset", "Location"])
    }
}
