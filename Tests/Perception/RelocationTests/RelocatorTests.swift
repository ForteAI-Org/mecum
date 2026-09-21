import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

final class RelocatorTests: XCTestCase {
    func testStage1HitShortCircuitsAndDoesNotSelfHeal() async {
        let probes = MockProbes()
        probes.set("axPath", .hit(rectImagePx: CGRect(x: 1, y: 2, width: 3, height: 4),
                                  rectScreenPt: nil, confidence: 1, healed: makeDescriptor()))
        let healer = MockHealer()
        let result = await Relocator(probes: probes, healer: healer).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .axPath)
        XCTAssertEqual(probes.calls, ["axPath"])             // short-circuited
        XCTAssertTrue(healer.healed.isEmpty, "stage 1 is canonical — must not self-heal")
    }

    func testStage2HitSelfHeals() async {
        let probes = MockProbes()
        probes.set("axPath", .miss)
        probes.set("geometryNCC", .hit(rectImagePx: nil, rectScreenPt: CGRect(x: 0, y: 0, width: 1, height: 1),
                                       confidence: 0.9, healed: makeDescriptor()))
        let healer = MockHealer()
        let result = await Relocator(probes: probes, healer: healer).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .geometryNCC)
        XCTAssertEqual(probes.calls, ["axPath", "geometryNCC"])
        XCTAssertEqual(healer.healed.count, 1)
    }

    func testAllMissReturnsNotFoundAfterAllStages() async {
        let probes = MockProbes()   // every stage defaults to .miss
        let result = await Relocator(probes: probes).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .notFound)
        XCTAssertEqual(probes.calls, ["axPath", "geometryNCC", "textConstellation", "contextNCC", "segmentationScore"])
    }

    func testNoTextElementRunsContextNCCBeforeTextConstellation() async {
        // A no-text element (icon/avatar) has no label to find, so its own-crop full-window NCC
        // (contextNCC) must run BEFORE the wasteful text stage — the opposite order from text elements.
        let probes = MockProbes()
        let result = await Relocator(probes: probes).relocate(makeDescriptor(selfText: nil))

        XCTAssertEqual(result.method, .notFound)
        XCTAssertEqual(probes.calls, ["axPath", "geometryNCC", "contextNCC", "textConstellation", "segmentationScore"])
    }

    func testOffscreenShortCircuits() async {
        let probes = MockProbes()
        probes.set("axPath", .miss)
        probes.set("geometryNCC", .offscreen)
        let result = await Relocator(probes: probes).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .offscreen)
        XCTAssertEqual(probes.calls, ["axPath", "geometryNCC"])   // didn't fall through to CV stages
    }

    func testStage4HitSelfHealsAndReportsMethod() async {
        let probes = MockProbes()
        for s in ["axPath", "geometryNCC", "contextNCC", "textConstellation"] { probes.set(s, .miss) }
        probes.set("segmentationScore", .hit(rectImagePx: CGRect(x: 5, y: 5, width: 10, height: 10),
                                             rectScreenPt: nil, confidence: 0.7, healed: makeDescriptor()))
        let healer = MockHealer()
        let result = await Relocator(probes: probes, healer: healer).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .segmentationScore)
        XCTAssertEqual(result.confidence, 0.7)
        XCTAssertEqual(healer.healed.count, 1)
    }

    func testLowerStageHitWithoutHealedDataDoesNotCrashOrHeal() async {
        let probes = MockProbes()
        probes.set("axPath", .miss)
        probes.set("geometryNCC", .hit(rectImagePx: CGRect.zero, rectScreenPt: nil, confidence: 0.88, healed: nil))
        let healer = MockHealer()
        let result = await Relocator(probes: probes, healer: healer).relocate(makeDescriptor())

        XCTAssertEqual(result.method, .geometryNCC)
        XCTAssertTrue(healer.healed.isEmpty)   // nothing to heal when the stage provided no update
    }
}
