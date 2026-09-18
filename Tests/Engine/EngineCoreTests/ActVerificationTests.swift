//
//  ActVerificationTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import EngineCore
import PerceptionCore
import Testing

/// The rule that ended the false green checkmark: success needs a structural effect, an identical
/// scene is a ghost, and a pixel-only change is not the action landing.
@Suite("Act verification")
struct ActVerificationTests {

    private func rect(_ x: Double, _ y: Double) -> NormalizedRect { NormalizedRect(x: x, y: y, width: 0.05, height: 0.02) }

    private func scene(_ elements: [SceneElement], title: String = "Export", token: SceneToken? = nil) -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements, token: token)
    }

    private let toggleOff = SceneElement(id: "sw", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .off)
    private let toggleOn  = SceneElement(id: "sw", kind: .control, label: "Facebook", bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.02), state: .on)

    @Test("an identical scene is a ghost")
    func ghost() {
        let before = scene([toggleOff])
        #expect(ActVerification.verdict(before: before, after: before, targetID: "sw") == .ghost)
        let outcome = ActVerification.outcome(for: .ghost, label: "Facebook", after: before)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("did NOT change"))
    }

    @Test("a structural effect lands")
    func landed() {
        let before = scene([toggleOff]), after = scene([toggleOn])
        let verdict = ActVerification.verdict(before: before, after: after, targetID: "sw")
        #expect(verdict == .landed(.stateFlip(from: .off, to: .on), matchesExpectation: true))
        let outcome = ActVerification.outcome(for: verdict, label: "Facebook", after: after)
        #expect(outcome.kind == .foundActed)
        #expect(outcome.isSuccess)
        #expect(outcome.message == "clicked 'Facebook' — toggles")
        #expect(outcome.scene == after)
    }

    @Test("a different token with no structural effect is unattributable")
    func unattributable() {
        let before = scene([toggleOff])
        let repaint = scene([toggleOff], token: SceneToken(rawValue: "different"))
        let verdict = ActVerification.verdict(before: before, after: repaint, targetID: "sw")
        #expect(verdict == .unattributable)
        let outcome = ActVerification.outcome(for: verdict, label: "Facebook", after: repaint)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("nothing structural"))
    }

    @Test("an expectation is compared by family")
    func expectationByFamily() {
        let before = scene([toggleOff]), after = scene([toggleOn])
        let sameFamily = ActVerification.verdict(before: before, after: after, targetID: "sw", expected: .stateFlip(from: .on, to: .off))
        #expect(sameFamily == .landed(.stateFlip(from: .off, to: .on), matchesExpectation: true))
        let otherFamily = ActVerification.verdict(before: before, after: after, targetID: "sw", expected: .menuOpened(labels: []))
        #expect(otherFamily == .landed(.stateFlip(from: .off, to: .on), matchesExpectation: false))
        let outcome = ActVerification.outcome(for: otherFamily, label: "Facebook", after: after)
        #expect(outcome.kind == .actedUnverified)
        #expect(outcome.message.contains("not the expected effect"))
    }

    @Test("a perceived window maps an element to a global point")
    func globalPoint() {
        let element = SceneElement(id: "e", kind: .control, label: "OK", bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
        let perceived = PerceivedWindow(scene: scene([element]), frame: CGRect(x: 100, y: 200, width: 400, height: 300))
        #expect(perceived.globalPoint(of: element) == CGPoint(x: 100 + 0.55 * 400, y: 200 + 0.55 * 300))
    }
}
