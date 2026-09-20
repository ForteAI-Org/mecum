import CoreGraphics
import Foundation
import ImageIO
import Perception
import PerceptionCore
import Testing
import VisionText

/// DropdownCaptureTests reads saved pixels with the real recognizer; no live app or grants needed.
@Suite("Dropdown capture regression")
struct DropdownCaptureTests {
    @Test("the New Paths format reads Mono without the neighbouring new caption")
    func monoControl() async throws {
        let file = try #require(Bundle.module.url(forResource: "NewPathsMono", withExtension: "png"))
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scene = try await ScenePipeline(text: VisionTextRecognizer()).perceive(
            image,
            inside: NormalizedRect(x: 141.0 / 514, y: 47.0 / 164, width: 91.0 / 514, height: 17.0 / 164),
            of: ScenePipeline.Window(bundleID: "com.avid.ProTools", appName: "Pro Tools", title: "New Paths")
        )
        let captured = try #require(scene)
        guard case .found(let value) = captured.resolve(target: "Mono") else {
            Issue.record("Mono was lost or combined with its neighbour: \(captured.elements.map(\.label))")
            return
        }
        #expect(LabelText.normalize(value.label) == "mono")
        #expect(!captured.elements.contains { LabelText.tokens($0.label).contains("new") })
    }
}
