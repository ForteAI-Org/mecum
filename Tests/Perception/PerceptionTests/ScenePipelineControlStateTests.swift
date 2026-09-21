//
//  ScenePipelineControlStateTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
@testable import Perception
import PerceptionCore
import Testing

/// The control state stage, driven through a double that honors the role: shape gates over
/// geometry, a fixed verdict per family, and a record of every candidate it was asked about.
/// No image is read, which is the point: the composition is proven here and the pixel reader at
/// its own boundary.
@Suite("Scene pipeline control state")
struct ScenePipelineControlStateTests {

    struct FixedText: TextRecognizing {
        var runs: [RecognizedText] = []

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            runs
        }
    }

    struct FixedRegions: RegionSegmenting {
        var boxes: [CGRect]

        func segments(in image: CGImage) throws -> [CGRect] { boxes }
    }

    struct FixedControlState: ControlStateReading {
        var toggle: ControlState?
        var mark: ControlState?
        var readsMarks: Bool = true
        var asked: Recorder

        final class Recorder: @unchecked Sendable {
            var candidates: [ControlCandidate] = []
        }

        func isToggleShaped(_ box: CGRect) -> Bool {
            let aspect = box.width / box.height
            return aspect >= 1.5 && aspect <= 2.3
        }

        func isMarkShaped(_ box: CGRect) -> Bool {
            guard readsMarks else { return false }
            let aspect = box.width / box.height
            return aspect >= 0.8 && aspect <= 1.25
        }

        func state(of candidate: ControlCandidate, in image: CGImage) -> ControlState? {
            asked.candidates.append(candidate)
            return candidate.shape == .mark ? mark : toggle
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

    private let window = ScenePipeline.Window(bundleID: "com.x", appName: "X", title: "Settings")

    @Test("a nil reader leaves every control silent, as the scene was before the role")
    func nilReaderChangesNothing() async throws {
        let regions = FixedRegions(boxes: [CGRect(x: 40, y: 40, width: 40, height: 20)])
        let scene = try await ScenePipeline(text: FixedText(), regions: regions)
            .perceive(try blank(1000, 500), of: window)
        #expect(scene.elements.allSatisfy { $0.state == nil })
    }

    @Test("a switch candidate the grouper places takes the state the reader commits to")
    func readerFillsASwitchState() async throws {
        let pill = CGRect(x: 40, y: 40, width: 40, height: 20)
        let asked = FixedControlState.Recorder()
        let reader = FixedControlState(toggle: .on, mark: nil, asked: asked)
        let scene = try await ScenePipeline(
            text: FixedText(), regions: FixedRegions(boxes: [pill]), controlState: reader
        ).perceive(try blank(1000, 500), of: window)
        #expect(asked.candidates.map(\.shape) == [.toggle])
        #expect(scene.elements.count == 1)
        #expect(scene.elements.first?.state == .on)
    }

    @Test("a reader that will not commit leaves the control silent")
    func unreadableCandidateLeavesNoState() async throws {
        let asked = FixedControlState.Recorder()
        let reader = FixedControlState(toggle: nil, mark: nil, asked: asked)
        let scene = try await ScenePipeline(
            text: FixedText(),
            regions: FixedRegions(boxes: [CGRect(x: 40, y: 40, width: 40, height: 20)]),
            controlState: reader
        ).perceive(try blank(1000, 500), of: window)
        #expect(asked.candidates.count == 1)
        #expect(scene.elements.first?.state == nil)
    }

    @Test("a confirmed mark leaves the switch pass's input, so its dot is never read as a knob")
    func confirmedMarkLeavesTheSwitchPass() async throws {
        // Two same-size squares sharing a left edge: the grouper's unanchored-column fallback would
        // take them for all-off switches if the mark pass had not already claimed them.
        let squares = [CGRect(x: 100, y: 100, width: 24, height: 24),
                       CGRect(x: 100, y: 200, width: 24, height: 24)]
        let asked = FixedControlState.Recorder()
        let reader = FixedControlState(toggle: .off, mark: .on, asked: asked)
        let scene = try await ScenePipeline(
            text: FixedText(), regions: FixedRegions(boxes: squares), controlState: reader
        ).perceive(try blank(1000, 500), of: window)
        #expect(asked.candidates.allSatisfy { $0.shape == .mark })
        #expect(scene.elements.count == 2)
        #expect(scene.elements.allSatisfy { $0.state == .on })
    }

    @Test("an unclaimed column is assumed to be switches the reader must confirm")
    func unclaimedColumnBecomesAssumedSwitches() async throws {
        let squares = [CGRect(x: 100, y: 100, width: 24, height: 24),
                       CGRect(x: 100, y: 200, width: 24, height: 24)]
        let asked = FixedControlState.Recorder()
        let reader = FixedControlState(toggle: .off, mark: nil, readsMarks: false, asked: asked)
        let scene = try await ScenePipeline(
            text: FixedText(), regions: FixedRegions(boxes: squares), controlState: reader
        ).perceive(try blank(1000, 500), of: window)
        #expect(asked.candidates.allSatisfy { $0.shape == .toggle && $0.isAssumed })
        #expect(scene.elements.allSatisfy { $0.state == .off })
    }
}
