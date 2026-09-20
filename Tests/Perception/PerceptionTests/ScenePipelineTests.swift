//
//  ScenePipelineTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import Perception
import PerceptionCore
import Testing

/// The pipeline is driven through doubles that honor the roles' contracts: a recognizer that
/// answers fixed runs or throws, a segmenter that answers fixed boxes. No image is read, which is
/// the point: the composition is proven here, the frameworks are proven at their own boundary.
@Suite("Scene pipeline")
struct ScenePipelineTests {

    struct FixedText: TextRecognizing {
        var runs: [RecognizedText]
        var failure: (any Error)?

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            if let failure { throw failure }
            return runs
        }
    }

    struct FixedRegions: RegionSegmenting {
        var boxes: [CGRect]

        func segments(in image: CGImage) throws -> [CGRect] { boxes }
    }

    struct Unavailable: Error, Equatable {}

    struct FixedAugmentation: SceneAugmenting {
        var elements: [SceneElement]
        var seen: Recorder

        final class Recorder: @unchecked Sendable {
            var calls: [(pid_t, CGRect)] = []
        }

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> [SceneElement] {
            seen.calls.append((processID, windowFrame))
            return elements
        }
    }

    private func blank(_ width: Int, _ height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private let window = ScenePipeline.Window(bundleID: "com.x", appName: "X", title: "Export")

    @Test("text runs and an adjacent segment become one control with a normalized position")
    func iconAndCaptionBecomeAControl() async throws {
        let text = FixedText(runs: [RecognizedText(text: "Export", pixelBox: CGRect(x: 30, y: 101, width: 52, height: 16))])
        let regions = FixedRegions(boxes: [CGRect(x: 8, y: 100, width: 18, height: 18)])
        let scene = try await ScenePipeline(text: text, regions: regions).perceive(try blank(1000, 500), of: window)
        #expect(scene.elements.count == 1)
        let element = try #require(scene.elements.first)
        #expect(element.kind == .control)
        #expect(element.label == "Export")
        #expect(element.id == "control|export")
        #expect(element.bounds == NormalizedRect(x: 0.008, y: 0.2, width: 0.074, height: 0.036))
        #expect(scene.viewportPixelSize == ViewportPixelSize(width: 1000, height: 500))
    }

    @Test("blank runs are dropped; a single letter is retained without contrary visual evidence")
    func filtersAndUnlabeled() async throws {
        let text = FixedText(runs: [RecognizedText(text: "O", pixelBox: CGRect(x: 10, y: 10, width: 8, height: 8)),
                                    RecognizedText(text: "  ", pixelBox: CGRect(x: 40, y: 10, width: 8, height: 8)),
                                    RecognizedText(text: "Mute", pixelBox: CGRect(x: 100, y: 300, width: 40, height: 14))])
        let regions = FixedRegions(boxes: [CGRect(x: 500, y: 300, width: 24, height: 24)])
        let scene = try await ScenePipeline(text: text, regions: regions).perceive(try blank(1000, 500), of: window)
        #expect(scene.elements.map(\.kind) == [.text, .text, .icon])
        let icon = try #require(scene.elements.last)
        #expect(icon.isUnlabeled)
        #expect(icon.label == "(unlabeled)")
        #expect(icon.id.hasPrefix("?|@"))
    }

    @Test("a segment that is a text glyph or a labeled box is not an icon")
    func segmentGates() async throws {
        let runs = [RecognizedText(text: "Settings row", pixelBox: CGRect(x: 60, y: 100, width: 200, height: 24)),
                    RecognizedText(text: "second", pixelBox: CGRect(x: 60, y: 140, width: 200, height: 24)),
                    RecognizedText(text: "third", pixelBox: CGRect(x: 60, y: 180, width: 200, height: 24))]
        let regions = FixedRegions(boxes: [CGRect(x: 40, y: 106, width: 10, height: 11),
                                           CGRect(x: 62, y: 102, width: 196, height: 20)])
        let scene = try await ScenePipeline(text: FixedText(runs: runs), regions: regions).perceive(try blank(1000, 500), of: window)
        #expect(scene.elements.allSatisfy { $0.kind == .text })
    }

    @Test("section rectangles compose panels; a nil segmenter yields a text-only scene")
    func sectionsAndTextOnly() async throws {
        var sectioned = window
        sectioned.sectionRects = [NormalizedRect(x: 0, y: 0, width: 0.2, height: 1), NormalizedRect(x: 0.2, y: 0, width: 0.8, height: 1)]
        let text = FixedText(runs: [RecognizedText(text: "TRACKS", pixelBox: CGRect(x: 10, y: 10, width: 60, height: 14)),
                                    RecognizedText(text: "Kick", pixelBox: CGRect(x: 10, y: 60, width: 40, height: 14)),
                                    RecognizedText(text: "Export", pixelBox: CGRect(x: 700, y: 400, width: 50, height: 14))])
        let scene = try await ScenePipeline(text: text).perceive(try blank(1000, 500), of: sectioned)
        #expect(scene.sections.map(\.name) == ["sidebar (TRACKS)", "content"])
        #expect(scene.elements.first { $0.label == "Kick" }?.section == "sidebar (TRACKS)")
        #expect(scene.elements.first { $0.label == "Export" }?.section == "content")
    }

    @Test("a recognizer that cannot run fails the perception")
    func recognizerFailurePropagates() async throws {
        let pipeline = ScenePipeline(text: FixedText(runs: [], failure: Unavailable()))
        let image = try blank(100, 100)
        await #expect(throws: Unavailable.self) { try await pipeline.perceive(image, of: window) }
    }

    @Test("an augmenter runs only with a process and a frame, adds its elements, and the token follows")
    func augmentation() async throws {
        let text = FixedText(runs: [RecognizedText(text: "Export", pixelBox: CGRect(x: 700, y: 400, width: 52, height: 16))])
        let row = SceneElement(id: "control|audio13", kind: .control, label: "Audio 13",
                               bounds: NormalizedRect(x: 0.03, y: 0.2, width: 0.3, height: 0.03), role: "AXRow")
        let recorder = FixedAugmentation.Recorder()
        let pipeline = ScenePipeline(text: text, augmentation: FixedAugmentation(elements: [row], seen: recorder))

        let plain = try await pipeline.perceive(try blank(1000, 500), of: window)
        #expect(plain.elements.map(\.label) == ["Export"])
        #expect(recorder.calls.isEmpty)

        var owned = window
        owned.processID = 4242
        owned.frame = CGRect(x: 100, y: 100, width: 1000, height: 500)
        let augmented = try await pipeline.perceive(try blank(1000, 500), of: owned)
        #expect(augmented.elements.map(\.label) == ["Export", "Audio 13"])
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.0 == 4242)
        #expect(augmented.token != plain.token)
    }

    @Test("a harvested element takes the panel it lands in")
    func augmentedElementsTakeSections() {
        let scene = SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
            elements: [],
            sections: [SceneSection(name: "sidebar", bounds: NormalizedRect(x: 0, y: 0, width: 0.3, height: 1))]
        )
        let row = SceneElement(id: "control|kick", kind: .control, label: "Kick",
                               bounds: NormalizedRect(x: 0.05, y: 0.2, width: 0.2, height: 0.03), role: "AXRow")
        let merged = ScenePipeline.augmented(scene, with: [row])
        #expect(merged.elements.first?.section == "sidebar")
    }

    @Test("the same inputs always produce the same token")
    func deterministicToken() async throws {
        let text = FixedText(runs: [RecognizedText(text: "Export", pixelBox: CGRect(x: 30, y: 101, width: 52, height: 16))])
        let pipeline = ScenePipeline(text: text)
        let first = try await pipeline.perceive(try blank(1000, 500), of: window)
        let second = try await pipeline.perceive(try blank(1000, 500), of: window)
        #expect(first.token == second.token)
    }

    struct SizedText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            [RecognizedText(text: "\(image.width)x\(image.height)", pixelBox: CGRect(x: 1, y: 1, width: 20, height: 8))]
        }
    }

    @Test("control regions are cropped before recognition at either backing scale", arguments: [1, 2])
    func regionBeforeRecognition(scale: Int) async throws {
        let image = try blank(500 * scale, 200 * scale)
        let bounds = NormalizedRect(x: 0.2, y: 0.25, width: 0.18, height: 0.1)
        let result = try await ScenePipeline(text: SizedText()).perceive(image, inside: bounds, of: window)
        let scene = try #require(result)
        #expect(scene.viewportPixelSize == ViewportPixelSize(width: 90 * scale, height: 20 * scale))
        #expect(scene.elements.first?.label == "\(90 * scale)x\(20 * scale)")
    }

    @Test("invalid or partly outside control regions are refused", arguments: [
        NormalizedRect(x: -0.1, y: 0, width: 0.3, height: 0.1),
        NormalizedRect(x: 0.9, y: 0, width: 0.3, height: 0.1),
        NormalizedRect(x: 0.2, y: 0.2, width: 0, height: 0.1),
        NormalizedRect(x: .nan, y: 0, width: 0.3, height: 0.1),
    ])
    func invalidRegion(bounds: NormalizedRect) async throws {
        let scene = try await ScenePipeline(text: SizedText()).perceive(try blank(500, 200), inside: bounds, of: window)
        #expect(scene == nil)
    }

    @Test("cropped control reads do not mix whole-window accessibility coordinates into the crop")
    func regionHasNoWholeWindowAugmentation() async throws {
        let recorder = FixedAugmentation.Recorder()
        let pipeline = ScenePipeline(text: SizedText(), augmentation: FixedAugmentation(elements: [], seen: recorder))
        let wholeWindow = ScenePipeline.Window(
            bundleID: "com.x", appName: "X", title: "New Paths", processID: 42,
            frame: CGRect(x: 1000, y: 500, width: 500, height: 200)
        )
        _ = try await pipeline.perceive(
            try blank(500, 200), inside: NormalizedRect(x: 0.2, y: 0.25, width: 0.18, height: 0.1), of: wholeWindow
        )
        #expect(recorder.calls.isEmpty)
    }
}
