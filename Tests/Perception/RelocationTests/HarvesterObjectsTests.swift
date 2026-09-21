import XCTest
import CoreGraphics
import LocatorCore
@testable import Relocation

/// The knowledge base sees what the agent sees: production `Grouped` elements → `ObservedObject`s.
final class HarvesterObjectsTests: XCTestCase {
    let size = CGSize(width: 1000, height: 500), now = Date(timeIntervalSince1970: 1_700_000_000)

    func testControlIsOneNamedObjectAndImagesAreNotObjects() {
        let els = [
            ElementGrouper.Grouped(rect: CGRect(x: 100, y: 100, width: 60, height: 40), kind: "control", label: "Export", state: "off"),
            ElementGrouper.Grouped(rect: CGRect(x: 200, y: 100, width: 20, height: 20), kind: "icon", label: "", unlabeled: true),
            ElementGrouper.Grouped(rect: CGRect(x: 300, y: 100, width: 80, height: 16), kind: "text", label: "Sequence 01"),
            ElementGrouper.Grouped(rect: CGRect(x: 0, y: 200, width: 600, height: 300), kind: "image", label: "image"),
            ElementGrouper.Grouped(rect: CGRect(x: 10, y: 210, width: 20, height: 20), kind: "overlay-candidate", label: "", unlabeled: true),
        ]
        let objs = KnowledgeHarvester.objects(from: els, windowPixelSize: size, now: now)
        XCTAssertEqual(objs.count, 3, "control + unlabeled icon + text; the picture and its overlay are not knowledge objects")
        XCTAssertEqual(objs[0].selfText, "Export")
        XCTAssertEqual(objs[0].boundsNormalized, [0.1, 0.2, 0.06, 0.08])
        XCTAssertNil(objs[1].selfText, "an unlabeled icon is position-keyed, never named ''")
        XCTAssertEqual(objs[2].selfText, "Sequence 01")
        XCTAssertTrue(objs.allSatisfy { $0.source == .cv })
    }

    func testEmptyTextIsNotAnObject() {
        let els = [ElementGrouper.Grouped(rect: CGRect(x: 1, y: 1, width: 5, height: 5), kind: "text", label: "  ")]
        XCTAssertTrue(KnowledgeHarvester.objects(from: els, windowPixelSize: size, now: now).isEmpty)
    }
}
