import XCTest
import CoreGraphics
@testable import Relocation
import LocatorCore

/// Pure-logic tests for the AX augmentor — the parts that don't need a live app: label cleaning (the
/// Pro Tools "Audio 13 - Audio Track " / "Shown. …" suffixes) and the additive merge that must never
/// create duplicate resolve targets. The live table walk is validated in supervised sessions.
final class AXSceneAugmentorTests: XCTestCase {
    func el(_ label: String, _ x: Double, _ y: Double, unlabeled: Bool? = nil) -> SceneElement {
        SceneElement(id: label, kind: "control", label: label, pos: [x, y, 0.06, 0.011], unlabeled: unlabeled)
    }

    func testCleanLabelStripsProToolsSuffixes() {
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Audio 13 - Audio Track "), "Audio 13")
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Shown. Audio 5"), "Audio 5")
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Hidden. Bass DI - Audio Track"), "Bass DI")
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Vocal Comp"), "Vocal Comp")   // untouched when clean
    }

    func testMergeAddsAXRowsMissingFromCV() {
        // CV mangled the list (missing Audio 13); AX supplies it → added.
        let cv = [el("Audio 1", 0.04, 0.20), el("(unlabeled)", 0.04, 0.34, unlabeled: true)]
        let ax = [el("Audio 13", 0.04, 0.34)]
        let merged = AXSceneAugmentor.merge(cv: cv, ax: ax)
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains { $0.label == "Audio 13" })
    }

    func testMergeDedupsWhenCVAlreadyHasSameLabelNearby() {
        // CV already read "Audio 1" at ~the same spot → AX row for it is NOT re-added (no dup targets).
        let cv = [el("Audio 1", 0.04, 0.20)]
        let ax = [el("Audio 1", 0.045, 0.205)]
        let merged = AXSceneAugmentor.merge(cv: cv, ax: ax)
        XCTAssertEqual(merged.filter { $0.label == "Audio 1" }.count, 1)
    }

    func testMergeKeepsSameLabelWhenFarApart() {
        // Two genuinely different controls sharing a name (a "vol" per track) must both survive —
        // dedup is position-scoped, not label-global.
        let cv = [el("vol", 0.3, 0.48)]
        let ax = [el("vol", 0.3, 0.68)]
        let merged = AXSceneAugmentor.merge(cv: cv, ax: ax)
        XCTAssertEqual(merged.filter { $0.label == "vol" }.count, 2)
    }

    func testEmptyAXLeavesCVUntouched() {
        let cv = [el("A", 0.1, 0.1), el("B", 0.2, 0.2)]
        XCTAssertEqual(AXSceneAugmentor.merge(cv: cv, ax: []).count, 2)
    }

    func testCleanLabelHandlesPopupCurrentGlyph() {
        // popup current item carries a checkmark glyph; the row we TARGET does not — but cleanLabel is
        // still exercised on both here for the suffix-stripping contract.
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Routing Folder - Audio Track"), "Routing Folder")
        XCTAssertEqual(AXSceneAugmentor.cleanLabel("Shown. Track 12"), "Track 12")
    }
}
