import XCTest
import CoreGraphics
@testable import AXSupport

final class OpaqueDetectionTests: XCTestCase {
    let reader = FakeReader()
    let windowFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testEmptyFullFrameGroupIsOpaque() {
        // A GPU canvas: empty AXGroup, no useful children, frame ≈ the whole window.
        let canvas = FakeNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertTrue(AXPathOps.isOpaqueGroup(canvas, windowFrame: windowFrame, reader: reader))
    }

    func testToolbarWithLabeledChildrenIsNotOpaque() {
        let button = FakeNode(role: "AXButton", title: "Bold")
        let toolbar = FakeNode(role: "AXGroup", frame: windowFrame).adding(button)
        XCTAssertFalse(AXPathOps.isOpaqueGroup(toolbar, windowFrame: windowFrame, reader: reader))
    }

    func testSmallEmptyGroupIsNotOpaque() {
        let small = FakeNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        XCTAssertFalse(AXPathOps.isOpaqueGroup(small, windowFrame: windowFrame, reader: reader))
    }

    func testTitledGroupIsNotOpaque() {
        let titled = FakeNode(role: "AXGroup", title: "Inspector", frame: windowFrame)
        XCTAssertFalse(AXPathOps.isOpaqueGroup(titled, windowFrame: windowFrame, reader: reader))
    }

    func testNonGroupRoleIsNeverOpaque() {
        let button = FakeNode(role: "AXButton", frame: windowFrame)
        XCTAssertFalse(AXPathOps.isOpaqueGroup(button, windowFrame: windowFrame, reader: reader))
    }
}
