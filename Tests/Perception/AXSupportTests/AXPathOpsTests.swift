import XCTest
import CoreGraphics
@testable import AXSupport
@testable import LocatorCore

final class AXPathOpsTests: XCTestCase {
    let reader = FakeReader()

    /// app → window → toolbar → [Italic, Bold, Underline] buttons. Returns (app, bold).
    private func standardTree() -> (app: FakeNode, bold: FakeNode) {
        let italic = FakeNode(role: "AXButton", title: "Italic", actions: ["AXPress"])
        let bold = FakeNode(role: "AXButton", title: "Bold", actions: ["AXPress"])
        let underline = FakeNode(role: "AXButton", title: "Underline", actions: ["AXPress"])
        let toolbar = FakeNode(role: "AXToolbar").adding(italic, bold, underline)
        let window = FakeNode(role: "AXWindow", title: "Untitled").adding(toolbar)
        let app = FakeNode(role: "AXApplication").adding(window)
        return (app, bold)
    }

    func testCapturePathRootToLeafStopsAtWindow() {
        let (app, bold) = standardTree()
        withExtendedLifetime(app) {   // keep the (weak-parent) upward chain alive
            let path = AXPathOps.capturePath(from: bold, reader: reader)
            XCTAssertEqual(path.map(\.role), ["AXWindow", "AXToolbar", "AXButton"])
            XCTAssertEqual(path.last?.title, "Bold")
            XCTAssertEqual(path.last?.index, 1)            // Bold is index 1 among same-role buttons
            XCTAssertEqual(path.first?.role, "AXWindow")   // window at the top
        }
    }

    func testSameRoleSiblingIndex() {
        let (app, bold) = standardTree()
        withExtendedLifetime(app) {
            XCTAssertEqual(AXPathOps.sameRoleSiblingIndex(of: bold, reader: reader), 1)
        }
    }

    func testReplayResolvesSameElement() {
        let (app, bold) = standardTree()
        let path = AXPathOps.capturePath(from: bold, reader: reader)
        let attrs = AXPathOps.leafAttrs(of: bold, reader: reader)
        let replayed = AXPathOps.replayPath(path, root: app, leafAttrs: attrs, reader: reader)
        XCTAssertTrue(replayed === bold)
    }

    func testReplaySurvivesSiblingReorderViaTitleMatch() {
        let (app, bold) = standardTree()
        let path = AXPathOps.capturePath(from: bold, reader: reader)   // Bold captured at index 1
        let attrs = AXPathOps.leafAttrs(of: bold, reader: reader)

        // Reorder so Bold is now index 0 — index-based pick would miss, title match should recover.
        let toolbar = bold.parent!
        toolbar.setChildren([bold] + toolbar.children.filter { $0 !== bold })

        let replayed = AXPathOps.replayPath(path, root: app, leafAttrs: attrs, reader: reader)
        XCTAssertTrue(replayed === bold)
    }

    func testLeafCousinSearchWhenIndexPicksWrongAndStepHasNoLabel() {
        // Buttons a, b, Bold. Capture a path step with NO title (index-only), but leaf attrs DO carry
        // "Bold". After reorder the index points at the wrong button → the leaf scan must recover Bold.
        let a = FakeNode(role: "AXButton", title: "A")
        let b = FakeNode(role: "AXButton", title: "B")
        let bold = FakeNode(role: "AXButton", title: "Bold")
        let toolbar = FakeNode(role: "AXToolbar").adding(a, b, bold)
        let window = FakeNode(role: "AXWindow").adding(toolbar)
        let app = FakeNode(role: "AXApplication").adding(window)

        let leafStep = AXPathStep(role: "AXButton", title: nil, index: 2)  // no label, index 2 == Bold originally
        let path = [
            AXPathStep(role: "AXWindow", index: 0),
            AXPathStep(role: "AXToolbar", index: 0),
            leafStep,
        ]
        let attrs = AXLeafAttrs(role: "AXButton", title: "Bold")

        // Reorder to [Bold, A, B]: index 2 now points at B, not Bold.
        toolbar.setChildren([bold, a, b])

        let replayed = AXPathOps.replayPath(path, root: app, leafAttrs: attrs, reader: reader)
        XCTAssertTrue(replayed === bold, "leaf attr scan should recover Bold even though index picked B")
    }

    func testReplayReturnsNilWhenLeafAttrsUnsatisfiable() {
        let (app, bold) = standardTree()
        let path = AXPathOps.capturePath(from: bold, reader: reader)
        let wrongAttrs = AXLeafAttrs(role: "AXButton", title: "Strikethrough")  // no such button
        XCTAssertNil(AXPathOps.replayPath(path, root: app, leafAttrs: wrongAttrs, reader: reader))
    }

    func testReplayDiagnosticReportsNoCandidates() {
        let (app, _) = standardTree()
        withExtendedLifetime(app) {
            let path = [
                AXPathStep(role: "AXWindow", index: 0),
                AXPathStep(role: "AXTabGroup", index: 0),   // window has a toolbar, not a tab group
            ]
            let outcome = AXPathOps.replayPathDiagnostic(path, root: app, reader: reader)
            guard case .noCandidates(let depth, let role) = outcome else {
                return XCTFail("expected noCandidates, got \(outcome)")
            }
            XCTAssertEqual(depth, 1)
            XCTAssertEqual(role, "AXTabGroup")
        }
    }

    func testReplayDiagnosticReportsLeafMismatch() {
        let (app, bold) = standardTree()
        withExtendedLifetime(app) {
            let path = AXPathOps.capturePath(from: bold, reader: reader)
            let wrong = AXLeafAttrs(role: "AXButton", title: "Strikethrough")
            let outcome = AXPathOps.replayPathDiagnostic(path, root: app, leafAttrs: wrong, reader: reader)
            guard case .leafAttrMismatch(let depth) = outcome else {
                return XCTFail("expected leafAttrMismatch, got \(outcome)")
            }
            XCTAssertEqual(depth, path.count - 1)
        }
    }

    func testReplayMatchesViaDescriptionWhenTitleEmpty() {
        // Logic-Pro style: label lives in descriptionText, title is nil.
        let knob = FakeNode(role: "AXSlider", descriptionText: "Volume")
        let window = FakeNode(role: "AXWindow").adding(knob)
        let app = FakeNode(role: "AXApplication").adding(window)
        let path = AXPathOps.capturePath(from: knob, reader: reader)
        let attrs = AXPathOps.leafAttrs(of: knob, reader: reader)
        XCTAssertNil(path.last?.title)
        XCTAssertEqual(path.last?.descriptionText, "Volume")
        XCTAssertTrue(AXPathOps.replayPath(path, root: app, leafAttrs: attrs, reader: reader) === knob)
    }
}
