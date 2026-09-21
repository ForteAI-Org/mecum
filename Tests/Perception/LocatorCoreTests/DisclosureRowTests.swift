import XCTest
@testable import LocatorCore

final class DisclosureRowTests: XCTestCase {
    func testCollapsedAndExpandedHeaders() {
        XCTAssertEqual(DisclosureRow.classify("> AUDIO")?.state, .collapsed)
        XCTAssertEqual(DisclosureRow.classify("> AUDIO")?.header, "AUDIO")
        XCTAssertEqual(DisclosureRow.classify("V METADATA")?.state, .expanded)
        XCTAssertEqual(DisclosureRow.classify("V CONTENT CREDENTIALS")?.header, "CONTENT CREDENTIALS")
        XCTAssertEqual(DisclosureRow.classify("> GENERAL")?.header, "GENERAL")
    }

    func testRejectsNonHeaders() {
        XCTAssertNil(DisclosureRow.classify("Video content fragment"))   // 'V' is a word's first letter
        XCTAssertNil(DisclosureRow.classify("VIDEO"))                    // no chevron
        XCTAssertNil(DisclosureRow.classify("> Sign In to upload"))      // rest not all-caps
        XCTAssertNil(DisclosureRow.classify(">"))                        // no header
        XCTAssertNil(DisclosureRow.classify("v mp4"))                    // lowercase body
    }

    func testAnnotateRewritesLabelAndAffordance() {
        let e = SceneElement(id: "x", kind: "control", label: "> GENERAL", pos: [0.2, 0.8, 0.3, 0.03])
        let out = DisclosureRow.annotate([e])[0]
        XCTAssertEqual(out.label, "GENERAL")
        XCTAssertTrue(out.does?.contains("EXPANDS") == true)
        // an icon is never a disclosure header
        let icon = SceneElement(id: "y", kind: "icon", label: "> AUDIO", pos: [0, 0, 0.1, 0.1])
        XCTAssertEqual(DisclosureRow.annotate([icon])[0].label, "> AUDIO")
    }
}
