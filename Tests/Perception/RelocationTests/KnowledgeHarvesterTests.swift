import XCTest
import CoreGraphics
import LocatorCore
@testable import Relocation

final class KnowledgeHarvesterTests: XCTestCase {
    // CV-first hover attribution: map the cursor's global point into the window and pick the SMALLEST
    // observed object containing it (so a row inside a panel wins over the enclosing panel).
    func testObjectUnderCursorPicksSmallestContaining() {
        let window = CGRect(x: 100, y: 50, width: 1000, height: 800)
        func obj(_ key: String, _ b: [Double]) -> ObservedObject {
            ObservedObject(identityKey: key, selfText: key, role: nil, source: .cv, boundsNormalized: b,
                           firstSeen: .init(timeIntervalSince1970: 0), lastSeen: .init(timeIntervalSince1970: 0))
        }
        let panel = obj("panel", [0.0, 0.0, 0.6, 1.0])      // left 60% of the window
        let row = obj("row", [0.0, 0.5, 0.6, 0.05])         // a row inside the panel
        let other = obj("other", [0.7, 0.0, 0.3, 1.0])      // right column

        // Cursor over the row (normalized 0.1, 0.52 → global 200, 466): smallest containing = the row.
        let hit = KnowledgeHarvester.objectUnderCursor([panel, row, other], windowFrameGlobalPt: window,
                                                       cursorGlobalPt: CGPoint(x: 100 + 0.1 * 1000, y: 50 + 0.52 * 800))
        XCTAssertEqual(hit?.identityKey, "row")

        // Cursor over the panel but not the row → the panel.
        let hit2 = KnowledgeHarvester.objectUnderCursor([panel, row, other], windowFrameGlobalPt: window,
                                                        cursorGlobalPt: CGPoint(x: 100 + 0.1 * 1000, y: 50 + 0.1 * 800))
        XCTAssertEqual(hit2?.identityKey, "panel")

        // Cursor outside every object → nil (honest miss, no false attribution).
        XCTAssertNil(KnowledgeHarvester.objectUnderCursor([row], windowFrameGlobalPt: window,
                                                          cursorGlobalPt: CGPoint(x: 100 + 0.9 * 1000, y: 50 + 0.9 * 800)))
    }

    func testPadLetsNearMissOnTightBoxRegister() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // A tight text box at 50%,50%, 4%×1%. Cursor just below it (0.5, 0.515) is OUTSIDE strictly...
        let tight = ObservedObject(identityKey: "t", selfText: "Properties", role: nil, source: .cv,
                                   boundsNormalized: [0.48, 0.495, 0.04, 0.01],
                                   firstSeen: .init(timeIntervalSince1970: 0), lastSeen: .init(timeIntervalSince1970: 0))
        let cursor = CGPoint(x: 500, y: 515)   // 0.5, 0.515 — ~0.5% below the box bottom (0.505)
        XCTAssertNil(KnowledgeHarvester.objectUnderCursor([tight], windowFrameGlobalPt: window, cursorGlobalPt: cursor))             // strict: miss
        XCTAssertEqual(KnowledgeHarvester.objectUnderCursor([tight], windowFrameGlobalPt: window, cursorGlobalPt: cursor, pad: 0.02)?.identityKey, "t")  // padded: hit
    }

    func testObjectFromSegmentIsTextlessPositionKeyed() {
        let o = KnowledgeHarvester.objectFromSegment(CGRect(x: 200, y: 100, width: 40, height: 40),
                                                     windowPixelSize: CGSize(width: 2000, height: 1000),
                                                     now: .init(timeIntervalSince1970: 0))
        XCTAssertNil(o?.selfText)                 // icon: no text
        XCTAssertEqual(o?.source, .cv)
        XCTAssertEqual(o?.identityKey, "?|@1,1")   // position-bucketed (10×10): x≈0.1→1, y≈0.1→1
    }
}

final class KnowledgeHarvesterLeafTextTests: XCTestCase {
    // The ambient/observe capture must record a control's LABEL but NEVER a text-input control's typed
    // VALUE (which is user content — including a password field, since AXSecureTextField is a subrole of
    // AXTextField). Every other role keeps `value`, where it is the displayed label.
    func testLeafTextNeverCapturesTypedFieldValue() {
        // Buttons / static text: value IS a label → kept.
        XCTAssertEqual(KnowledgeHarvester.leafText(role: "AXButton", title: "Export", description: nil, value: nil), "Export")
        XCTAssertEqual(KnowledgeHarvester.leafText(role: "AXStaticText", title: nil, description: nil, value: "Ready"), "Ready")
        XCTAssertEqual(KnowledgeHarvester.leafText(role: nil, title: nil, description: nil, value: "labelish"), "labelish")

        // Text-input controls: the typed value is CONTENT → dropped; the field's label is kept.
        XCTAssertNil(KnowledgeHarvester.leafText(role: "AXTextField", title: nil, description: nil, value: "hunter2"))
        XCTAssertNil(KnowledgeHarvester.leafText(role: "AXTextArea", title: nil, description: nil, value: "secret notes"))
        XCTAssertNil(KnowledgeHarvester.leafText(role: "AXSearchField", title: nil, description: nil, value: "my private query"))
        XCTAssertEqual(KnowledgeHarvester.leafText(role: "AXTextField", title: "Email", description: nil, value: "me@private.com"), "Email")
        XCTAssertEqual(KnowledgeHarvester.leafText(role: "AXTextField", title: nil, description: "Password", value: "p@ss"), "Password")
    }

    /// DECIDED on the benchmark (326432a): the text-overlap veto stays at 0.9. A word's dilated segment
    /// (overlap ≈0.79 here) is geometrically identical to a labelled button on a dark UI, and vetoing it at
    /// 0.6 cost 13–22 detections per app. Only a segment the OCR box practically fills (≥0.9) is vetoed.
    func testAWordSegmentPassesButAFullyCoveredOneDoesNot() {
        let seg = CGRect(x: 100, y: 100, width: 84, height: 26), ocr = CGRect(x: 103, y: 102, width: 78, height: 22)
        XCTAssertTrue(KnowledgeHarvester.isLikelyIcon(seg, ocrBoxes: [ocr]), "≈0.79 overlap: could be a button — kept")
        let tight = CGRect(x: 100, y: 100, width: 80, height: 24), tightOCR = CGRect(x: 100, y: 100, width: 79, height: 23)
        XCTAssertFalse(KnowledgeHarvester.isLikelyIcon(tight, ocrBoxes: [tightOCR]), "≈0.95 overlap: a word")
    }

    func testAButtonContainingItsLabelIsStillAnIcon() {
        let seg = CGRect(x: 100, y: 100, width: 120, height: 60), ocr = CGRect(x: 135, y: 120, width: 50, height: 20)
        XCTAssertTrue(KnowledgeHarvester.isLikelyIcon(seg, ocrBoxes: [ocr]))
    }
}
